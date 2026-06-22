"""
状态管理 — 多会话聚合 + 四态状态机，带 Qt signal 通知

聚合优先级: failure > running > success > idle
空闲会话 30 秒无心跳自动移除
"""
import time
from PyQt5.QtCore import QObject, pyqtSignal, QTimer

VALID_STATES = {"idle", "running", "success", "failure"}
AGGREGATE_PRIORITY = ["failure", "running", "success", "idle"]
SESSION_TTL_SECONDS = 30  # 会话心跳超时
CLEANUP_INTERVAL_MS = 5000  # 清理检查间隔


class StateManager(QObject):
    """管理多会话状态，按优先级聚合后通知 UI"""

    state_changed = pyqtSignal(str)  # 聚合后的状态

    def __init__(self):
        super().__init__()
        self._sessions = {}  # {session_id: {"state": str, "last_seen": float}}
        self._aggregated = "idle"

        # 定时清理过期会话
        self._cleanup_timer = QTimer(self)
        self._cleanup_timer.timeout.connect(self._cleanup_stale_sessions)
        self._cleanup_timer.start(CLEANUP_INTERVAL_MS)

        # 信号连接到自身以处理状态变化后的 auto-reset
        self.state_changed.connect(self._on_aggregated_changed)

    # ---- 会话管理 ----

    def update_session(self, session_id, new_state):
        """更新某个会话的状态，返回聚合后的状态"""
        if new_state not in VALID_STATES:
            return False

        now = time.time()
        if session_id in self._sessions:
            old = self._sessions[session_id]["state"]
            if old == new_state:
                self._sessions[session_id]["last_seen"] = now
                return True
        else:
            old = None

        self._sessions[session_id] = {"state": new_state, "last_seen": now}
        self._recompute()

        return True

    def remove_session(self, session_id):
        """移除会话（终端关闭时调用）"""
        if session_id in self._sessions:
            del self._sessions[session_id]
            self._recompute()

    def _cleanup_stale_sessions(self):
        """移除超过 TTL 的会话"""
        now = time.time()
        stale = [
            sid for sid, info in self._sessions.items()
            if now - info["last_seen"] > SESSION_TTL_SECONDS
        ]
        if stale:
            for sid in stale:
                del self._sessions[sid]
            self._recompute()

    # ---- 聚合 ----

    def _recompute(self):
        """按优先级计算聚合状态"""
        if not self._sessions:
            new_aggregated = "idle"
        else:
            for candidate in AGGREGATE_PRIORITY:
                if any(s["state"] == candidate for s in self._sessions.values()):
                    new_aggregated = candidate
                    break
            else:
                new_aggregated = "idle"

        if new_aggregated != self._aggregated:
            self._aggregated = new_aggregated
            self.state_changed.emit(new_aggregated)

    @property
    def state(self):
        return self._aggregated

    @property
    def session_count(self):
        return len(self._sessions)

    # ---- 兼容旧接口 ----

    def update_state(self, new_state):
        """兼容旧 API：单会话模式"""
        return self.update_session("default", new_state)

    # ---- auto-reset 定时器（与旧版本一致） ----

    def _on_aggregated_changed(self, new_state):
        """聚合状态变化时的副作用"""
        # 单会话兼容：success/failure 5 秒后自动回 idle
        # 多会话模式下，只有在所有会话都是 success/failure
        # 且无 running 时才会触发。这里保持简单：不做自动 reset，
        # 因为多会话场景下，自动 reset 需要谨慎。
        #
        # 多会话模式依赖 SESSION_TTL_SECONDS 的清理机制：
        # 会话停止更新 30 秒后自动移除，聚合状态自然更新。
        pass
