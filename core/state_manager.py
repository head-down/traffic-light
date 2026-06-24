"""
状态管理 — 轮询状态源 + 多会话聚合，带 Qt signal 通知

聚合优先级: waiting > failure > thinking > running > success > idle
按状态类型分别设置 TTL，定期清理过期状态

StateSource 适配器:
  FileSystemStateSource — 生产环境，从 .traffic-light-states/*.state 文件读取
  InMemoryStateSource  — 测试环境，纯内存存储
"""
import os
import time
from dataclasses import dataclass, field
from PyQt5.QtCore import QObject, pyqtSignal, QTimer

VALID_STATES = {"idle", "thinking", "running", "waiting", "success", "failure"}
# 聚合优先级：等待确认 > 失败 > 思考 > 运行 > 成功 > 空闲
AGGREGATE_PRIORITY = ["waiting", "failure", "thinking", "running", "success", "idle"]
STATE_TTL_SECONDS = {
    "thinking": 600,
    "running": 90,
    "waiting": 600,
    "success": 8,
    "failure": 30,
    "idle": float("inf"),
}
POLL_INTERVAL_MS = 300

# 默认状态目录: traffic-light/.traffic-light-states/
_DEFAULT_STATE_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    ".traffic-light-states",
)


# ============================================================
# StateSource — 数据适配器
# ============================================================

@dataclass
class StateEntry:
    """单条状态记录"""
    project: str
    state: str
    project_dir: str = ""
    mtime: float = 0.0


class StateSource:
    """状态源抽象基类 — 一个 adapter = 假设 seam"""

    def read_all(self) -> list[StateEntry]:
        """返回所有当前状态条目"""
        raise NotImplementedError

    def remove(self, project: str):
        """删除指定项目的状态条目"""
        raise NotImplementedError


class FileSystemStateSource(StateSource):
    """从 .traffic-light-states/ 目录读状态文件"""

    def __init__(self, state_dir=None):
        self._state_dir = state_dir or _DEFAULT_STATE_DIR

    def read_all(self) -> list[StateEntry]:
        entries = []
        if not os.path.isdir(self._state_dir):
            return entries

        try:
            for fname in os.listdir(self._state_dir):
                if not fname.endswith(".state"):
                    continue
                project = fname[:-6]
                fpath = os.path.join(self._state_dir, fname)
                try:
                    mtime = os.path.getmtime(fpath)
                    with open(fpath, "r") as f:
                        lines = f.read().splitlines()
                    state = lines[0].strip() if lines else ""
                    if state not in VALID_STATES:
                        continue
                    project_dir = lines[1].strip() if len(lines) >= 2 else ""
                    entries.append(StateEntry(project, state, project_dir, mtime))
                except (IOError, OSError):
                    continue
        except OSError:
            pass

        return entries

    def remove(self, project: str):
        fpath = os.path.join(self._state_dir, f"{project}.state")
        try:
            os.remove(fpath)
        except OSError:
            pass


class InMemoryStateSource(StateSource):
    """纯内存状态源 — 测试用 adapter"""

    def __init__(self):
        self._entries: dict[str, StateEntry] = {}

    def add(self, project: str, state: str,
            project_dir: str = "", mtime: float = None):
        """添加/更新一条状态"""
        self._entries[project] = StateEntry(
            project=project,
            state=state,
            project_dir=project_dir,
            mtime=mtime if mtime is not None else time.time(),
        )

    def read_all(self) -> list[StateEntry]:
        return list(self._entries.values())

    def remove(self, project: str):
        self._entries.pop(project, None)


# ============================================================
# StateManager
# ============================================================

class StateManager(QObject):
    """轮询状态源，按优先级聚合后通知 UI"""

    state_changed = pyqtSignal(str)
    project_dir_changed = pyqtSignal(str)

    def __init__(self, project=None, source=None):
        super().__init__()
        self._sessions = {}
        self._aggregated = "idle"
        self._project_dir = ""
        self._project = project
        self._source = source or FileSystemStateSource()

        self._poll_timer = QTimer(self)
        self._poll_timer.timeout.connect(self._poll)
        self._poll_timer.start(POLL_INTERVAL_MS)

    # ---- 轮询 ----

    def _poll(self):
        """从 source 读取状态，TTL 清理，聚合通知"""
        now = time.time()
        sessions = {}
        project_dir = None

        for entry in self._source.read_all():
            # 项目过滤
            if self._project is not None and entry.project != self._project:
                continue

            # 状态合法性
            if entry.state not in VALID_STATES:
                continue

            # TTL 检查
            ttl = STATE_TTL_SECONDS.get(entry.state, 30)
            if ttl != float("inf") and now - entry.mtime > ttl:
                self._source.remove(entry.project)
                continue

            sessions[entry.project] = {
                "state": entry.state,
                "last_seen": entry.mtime,
            }

            if entry.project_dir and project_dir is None:
                project_dir = entry.project_dir

        self._sessions = sessions
        self._recompute()

        if project_dir is not None and project_dir != self._project_dir:
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
