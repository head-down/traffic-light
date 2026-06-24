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
import argparse
import signal

from PyQt5.QtWidgets import QApplication
from PyQt5.QtCore import Qt, QTimer

from core.overlay_window import TrafficLightWindow
from core.light_panel import LightPanel
from core.state_manager import StateManager


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

    # 窗口显示
    window.show()

    # CodeBuddy 存活检测：Ctrl+C 关闭 CodeBuddy 时 SessionEnd hook 不触发，
    # 守护进程需自己感知 CodeBuddy 退出并自动关闭
    _cb_pid = _read_cbpid(args.project)
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
        import ctypes
        ctypes.windll.kernel32.SetConsoleCtrlHandler(None, False)
    except Exception:
        pass

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
