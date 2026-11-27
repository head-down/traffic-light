"""会话视图聚合 — bind ⋈ state 的唯一 Python seam。

drawer 与降级灯都只消费 `SessionView.snapshot()`，不各自读文件。

聚合管线：
  读绑定 ⋈ 读状态 → 同一 pid 取 updated 最新的绑定 → 按 hwnd/降级模式过滤
  → 身份校验（pid + 创建时间）→ 按 pid 去重 → 按优先级聚合

状态 TTL 只在聚合时用作过滤：超时的状态回落到 idle，不作废会话本身
（绑定 TTL 归 hook 侧的低频事件处理，不在这里淘汰会话）。
"""
import os
import time
from dataclasses import dataclass

from core import wire
from core.wire import VALID_STATES

# 聚合优先级：等待确认 > 失败 > 思考 > 运行 > 成功 > 空闲
AGGREGATE_PRIORITY = ["waiting", "failure", "thinking", "running", "success", "idle"]
# 每类状态的 TTL（秒）：超时只在聚合时回落 idle，不淘汰会话本身
STATE_TTL_SECONDS = {
    "thinking": 600,
    "running": 90,
    "waiting": 600,
    "success": 8,
    "failure": 30,
    "idle": float("inf"),
}

_PRIORITY_INDEX = {name: index for index, name in enumerate(AGGREGATE_PRIORITY)}


# ============================================================
# 数据模型
# ============================================================

@dataclass(frozen=True)
class SessionInfo:
    """聚合输出中的单条会话"""
    pid: int
    state: str
    project: str
    session_id: str


@dataclass(frozen=True)
class WindowView:
    """一盏灯渲染所需的全部信息"""
    state: str
    label: str
    count: int
    degraded: bool
    sessions: list


# ============================================================
# Sources — 数据源适配器
# ============================================================

class Sources:
    """绑定 + 状态的数据源抽象"""

    def read_binds(self) -> list:
        raise NotImplementedError

    def read_states(self) -> dict:
        raise NotImplementedError


class FileSystemSources(Sources):
    """从 `.traffic-light-states/` 读真实绑定与状态文件"""

    def __init__(self, state_dir):
        self._state_dir = state_dir

    def read_binds(self) -> list:
        binds = []
        if not os.path.isdir(self._state_dir):
            return binds
        try:
            names = os.listdir(self._state_dir)
        except OSError:
            return binds

        for name in names:
            if not wire.is_bind(name):
                continue
            try:
                binds.append(wire.read_bind(os.path.join(self._state_dir, name)))
            except (OSError, ValueError):
                continue
        return binds

    def read_states(self) -> dict:
        states = {}
        if not os.path.isdir(self._state_dir):
            return states
        try:
            names = os.listdir(self._state_dir)
        except OSError:
            return states

        for name in names:
            pid = wire.parse_state_name(name)
            if pid is None:
                continue
            path = os.path.join(self._state_dir, name)
            try:
                entry = wire.read_state(path, pid,
                                        mtime=os.path.getmtime(path))
            except OSError:
                continue
            if entry.state not in VALID_STATES:
                continue
            states[pid] = entry
        return states


class InMemorySources(Sources):
    """纯内存数据源 — 测试注入用"""

    def __init__(self, binds=None, states=None):
        self._binds = list(binds or [])
        self._states = dict(states or {})

    def add_bind(self, bind):
        self._binds.append(bind)

    def add_state(self, entry):
        self._states[entry.pid] = entry

    def read_binds(self) -> list:
        return list(self._binds)

    def read_states(self) -> dict:
        return dict(self._states)


# ============================================================
# SessionView
# ============================================================

class SessionView:
    """把绑定与状态聚合成一盏灯能直接消费的窗口视图"""

    def __init__(self, sources, hwnd=0, process_checker=None, now=None):
        # 降级灯就是「没有窗口的灯」：唯一的判据是 hwnd 是否为空
        self._sources = sources
        self._hwnd = hwnd
        self._degraded = not hwnd
        if process_checker is None:
            from core.process_identity import is_process_alive
            process_checker = is_process_alive
        self._checker = process_checker
        self._now = now

    def snapshot(self) -> WindowView:
        now = self._resolve_now()
        states = self._sources.read_states()
        binds = self._latest_binds(self._sources.read_binds())

        entries = []
        for bind in binds:
            # 写出端保证 degraded ⇔ hwnd==0；历史文件里两者可能不一致，
            # 任一说降级就按降级灯处理，避免旧绑定再没人认领
            if (bind.degraded or bind.hwnd == 0) != self._degraded:
                continue
            if not self._degraded and bind.hwnd != self._hwnd:
                continue

            known_pid = bind.pid > 0
            entry = states.get(bind.pid) if known_pid else None
            if known_pid:
                creation_ft = bind.creation_ft or (
                    entry.creation_ft if entry is not None else "")
                if not self._checker(bind.pid, creation_ft or None):
                    continue

            entries.append((bind, SessionInfo(
                pid=bind.pid,
                state=self._resolve_state(entry, now),
                project=bind.project,
                session_id=bind.session_id,
            )))

        if not entries:
            return WindowView("idle", "", 0, self._degraded, [])

        entries.sort(key=lambda pair: (
            _PRIORITY_INDEX.get(pair[1].state, len(_PRIORITY_INDEX)),
            -pair[0].updated,
            pair[0].pid,
        ))
        _, top = entries[0]
        return WindowView(top.state, top.project, len(entries),
                          self._degraded, [info for _, info in entries])

    # ---- 内部 ----

    def _resolve_now(self):
        if self._now is None:
            return time.time()
        if callable(self._now):
            return self._now()
        return self._now

    @staticmethod
    def _latest_binds(binds) -> list:
        """同 pid 取 updated 最新的一条；身份未知（pid=0）按 session_id 分辨。"""
        latest = {}
        for bind in binds:
            key = bind.pid if bind.pid > 0 else "session:" + bind.session_id
            current = latest.get(key)
            if current is None or (bind.updated, bind.session_id) >= (
                    current.updated, current.session_id):
                latest[key] = bind
        return list(latest.values())

    @staticmethod
    def _resolve_state(entry, now):
        if entry is None or entry.state not in VALID_STATES:
            return "idle"
        # 身份已校验存活；ended 在 /clear 的 End→Start 间隙按 idle 渲染
        if entry.state == "ended":
            return "idle"
        ttl = STATE_TTL_SECONDS.get(entry.state, 30)
        if ttl != float("inf") and now - entry.mtime > ttl:
            return "idle"
        return entry.state
