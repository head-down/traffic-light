"""
状态管理 — 文件系统轮询 + 多会话聚合，带 Qt signal 通知

聚合优先级: waiting > failure > thinking > running > success > idle
按状态类型分别设置 TTL，定期清理过期状态文件
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
POLL_INTERVAL_MS = 300  # 文件系统轮询间隔

# 状态目录: traffic-light/.traffic-light-states/
_STATE_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    ".traffic-light-states",
)


class StateManager(QObject):
    """扫描状态目录，按优先级聚合后通知 UI"""

    state_changed = pyqtSignal(str)  # 聚合后的状态
    project_dir_changed = pyqtSignal(str)  # 当前项目路径（来自 hook）

    def __init__(self, project=None):
        super().__init__()
        self._sessions = {}  # {project_name: {"state": str, "last_seen": float}}
        self._aggregated = "idle"
        self._project_dir = ""
        self._project = project  # 指定关注的项目名，对应 <project>.state 文件；None = 聚合所有

        # 轮询定时器
        self._poll_timer = QTimer(self)
        self._poll_timer.timeout.connect(self._poll_from_dir)
        self._poll_timer.start(POLL_INTERVAL_MS)

    # ---- 文件系统轮询 ----

    def _poll_from_dir(self):
        """扫描状态目录，按优先级聚合，清理过期文件"""
        if not os.path.isdir(_STATE_DIR):
            return

        now = time.time()
        sessions = {}
        stale_files = []
        project_dir = None

        try:
            for fname in os.listdir(_STATE_DIR):
                if not fname.endswith(".state"):
                    continue
                # 按项目过滤：指定 project 时只读 <project>.state
                if self._project is not None:
                    expected = f"{self._project}.state"
                    if fname != expected:
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

    @property
    def state(self):
        return self._aggregated

    @property
    def session_count(self):
        return len(self._sessions)

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
