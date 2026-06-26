"""
终端窗口发现适配器 — 包装 terminal_tracker 策略链

从 traffic_light.py 的 _discover_terminal 闭包提取。
两阶段：discover() 一次性发现，后续只做缓存的状态查询。
"""
import os

from core.terminal_tracker import (
    get_my_terminal,
    find_terminal_by_any_codebuddy,
    find_terminal_for_codebuddy,
    is_window_visible_and_normal,
    get_window_rect,
)


class TerminalAdapter:
    """
    终端窗口发现与状态跟踪。

    discover()        — 一次性发现（termwnd → cbpid → global scan 降级链）
    update_visibility() — 返回 True 表示可见性变化
    update_rect()     — 返回 True 表示位置/尺寸变化

    所有属性均为缓存值，不触发系统调用：
      .hwnd      — 终端 HWND，未找到时为 None
      .visible   — 当前可见性（布尔）
      .rect      — 当前屏幕坐标 (left, top, right, bottom)，未找到时为 None
      .found     — 是否已找到终端（hwnd is not None）
    """

    def __init__(self, project, pid_dir):
        self._project = project
        self._pid_dir = pid_dir
        self._hwnd = None
        self._visible = False
        self._rect = None
        self._discovered = False

    # ---- 发现 ----

    def discover(self) -> bool:
        """
        尝试发现终端窗口（仅首次调用执行发现）。

        策略:
          1. termwnd: GetConsoleWindow → WM_GETICON → GW_OWNER（精确）
          2. cbpid:   读取 <project>.cbpid → find_terminal_for_codebuddy 精确定位
          3. global scan + claim: 遍历 node.exe，排除已声明 PID（最后回退）

        返回 True 表示找到终端。
        """
        if self._discovered:
            return self._hwnd is not None
        self._discovered = True

        try:
            hwnd, title = get_my_terminal()
            if not hwnd and self._project:
                hwnd, title = self._try_cbpid_terminal()
            if not hwnd:
                hwnd, title = find_terminal_by_any_codebuddy(
                    state_dir=self._pid_dir, project_name=self._project
                )
            if hwnd:
                self._hwnd = hwnd
                print(f"[SignalLight] terminal found: {title}", flush=True)
                return True

            print(
                "[SignalLight] no terminal window found, using default position",
                flush=True,
            )
        except Exception as e:
            print(f"[SignalLight] terminal discovery error: {e}", flush=True)

        return False

    def _try_cbpid_terminal(self):
        """读取 <project>.cbpid 获取 CodeBuddy PID，通过进程树精确定位终端窗口。
        返回 (hwnd, title) 或 (None, None)。"""
        cbpid_file = os.path.join(self._pid_dir, f"{self._project}.cbpid")
        try:
            with open(cbpid_file) as f:
                cb_pid = int(f.read().strip())
        except Exception:
            return None, None

        try:
            hwnd, pid, title = find_terminal_for_codebuddy(cb_pid)
            if hwnd:
                return hwnd, title
        except Exception:
            pass

        return None, None

    # ---- 状态查询（含缓存更新） ----

    def update_visibility(self) -> bool:
        """更新可见性缓存。返回 True 表示可见性发生变化。"""
        if self._hwnd is None:
            return False
        prev = self._visible
        self._visible = is_window_visible_and_normal(self._hwnd)
        return self._visible != prev

    def update_rect(self) -> bool:
        """更新窗口位置缓存。返回 True 表示位置/尺寸发生变化。"""
        if self._hwnd is None:
            return False
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

    def mark_visible(self):
        """首次发现终端时强制标记为可见（部分终端 IsWindowVisible 返回 False）。"""
        self._visible = True

    @property
    def rect(self):
        return self._rect

    @property
    def found(self):
        return self._hwnd is not None
