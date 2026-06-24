#!/usr/bin/env python
"""
信号灯守护进程 — Windows 桌面悬浮窗，聚合多个 CodeBuddy / CLI agent 状态

用法:
    python traffic_light.py                      # 启动守护进程（聚合所有项目）
    python traffic_light.py --project mine       # 绑定到指定项目

Hook 脚本通过文件系统写状态文件，守护进程 300ms 轮询聚合显示:
    红灯(失败) > 黄灯(运行中) > 绿灯(成功) > 灭灯(空闲)
"""
import sys
import os
import ctypes
import argparse
import signal

# 必须在 QApplication 创建前设置 DPI awareness
# 系统 DPI 缩放 150%，不设置的话 GetWindowRect 返回虚拟化坐标（缩放后的），
# 导致 SetWindowPos 定位错误
# 用 SetProcessDpiAwarenessContext (Per-Monitor V2) 优先，回退到 V1
_dpi_set = False
try:
    # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
    ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
    _dpi_set = True
except Exception:
    pass
if not _dpi_set:
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)  # PER_MONITOR_AWARE
        _dpi_set = True
    except Exception:
        try:
            ctypes.windll.user32.SetProcessDPIAware()
            _dpi_set = True
        except Exception:
            pass

from PyQt5.QtCore import Qt
from PyQt5.QtWidgets import QApplication
from PyQt5.QtCore import Qt, QTimer, QPoint

from core.overlay_window import TrafficLightWindow
from core.light_panel import LightPanel
from core.state_manager import StateManager
from core.terminal_tracker import (
    find_terminal_for_codebuddy,
    get_window_rect,
    is_window_visible_and_normal,
)

_user32 = ctypes.windll.user32

# Owner 窗口绑定：让灯成为终端的 owned window
# Windows 自动维护 z-order/最小化/销毁，无需手动 TOPMOST 轮询
# 参考: https://blog.walterlv.com/post/set-owner-window-using-win32-api
GWL_HWNDPARENT = -8
SWP_FRAMECHANGED = 0x0020
SWP_NOSIZE = 0x0001
SWP_NOACTIVATE = 0x0010
SWP_NOMOVE = 0x0002
SWP_NOZORDER = 0x0004


def _set_window_owner(light_hwnd, owner_hwnd):
    """
    把灯窗口的 owner 设为终端窗口。
    设置后 Windows 自动保证：
      - 灯始终在终端之上（z-order 跟随）
      - 终端最小化时灯自动隐藏
      - 终端销毁时灯自动销毁
    返回 True 表示设置成功或已存在该 owner。
    """
    # 检查当前 owner 是否已经是目标窗口
    GW_OWNER = 4
    current_owner = _user32.GetWindow(light_hwnd, GW_OWNER)
    if current_owner == owner_hwnd:
        return True

    # 64 位系统用 SetWindowLongPtrW，32 位回退 SetWindowLongW
    try:
        ret = _user32.SetWindowLongPtrW(light_hwnd, GWL_HWNDPARENT, owner_hwnd)
    except AttributeError:
        ret = _user32.SetWindowLongW(light_hwnd, GWL_HWNDPARENT, owner_hwnd)

    if ret == 0:
        err = ctypes.get_last_error()
        if err != 0:
            print(f"[SignalLight] SetWindowLongPtrW failed err={err}", flush=True)
            return False

    # GWL_HWNDPARENT 改动后需 SetWindowPos + SWP_FRAMECHANGED 刷新窗口缓存
    _user32.SetWindowPos(
        light_hwnd, 0, 0, 0, 0, 0,
        SWP_FRAMECHANGED | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOZORDER
    )
    return True


def _read_cbpid(project):
    """读取 CodeBuddy 进程 PID（bind.sh 启动时写入）"""
    pid_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.traffic-light-states')
    cbpid_file = os.path.join(pid_dir, f"{project or 'all'}.cbpid")
    try:
        with open(cbpid_file) as f:
            return int(f.read().strip())
    except Exception:
        return None


def _is_process_alive(pid):
    """检查指定 PID 的进程是否存活（Windows 用 OpenProcess，避免 os.kill 误杀）"""
    try:
        import ctypes
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        STILL_ACTIVE = 259
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not handle:
            return False
        try:
            exit_code = ctypes.c_ulong()
            if kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
                return exit_code.value == STILL_ACTIVE
            return False
        finally:
            kernel32.CloseHandle(handle)
    except Exception:
        return False


