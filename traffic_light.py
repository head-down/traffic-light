#!/usr/bin/env python
"""
信号灯 drawer — 一个终端窗口（hwnd）一盏悬浮灯

用法:
    python traffic_light.py --hwnd <十进制> [--nonce <hex>]
    python traffic_light.py --degraded [--hwnd 0] [--nonce <hex>]

由解析器写好锚（.traffic-light-states/w<hwnd>.win）后拉起；drawer 只读
本窗绑定聚合渲染，每 1000ms 刷新锚 mtime 作为心跳，窗口失效 / owner
（pid + 创建时间）不匹配 / 本窗零活 pid 连续 3 次心跳 / nonce 被替换时
注销自己并退出。

--degraded 与 --hwnd 0 等价：全机一盏降级灯（锚 w0.win / 任务
traffic-light-w0），聚合所有 degraded=1 的绑定并标 <project> ?；
不绑定 owner、不跟随窗口，连续 3 次心跳无降级会话即自灭。

状态目录由自身位置推导（源码版 = 脚本目录，frozen = EXE 目录），命令行
只传 hwnd 与 nonce（schtasks /TR 有 261 字符上限）。不写 .pid 文件，
自己的 pid 写进锚的 drawer_pid=。
"""
import argparse
import ctypes
import os
import subprocess
import sys

# hook 入口：GUI 子系统下用 CREATE_NO_WINDOW 起 bash，避免每个事件闪一个黑框。
# 必须在导入 PyQt 之前处理：hook 不需要 Qt，启动越快越好。
if len(sys.argv) > 1 and sys.argv[1] == "--hook":
    from core.hook_launcher import run_hook

    sys.exit(run_hook(sys.argv[2:]))

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

from PyQt5.QtCore import QTimer
from PyQt5.QtWidgets import QApplication

from core.drawer import (
    EXIT_NONCE,
    HEARTBEAT_MS,
    TICK_MS,
    Anchor,
    DrawerGuard,
    anchor_path,
    badge_count,
    degraded_beat,
    degraded_label,
    derive_state_dir,
    read_anchor,
    touch_anchor,
    write_anchor,
)
from core.light_panel import LightPanel
from core.overlay_window import TrafficLightWindow
from core.position_engine import PositionEngine
from core.session_view import FileSystemSources, SessionView
from core.terminal_adapter import TerminalAdapter
from core.terminal_tracker import get_window_owner, is_window


def _redirect_logs(state_dir):
    """stdout/stderr → daemon.log；pythonw 下没有控制台，print 会炸。"""
    try:
        os.makedirs(state_dir, exist_ok=True)
        log = open(os.path.join(state_dir, "daemon.log"), "a",
                   buffering=1, encoding="utf-8")
    except OSError:
        return
    sys.stdout = log
    sys.stderr = log


