"""
终端窗口状态跟踪 — hwnd 由参数提供，不再自行发现终端。

drawer 的窗口句柄是命令行参数（解析器唯一真相）；这里只做可见性与
rect 的缓存查询，供 PositionEngine 跟随定位。
"""
from core.terminal_tracker import (
    is_window_visible_and_normal,
    get_window_rect,
)


class TerminalAdapter:
    """
    固定 hwnd 的窗口状态跟踪。

    update_visibility() — 返回 True 表示可见性变化
    update_rect()       — 返回 True 表示位置/尺寸变化

    所有属性均为缓存值，不触发系统调用：
      .hwnd      — 终端 HWND
      .visible   — 当前可见性（布尔）
      .rect      — 当前屏幕坐标 (left, top, right, bottom)，尚未读取时为 None
    """

    def __init__(self, hwnd):
        self._hwnd = int(hwnd)
        self._visible = False
        self._rect = None

    # ---- 状态查询（含缓存更新） ----

    def update_visibility(self) -> bool:
        """更新可见性缓存。返回 True 表示可见性发生变化。"""
        prev = self._visible
        self._visible = is_window_visible_and_normal(self._hwnd)
        return self._visible != prev

    def update_rect(self) -> bool:
        """更新窗口位置缓存。返回 True 表示位置/尺寸发生变化。"""
        prev = self._rect
        self._rect = get_window_rect(self._hwnd)
        return self._rect != prev

    # ---- 属性 ----

    @property
    def hwnd(self):
        return self._hwnd

    @property
    def visible(self):
        return self._visible

    @property
    def rect(self):
        return self._rect
