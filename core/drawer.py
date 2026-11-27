"""一窗一灯的 drawer 纯逻辑：nonce 校验、自灭判定。

这里不做任何 Qt / 窗口操作，也不碰文件，便于用纯逻辑测试覆盖判定；运行期
胶水在 traffic_light.py，锚的格式与读写（.traffic-light-states/w<hwnd>.win）
在 core/wire.py，视图怎么画在 core/render.py。drawer 只判定自己该死。
"""
from dataclasses import dataclass

from core.process_identity import creation_ft_matches

# 渲染 tick 与心跳 tick：锚 mtime 每 1000ms 显式刷新一次
TICK_MS = 300
HEARTBEAT_MS = 1000

# 本窗零活 pid 连续这么多次心跳 → 自灭（/clear 的 End→Start 间隙不误杀）
IDLE_TICK_LIMIT = 3

# 自灭原因
EXIT_NONCE = "nonce_superseded"
EXIT_WINDOW = "window_gone"
EXIT_OWNER = "owner_mismatch"
EXIT_IDLE = "no_live_sessions"


@dataclass(frozen=True)
class ExitDecision:
    """自灭判定结果；remove_anchor=False 时只退出、不碰锚（被取代）"""
    reason: str
    remove_anchor: bool


def owner_matches(anchor, observed_pid, observed_ft):
    """owner（pid + 创建时间）是否仍与锚一致；拿不到的字段一律放行。"""
    if not anchor.owner_pid:
        return True
    if observed_pid is None:
        return True
    try:
        if int(observed_pid) != anchor.owner_pid:
            return False
    except (TypeError, ValueError):
        return True
    if anchor.owner_ft and observed_ft and not creation_ft_matches(
            anchor.owner_ft, observed_ft):
        return False
    return True


class DrawerGuard:
    """drawer 自灭判定：nonce → 窗口存活 → owner → 本窗活会话数。"""

    def __init__(self, nonce=None, idle_limit=IDLE_TICK_LIMIT):
        self._nonce = nonce or None
        self._idle_limit = idle_limit
        self._zero_streak = 0

    def check_nonce(self, anchor):
        if anchor is None:
            return ExitDecision(EXIT_NONCE, remove_anchor=False)
        if self._nonce and anchor.nonce != self._nonce:
            return ExitDecision(EXIT_NONCE, remove_anchor=False)
        return None

    def check(self, anchor, window_alive=True, owner=None, live_count=None):
        decision = self.check_nonce(anchor)
        if decision is not None:
            return decision

        if not window_alive:
            return ExitDecision(EXIT_WINDOW, remove_anchor=True)

        if owner is not None and not owner_matches(anchor, *owner):
            return ExitDecision(EXIT_OWNER, remove_anchor=True)

        if live_count is not None:
            if live_count <= 0:
                self._zero_streak += 1
                if self._zero_streak >= self._idle_limit:
                    return ExitDecision(EXIT_IDLE, remove_anchor=True)
            else:
                self._zero_streak = 0

        return None

    @property
    def zero_streak(self):
        return self._zero_streak
