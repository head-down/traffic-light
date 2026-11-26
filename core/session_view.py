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

# 状态集合：原六态 + ended（SessionEnd 只置 ended，不删文件）
VALID_STATES = set(AGGREGATE_PRIORITY) | {"ended"}

_PRIORITY_INDEX = {name: index for index, name in enumerate(AGGREGATE_PRIORITY)}


# ============================================================
# 数据模型
# ============================================================

@dataclass(frozen=True)
class Bind:
    """一条绑定记录（`<session_id>.bind` 的解析结果）"""
    session_id: str
    pid: int
    creation_ft: str = ""
    hwnd: int = 0
    hwnd_owner_pid: int = 0
    hwnd_owner_ft: str = ""
    project: str = ""
    cwd: str = ""
    updated: float = 0.0
    degraded: bool = False


@dataclass(frozen=True)
class StateEntry:
    """一条身份层状态（`<pid>.state` 的解析结果）"""
    pid: int
    state: str
    cwd: str = ""
    creation_ft: str = ""
    mtime: float = 0.0


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


def _to_int(value, default=None):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def _to_bool(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def _parse_bind(path):
    """解析单个 .bind 文件；缺 pid 或 pid 非数字视为损坏。

    pid=0 是合法状态：解析器认出了窗口却没认定进程（身份未知）。这条
    绑定仍属于那个窗口，只是渲染成 idle、跳过进程校验。
    """
    fields = {}
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line or "=" not in line:
                continue
            key, value = line.split("=", 1)
            fields[key.strip()] = value.strip()

    pid = _to_int(fields.get("pid"))
    if pid is None:
        raise ValueError(f"invalid bind pid: {fields.get('pid')!r}")
    if pid < 0:
        pid = 0

    session_id = fields.get("session_id", "")
    return Bind(
        session_id=session_id,
        pid=pid,
        creation_ft=fields.get("creation_ft", ""),
        hwnd=_to_int(fields.get("hwnd"), 0),
        hwnd_owner_pid=_to_int(fields.get("hwnd_owner_pid"), 0),
        hwnd_owner_ft=fields.get("hwnd_owner_ft", ""),
        project=fields.get("project", ""),
        cwd=fields.get("cwd", ""),
        updated=float(fields.get("updated", 0) or 0),
        degraded=_to_bool(fields.get("degraded")),
    )


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
            if not name.endswith(".bind"):
                continue
            try:
                binds.append(_parse_bind(os.path.join(self._state_dir, name)))
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
            if not name.endswith(".state"):
                continue
            pid = _to_int(name[:-len(".state")])
            if pid is None or pid <= 0:
                continue
            path = os.path.join(self._state_dir, name)
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    lines = f.read().splitlines()
                state = lines[0].strip() if lines else ""
                if state not in VALID_STATES:
                    continue
                states[pid] = StateEntry(
                    pid=pid,
                    state=state,
                    cwd=lines[1].strip() if len(lines) >= 2 else "",
                    creation_ft=lines[2].strip() if len(lines) >= 3 else "",
                    mtime=os.path.getmtime(path),
                )
            except OSError:
                continue
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

    def __init__(self, sources, hwnd=None, degraded=False,
                 process_checker=None, now=None):
        self._sources = sources
        self._hwnd = hwnd
        self._degraded = degraded
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
            if bind.degraded != self._degraded:
                continue
            if not self._degraded and (not self._hwnd or bind.hwnd != self._hwnd):
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
