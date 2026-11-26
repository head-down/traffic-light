"""一窗一灯的 drawer 纯逻辑：锚文件读写、nonce 校验、自灭判定。

这里不做任何 Qt / 窗口操作，便于用纯逻辑测试覆盖判定；运行期胶水在
traffic_light.py。锚文件（.traffic-light-states/w<hwnd>.win）由解析器原子
创建，drawer 只负责刷新 mtime、回填 drawer_pid，以及判定自己该死。
"""
import os
import sys
import tempfile
from dataclasses import dataclass

from core.process_identity import creation_ft_matches

STATE_DIR_NAME = ".traffic-light-states"

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
class Anchor:
    """w<hwnd>.win 的内容"""
    nonce: str = ""
    drawer_pid: int = 0
    hwnd: int = 0
    owner_pid: int = 0
    owner_ft: str = ""
    started: str = ""


@dataclass(frozen=True)
class ExitDecision:
    """自灭判定结果；remove_anchor=False 时只退出、不碰锚（被取代）"""
    reason: str
    remove_anchor: bool


def derive_state_dir():
    """状态目录由自身位置推导：源码版 = 脚本目录，frozen = EXE 目录。"""
    if getattr(sys, "frozen", False):
        base = os.path.dirname(sys.executable)
    else:
        base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, STATE_DIR_NAME)


def anchor_path(state_dir, hwnd):
    return os.path.join(state_dir, "w%d.win" % int(hwnd))


def _to_int(value, default=0):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def read_anchor(path):
    """读锚；文件缺失或不可读时返回 None"""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return None

    fields = {}
    for line in lines:
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        fields[key.strip()] = value.strip()

    return Anchor(
        nonce=fields.get("nonce", ""),
        drawer_pid=_to_int(fields.get("drawer_pid")),
        hwnd=_to_int(fields.get("hwnd")),
        owner_pid=_to_int(fields.get("owner_pid")),
        owner_ft=fields.get("owner_ft", ""),
        started=fields.get("started", ""),
    )


def write_anchor(path, anchor):
    """同目录临时文件 + 重命名，原子替换（不加锁）"""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    lines = [
        "nonce=" + anchor.nonce,
        "drawer_pid=%d" % anchor.drawer_pid,
        "hwnd=%d" % anchor.hwnd,
        "owner_pid=%d" % anchor.owner_pid,
        "owner_ft=" + anchor.owner_ft,
        "started=" + anchor.started,
    ]
    fd, tmp = tempfile.mkstemp(prefix=".win-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write("\n".join(lines) + "\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def touch_anchor(path):
    """显式刷新锚 mtime（心跳）；锚已消失时返回 False"""
    try:
        os.utime(path, None)
        return True
    except OSError:
        return False


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


# ============================================================
# 降级灯（全机一盏，锚 w0.win）
# ============================================================

def degraded_label(view):
    """降级灯主标签：`<project> ?`；无降级会话时不显示标签。"""
    if view is None or not view.count:
        return ""
    return ("%s ?" % view.label) if view.label else "?"


def degraded_beat(guard, anchor, live_count):
    """降级灯心跳：没有可跟随的窗口与 owner，只按降级会话数判自灭。"""
    return guard.check(anchor, window_alive=True, owner=None,
                       live_count=live_count)


def badge_count(view, degraded=False):
    """角标数字：窗口灯数不同会话；降级灯是全机一盏，不画 ·N。"""
    if degraded or view is None:
        return 0
    return view.count