def main():
    parser = argparse.ArgumentParser(description="信号灯守护进程")
    parser.add_argument("--project", type=str, default=None, help="绑定项目名（对应 <project>.state），不指定则聚合所有项目")
    args = parser.parse_args()

    # 单实例锁：通过 PID 文件检测（bind.sh 已写 PID，此处做二次确认）
    # 不用 Windows Mutex（进程被强杀后 Mutex 残留，永远锁死）
    import os as _os
    _pid_dir = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '.traffic-light-states')
    _pid_file = _os.path.join(_pid_dir, f"{args.project or 'all'}.pid")
    if _os.path.exists(_pid_file):
        import signal as _signal
        try:
            with open(_pid_file) as _f:
                _old_pid = int(_f.read().strip())
            _os.kill(_old_pid, 0)
            print(f"[SignalLight] {args.project or 'all'} 的守护进程已在运行 (PID={_old_pid})")
            sys.exit(0)
        except Exception:
            _os.remove(_pid_file)  # 旧 PID 文件无效，清理

    # 写 PID 文件表示我们在运行
    _os.makedirs(_pid_dir, exist_ok=True)
    with open(_pid_file, 'w') as _f:
        _f.write(str(_os.getpid()))

    # Qt 应用
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName("traffic-light")

    # 窗口
    window = TrafficLightWindow(name="SignalLight")

    # 灯面板
    panel = LightPanel(window)
    panel.setGeometry(0, 0, window.width(), window.height())

    # 状态管理器（文件系统轮询）
    state_mgr = StateManager(project=args.project)
    state_mgr.state_changed.connect(panel.set_state)
    state_mgr.state_changed.connect(window.set_glow_color)
    state_mgr.project_dir_changed.connect(panel.set_project_name)

    # 终端窗口跟踪：16ms 高频轮询（60fps）+ 位置变化检测
    # z-order 由 owner 关系自动维护（_set_window_owner 一次性设置），
    # 这里只负责跟随位置
    _cb_pid = _read_cbpid(args.project)
    _terminal_hwnd = None
    _term_visible = False
    _last_term_rect = None    # 上次终端 rect，用于变化检测
    _hwnd_cache = None        # 灯窗口 HWND 缓存
    _owner_set = False        # owner 关系是否已建立

    def _get_light_hwnd():
        nonlocal _hwnd_cache
        if _hwnd_cache is None:
            _hwnd_cache = int(window.winId())
        return _hwnd_cache

    def _tick():
        """16ms 高频轮询：检测终端位置变化，只在变化时移动灯"""
        nonlocal _terminal_hwnd, _term_visible, _last_term_rect, _owner_set

        if _terminal_hwnd is None:
            if _cb_pid is not None:
                _terminal_hwnd, _term_pid, _term_title = find_terminal_for_codebuddy(_cb_pid)
                if _terminal_hwnd is not None:
                    print(f"[SignalLight] 终端窗口: {_term_title} (PID={_term_pid})", flush=True)
                    _term_visible = True
                    _last_term_rect = None
                    _owner_set = False
            if _terminal_hwnd is None:
                if not window.isVisible():
                    screen = QApplication.primaryScreen()
                    if screen:
                        geom = screen.availableGeometry()
                        window.move(geom.right() - window.WIDTH - 20, geom.bottom() - window.HEIGHT - 20)
                    window.show()
                return

        # 首次绑定 owner（终端 HWND 刚拿到，或被 Qt 重置后重新建立）
        if not _owner_set:
            if _set_window_owner(_get_light_hwnd(), _terminal_hwnd):
                _owner_set = True
                print(f"[SignalLight] owner 绑定成功: light→terminal (hwnd={_terminal_hwnd})", flush=True)

        visible = is_window_visible_and_normal(_terminal_hwnd)
        if visible != _term_visible:
            _term_visible = visible
            if not visible:
                if window.isVisible():
                    window.hide()
                _last_term_rect = None
                return
            else:
                _last_term_rect = None

        if not _term_visible:
            return

        rect = get_window_rect(_terminal_hwnd)
        if rect == _last_term_rect:
            return
        _last_term_rect = rect

        # get_window_rect 返回物理坐标，Qt move() 用逻辑坐标
        # 转换：逻辑 = 物理 / devicePixelRatio
        screen = QApplication.screenAt(QPoint(rect[0] + (rect[2]-rect[0])//2, rect[1] + 50))
        if not screen:
            screen = QApplication.primaryScreen()
        dpr = screen.devicePixelRatio() if screen else 1.0

        term_w = rect[2] - rect[0]
        x_phys = rect[0] + (term_w - window.WIDTH * dpr) // 2
        y_phys = rect[3] + 8
        # 转逻辑坐标
        x = int(x_phys / dpr)
        y = int(y_phys / dpr)

        if not window.isVisible():
            window.show()
            # Qt show() 可能重置 owner，下次 tick 重新建立
            _owner_set = False
        # 用 Qt 的 move() 处理 DPI 转换；z-order 由 owner 关系自动维护
        window.move(x, y)

    if _cb_pid is not None:
        _tick_timer = QTimer(app)
        _tick_timer.timeout.connect(_tick)
        _tick_timer.start(16)  # 60fps 高频轮询
        _tick()
    else:
        window.show()

    # CodeBuddy 存活检测：Ctrl+C 关闭 CodeBuddy 时 SessionEnd hook 不触发，
    # 守护进程需自己感知 CodeBuddy 退出并自动关闭
    _cb_check_count = 0  # 连续检测失败计数，避免偶发误判

    def _check_codebuddy_alive():
        nonlocal _cb_check_count
        if _cb_pid is None:
            return
        if _is_process_alive(_cb_pid):
            _cb_check_count = 0
        else:
            _cb_check_count += 1
            # 连续 2 次检测失败（约 10 秒）才退出，避免进程刚启动时的抖动
            if _cb_check_count >= 2:
                print(f"[SignalLight] CodeBuddy (PID={_cb_pid}) exited, shutting down", flush=True)
                app.quit()

    if _cb_pid is not None:
        _cb_watcher = QTimer(app)
        _cb_watcher.timeout.connect(_check_codebuddy_alive)
        _cb_watcher.start(5000)  # 每 5 秒检查一次

    # Ctrl+C 优雅退出
    def cleanup(signum=None, frame=None):
        app.quit()

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    try:
        app.exec_()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            _os.remove(_pid_file)
        except Exception:
            pass


if __name__ == "__main__":
    main()
