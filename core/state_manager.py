"""
状态管理 — 多会话聚合 + 四态状态机，带 Qt signal 通知

聚合优先级: failure > running > success > idle
空闲会话 30 秒无心跳自动移除

支持两种更新方式:
1. 文件系统轮询（默认）: hook 写 .traffic-light-states/<sid>.state 文件
2. HTTP API（兼容）: update_session() / remove_session()
"""
import os
import time
from PyQt5.QtCore import QObject, pyqtSignal, QTimer

VALID_STATES = {"idle", "thinking", "running", "waiting", "success", "failure"}
# 聚合优先级：等待确认 > 失败 > 思考 > 运行 > 成功 > 空闲
AGGREGATE_PRIORITY = ["waiting", "failure", "thinking", "running", "success", "idle"]
# 不同状态的 TTL：
# - thinking 180s：模型纯思考期无 hook 触发，给 3 分钟缓冲；超时视为会话已死
# - running 90s：PostToolUse 应频繁触发，90s 无更新视为完成或卡住
# - waiting 600s：权限确认用户可能离开，给 10 分钟
# - success 8s / failure 30s：短 TTL，让用户看到后自动回 idle
STATE_TTL_SECONDS = {
    "thinking": 180,
    "running": 90,
    "waiting": 600,
    "success": 8,
    "failure": 30,
    "idle": float("inf"),
}
CLEANUP_INTERVAL_MS = 5000  # 清理检查间隔（HTTP 模式）
POLL_INTERVAL_MS = 300  # 文件系统轮询间隔

# 状态目录: traffic-light/.traffic-light-states/
_STATE_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    ".traffic-light-states",
)


class StateManager(QObject):
    """管理多会话状态，按优先级聚合后通知 UI"""

    state_changed = pyqtSignal(str)  # 聚合后的状态
    project_dir_changed = pyqtSignal(str)  # 当前项目路径（来自 hook）

    def __init__(self, use_file_polling=True):
        super().__init__()
        self._sessions = {}  # {session_id: {"state": str, "last_seen": float}}
        self._aggregated = "idle"
        self._project_dir = ""

        # 轮询定时器
        self._poll_timer = QTimer(self)
        if use_file_polling:
            self._poll_timer.timeout.connect(self._poll_from_dir)
            self._poll_timer.start(POLL_INTERVAL_MS)
        else:
            # HTTP 模式: 只做 TTL 清理
            self._poll_timer.timeout.connect(self._cleanup_stale_sessions)
            self._poll_timer.start(CLEANUP_INTERVAL_MS)

        # 信号连接到自身以处理状态变化后的 auto-reset
        self.state_changed.connect(self._on_aggregated_changed)

    # ---- 文件系统轮询 ----

    def _poll_from_dir(self):
        """扫描状态目录，按优先级聚合，清理过期文件"""
        if not os.path.isdir(_STATE_DIR):
            return

        now = time.time()
        sessions = {}
        stale_files = []
        project_dir = None  # None 表示本轮没有获取到新值

        try:
            for fname in os.listdir(_STATE_DIR):
                if not fname.endswith(".state"):
                    continue
                sid = fname[:-6]  # 去掉 .state 后缀
                fpath = os.path.join(_STATE_DIR, fname)
                try:
                    mtime = os.path.getmtime(fpath)
                    with open(fpath, "r") as f:
                        lines = f.read().splitlines()
                    state = lines[0].strip() if lines else ""
                    if state not in VALID_STATES:
                        continue
                    # 第二行：项目路径（可选，向后兼容）
                    if len(lines) >= 2:
                        pdir = lines[1].strip()
                        if pdir and project_dir is None:
                            project_dir = pdir
                    # 按状态类型查 TTL
                    ttl = STATE_TTL_SECONDS.get(state, 30)
                    if ttl != float("inf") and now - mtime > ttl:
                        stale_files.append(fpath)
                        continue
                    sessions[sid] = {"state": state, "last_seen": mtime}
                except (IOError, OSError):
                    continue
        except OSError:
            return

        # 清理过期文件
        for fpath in stale_files:
            try:
                os.remove(fpath)
            except OSError:
                pass

        # 状态变化时重新聚合
        self._sessions = sessions
        self._recompute()

        # 项目路径变化通知：只更新非空值，保持常驻显示
        if project_dir is not None:
            if project_dir != self._project_dir:
                self._project_dir = project_dir
                self.project_dir_changed.emit(project_dir)

    # ---- 属性 ----
    @property
    def project_dir(self):
        return self._project_dir

    # ---- 会话管理（HTTP 模式兼容） ----

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
        """移除超过 TTL 的会话（HTTP 模式）"""
        now = time.time()
        stale = []
        for sid, info in self._sessions.items():
            ttl = STATE_TTL_SECONDS.get(info["state"], 30)
            if ttl != float("inf") and now - info["last_seen"] > ttl:
                stale.append(sid)
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

    # ---- auto-reset ----

    def _on_aggregated_changed(self, new_state):
        pass