def _unregister_task(hwnd):
    """注销本窗计划任务（杀灯的唯一路径是 drawer 自检）。"""
    try:
        subprocess.run(
            ["schtasks", "/Delete", "/TN", "traffic-light-w%d" % hwnd, "/F"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            check=False,
        )
    except OSError:
        pass


class _DrawerLoop:
    """渲染 tick（300ms）+ 心跳 tick（1000ms）。"""

    def __init__(self, app, hwnd, guard, anchor_file, state_dir,
                 window, panel, degraded=False):
        self._app = app
        self._hwnd = hwnd
        self._guard = guard
        self._anchor_file = anchor_file
        self._window = window
        self._panel = panel
        self._degraded = degraded
        if degraded:
            self._view = SessionView(FileSystemSources(state_dir),
                                     degraded=True)
        else:
            self._view = SessionView(FileSystemSources(state_dir), hwnd=hwnd)
        self._live_count = 0
        self._stopped = False

        self._render_timer = QTimer(app)
        self._render_timer.timeout.connect(self._render)
        self._render_timer.setInterval(TICK_MS)

        self._beat_timer = QTimer(app)
        self._beat_timer.timeout.connect(self._beat)
        self._beat_timer.setInterval(HEARTBEAT_MS)

    def start(self):
        self._render()
        self._render_timer.start()
        self._beat_timer.start()

    def _render(self):
        view = self._view.snapshot()
        self._live_count = view.count
        self._panel.set_state(view.state)
        if self._degraded:
            self._panel.set_project_name(degraded_label(view))
        else:
            self._panel.set_project_name(view.label)
        self._panel.set_badge(badge_count(view, self._degraded))
        self._window.set_glow_color(view.state)

    def _beat(self):
        # 先验 nonce，再刷 mtime：被取代的 drawer 不能替新锚续命
        anchor = read_anchor(self._anchor_file)
        if self._degraded:
            # 降级灯没有窗口与 owner 可校验，只按降级会话数判自灭
            decision = degraded_beat(self._guard, anchor, self._live_count)
        else:
            decision = self._guard.check(
                anchor,
                window_alive=is_window(self._hwnd),
                owner=get_window_owner(self._hwnd),
                live_count=self._live_count,
            )
        if decision is None:
            touch_anchor(self._anchor_file)
            return
        self._die(decision)

    def _die(self, decision):
        if self._stopped:
            return
        self._stopped = True
        self._render_timer.stop()
        self._beat_timer.stop()
        if decision.reason != EXIT_NONCE:
            # 被取代时任务与锚已归新实例，旧 drawer 一律不碰
            _unregister_task(self._hwnd)
        if decision.remove_anchor:
            try:
                os.remove(self._anchor_file)
            except OSError:
                pass
        self._window.hide()
        self._app.quit()


def main(argv=None):
    parser = argparse.ArgumentParser(description="一窗一灯的 drawer")
    parser.add_argument("--hwnd", type=int, default=None,
                        help="终端窗口句柄（十进制）；0 与 --degraded 等价")
    parser.add_argument("--degraded", action="store_true",
                        help="降级灯：全机一盏，锚 w0.win")
    parser.add_argument("--nonce", type=str, default="",
                        help="锚文件实例 nonce；不传则不校验")
    args = parser.parse_args(argv)

    if args.hwnd is None and not args.degraded:
        parser.error("需要 --hwnd 或 --degraded")
    degraded = args.degraded or args.hwnd == 0
    hwnd = 0 if degraded else args.hwnd

    state_dir = derive_state_dir()
    anchor_file = anchor_path(state_dir, hwnd)
    anchor = read_anchor(anchor_file)
    if anchor is None:
        # 没有锚就没有要渲染的窗口，也绝不自己造锚
        return 0

    guard = DrawerGuard(nonce=args.nonce or None)
    if guard.check_nonce(anchor) is not None:
        # 被取代：静默退出，不删新锚
        return 0

    # pythonw 下没有控制台：先接管 stdout/stderr，避免后续 print 抛异常
    _redirect_logs(state_dir)
    print("[SignalLight] drawer hwnd=%d pid=%d degraded=%d"
          % (hwnd, os.getpid(), 1 if degraded else 0), flush=True)

    # 回填 drawer_pid（不写 .pid 文件）；写前再验一次 nonce
    current = read_anchor(anchor_file)
    if current is None or current.nonce != anchor.nonce:
        return 0
    write_anchor(anchor_file, Anchor(
        nonce=anchor.nonce,
        drawer_pid=os.getpid(),
        hwnd=anchor.hwnd,
        owner_pid=anchor.owner_pid,
        owner_ft=anchor.owner_ft,
        started=anchor.started,
    ))

    app = QApplication([sys.argv[0]])
    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName("traffic-light")

    window = TrafficLightWindow(name="SignalLight")
    panel = LightPanel(window)
    panel.setGeometry(0, 0, window.width(), window.height())

    if degraded:
        # 降级灯不跟随任何窗口：自由置顶、不抢焦点
        window.enable_free_floating()
        window.show()
    else:
        # 跟随定位：hwnd 来自命令行，不做终端发现
        position = PositionEngine(app, window, TerminalAdapter(hwnd))
        position.start()

    drawer = _DrawerLoop(app, hwnd, guard, anchor_file, state_dir,
                         window, panel, degraded=degraded)
    drawer.start()

    try:
        app.exec_()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
