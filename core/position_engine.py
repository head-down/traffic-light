"""
位置引擎 — 60fps 高频轮询，让灯窗口跟随终端移动

从 traffic_light.py 的 _tick 闭包提取。
负责：owner 绑定、可见性跟踪、DPI 坐标转换。

可见性双保险：
  1. GW_OWNER (SetWindowLongPtrW) — z-order 跟随，终端最小化时自动隐藏
  2. is_window_visible_and_normal — 手动 show/hide，应对 GW_OWNER 对 conhost 失效
  首次发现终端时强制标记可见（部分 conhost 窗口 IsWindowVisible 返回 False）
"""
import ctypes
from PyQt5.QtCore import QTimer, QPoint
from PyQt5.QtWidgets import QApplication

_user32 = ctypes.windll.user32

GWL_HWNDPARENT = -8
SWP_FRAMECHANGED = 0x0020
SWP_NOSIZE = 0x0001
SWP_NOACTIVATE = 0x0010
SWP_NOMOVE = 0x0002
SWP_NOZORDER = 0x0004


class PositionEngine:
    """
    60fps 终端位置跟踪。

    __init__   — 创建 QTimer，不启动
    start()    — 首次 tick + 启动定时器
    _tick()    — 每个 16ms tick：owner 绑定 → 可见性 → 位置更新
    """

    def __init__(self, app, window, terminal):
        self._app = app
        self._window = window
        self._terminal = terminal
        self._owner_set = False
        self._hwnd_cache = None
        self._term_visible = False
        self._first_discovery = True

        self._timer = QTimer(app)
        self._timer.timeout.connect(self._tick)
        self._timer.setInterval(16)

    def start(self):
        """首次 tick + 启动定时器"""
        self._tick()
        self._timer.start()

    # ---- 内部 ----

    def _get_light_hwnd(self):
        if self._hwnd_cache is None:
            self._hwnd_cache = int(self._window.winId())
        return self._hwnd_cache

    def _set_window_owner(self):
        """把灯窗口的 owner 设为终端窗口（z-order 跟随）。
        绑定后 Windows 自动维护显隐/最小化/销毁。"""
        light_hwnd = self._get_light_hwnd()
        owner_hwnd = self._terminal.hwnd

        GW_OWNER = 4
        current_owner = _user32.GetWindow(light_hwnd, GW_OWNER)
        if current_owner == owner_hwnd:
            return True

        try:
            ret = _user32.SetWindowLongPtrW(light_hwnd, GWL_HWNDPARENT, owner_hwnd)
        except AttributeError:
            ret = _user32.SetWindowLongW(light_hwnd, GWL_HWNDPARENT, owner_hwnd)

        if ret == 0:
            err = ctypes.get_last_error()
            if err != 0:
                print(
                    f"[SignalLight] SetWindowLongPtrW failed err={err}", flush=True
                )
                return False

        _user32.SetWindowPos(
            light_hwnd,
            0, 0, 0, 0, 0,
            SWP_FRAMECHANGED | SWP_NOSIZE | SWP_NOACTIVATE
            | SWP_NOMOVE | SWP_NOZORDER,
        )
        return True

    def _tick(self):
        """16ms 高频轮询：owner 绑定 → 可见性 → 位置跟踪"""
        self._terminal.discover()

        if not self._terminal.found:
            self._show_at_default()
            return

        # 首次发现终端：强制标记可见 + 重置 owner
        # （匹配 pre-refactor 行为：不查 IsWindowVisible，直接标记可见）
        if self._first_discovery:
            self._first_discovery = False
            self._term_visible = True
            self._owner_set = False

        # owner 绑定（首次或被 show() 重置后）
        if not self._owner_set:
            if self._set_window_owner():
                self._owner_set = True
                print(
                    f"[SignalLight] owner bound: light→terminal "
                    f"(hwnd={self._terminal.hwnd})",
                    flush=True,
                )

        # 可见性跟踪：终端最小化时隐藏灯，还原时显示
        # （GW_OWNER 对 conhost 窗口可能失效，手动 show/hide 是双保险）
        vis_changed = self._terminal.update_visibility()
        if vis_changed:
            if not self._terminal.visible:
                if self._window.isVisible():
                    self._window.hide()
                return
            # 可见性恢复 → 强制 reposition
            self._terminal._rect = None

        if not self._terminal.visible:
            return

        # 位置跟踪：rect 变化时重新定位
        if not self._terminal.update_rect():
            return

        self._position_at_terminal()

    def _show_at_default(self):
        """未找到终端 → 显示在屏幕右下角"""
        if not self._window.isVisible():
            screen = QApplication.primaryScreen()
            if screen:
                geom = screen.availableGeometry()
                self._window.move(
                    geom.right() - self._window.WIDTH - 20,
                    geom.bottom() - self._window.HEIGHT - 20,
                )
            self._window.show()

    def _position_at_terminal(self):
        """根据终端窗口位置 + DPI 计算灯窗口坐标"""
        rect = self._terminal.rect
        if rect is None:
            return

        screen = QApplication.screenAt(
            QPoint(rect[0] + (rect[2] - rect[0]) // 2, rect[1] + 50)
        )
        if not screen:
            screen = QApplication.primaryScreen()
        dpr = screen.devicePixelRatio() if screen else 1.0

        term_w = rect[2] - rect[0]
        x_phys = rect[0] + (term_w - self._window.WIDTH * dpr) // 2
        y_phys = rect[3] + 8
        x = int(x_phys / dpr)
        y = int(y_phys / dpr)

        if not self._window.isVisible():
            self._window.show()
            self._owner_set = False  # Qt show() 可能重置 owner

        self._window.move(x, y)
