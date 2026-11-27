"""状态目录的线上格式（wire format）—— 唯一所有者。

三种文件（都落在 `.traffic-light-states/`）：

  <session_id>.bind   key=value，一行一个字段（BIND_FIELDS）
  <pid>.state         三行：state / cwd / creation_ft（STATE_FIELDS）
  w<hwnd>.win         key=value，窗口锚（ANCHOR_FIELDS），w0.win 是全机降级灯

本模块只管"这些字节是什么"，不管怎么聚合、TTL 多久、灯什么时候该死：
文件名、字段名、解析、序列化、状态目录位置都在这里；绑定与状态的聚合规则在
session_view.py，锚的自灭判定在 drawer.py。

PowerShell 与 bash 是同一个格式的另外两个读写方（resolve-lib.ps1 写 bind 与
anchor、hooks/traffic-light.sh 读 bind 写 state）。它们不 import 本模块，字段
表由 tests/test_wire.py 直接比对写出端源码，改名或加字段不同步就会红。

放宽的历史格式：
  - .state 允许两行（没有 creation_ft，身份未知）
  - .bind 里 pid=0 合法：认出了窗口但没认定进程
  - 不认识的 key 一律忽略：新字段可以让旧读端继续跑
"""
import os
import sys
import tempfile
from dataclasses import dataclass

STATE_DIR_NAME = ".traffic-light-states"

BIND_SUFFIX = ".bind"
STATE_SUFFIX = ".state"

# 字段顺序就是 resolve-lib.ps1 Get-BindLines 的写出顺序；hwnd_source 只作诊断
# 记录（chain / bind / sole / none），聚合时不用它做任何判断。
BIND_FIELDS = (
    "session_id",
    "pid",
    "creation_ft",
    "hwnd",
    "hwnd_owner_pid",
    "hwnd_owner_ft",
    "project",
    "cwd",
    "updated",
    "degraded",
    "hwnd_source",
)

# 一行一个值，没有 key：顺序即格式，两行表示旧格式（缺 creation_ft）
STATE_FIELDS = ("state", "cwd", "creation_ft")

ANCHOR_FIELDS = (
    "nonce",
    "drawer_pid",
    "hwnd",
    "owner_pid",
    "owner_ft",
    "started",
)

# 状态文件里允许出现的值（ended 是 SessionEnd 的终态；TTL 与优先级不在这里）
VALID_STATES = frozenset({
    "waiting", "failure", "thinking", "running", "success", "idle", "ended",
})


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
    hwnd_source: str = ""


@dataclass(frozen=True)
class StateEntry:
    """一条身份层状态（`<pid>.state` 的解析结果）"""
    pid: int
    state: str
    cwd: str = ""
    creation_ft: str = ""
    mtime: float = 0.0


@dataclass(frozen=True)
class Anchor:
    """`w<hwnd>.win` 的内容"""
    nonce: str = ""
    drawer_pid: int = 0
    hwnd: int = 0
    owner_pid: int = 0
    owner_ft: str = ""
    started: str = ""


# ============================================================
# 文件名与状态目录
# ============================================================

def derive_state_dir():
    """状态目录由自身位置推导：源码版 = 脚本目录，frozen = EXE 目录。"""
    if getattr(sys, "frozen", False):
        base = os.path.dirname(sys.executable)
    else:
        base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, STATE_DIR_NAME)


def anchor_path(state_dir, hwnd):
    return os.path.join(state_dir, "w%d.win" % int(hwnd))


def is_bind(name):
    return name.endswith(BIND_SUFFIX)


def parse_state_name(name):
    """`<pid>.state` → pid；后缀不是纯数字或 pid<=0 时返回 None（旧格式）。"""
    if not name.endswith(STATE_SUFFIX):
        return None
    pid = _to_int(name[:-len(STATE_SUFFIX)])
    if pid is None or pid <= 0:
        return None
    return pid


# ============================================================
# 解析
# ============================================================

def _to_int(value, default=None):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def _to_bool(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def _decode_fields(text):
    """key=value 行 → dict；空行与没有等号的行忽略。"""
    fields = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        fields[key.strip()] = value.strip()
    return fields


def _read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read()


def parse_bind(text):
    """解析 .bind 文本；缺 pid 或 pid 非数字视为损坏，抛 ValueError。

    pid=0 是合法状态：解析器认出了窗口却没认定进程（身份未知）。这条
    绑定仍属于那个窗口，只是渲染成 idle、跳过进程校验。
    """
    fields = _decode_fields(text)
    pid = _to_int(fields.get("pid"))
    if pid is None:
        raise ValueError("invalid bind pid: %r" % fields.get("pid"))
    if pid < 0:
        pid = 0

    return Bind(
        session_id=fields.get("session_id", ""),
        pid=pid,
        creation_ft=fields.get("creation_ft", ""),
        hwnd=_to_int(fields.get("hwnd"), 0),
        hwnd_owner_pid=_to_int(fields.get("hwnd_owner_pid"), 0),
        hwnd_owner_ft=fields.get("hwnd_owner_ft", ""),
        project=fields.get("project", ""),
        cwd=fields.get("cwd", ""),
        updated=float(fields.get("updated", 0) or 0),
        degraded=_to_bool(fields.get("degraded")),
        hwnd_source=fields.get("hwnd_source", ""),
    )


def read_bind(path):
    return parse_bind(_read_text(path))


def parse_state(text, pid, mtime=0.0):
    """解析 .state 文本；不校验 state 是否合法，交给聚合层过滤。"""
    lines = text.splitlines()
    return StateEntry(
        pid=pid,
        state=lines[0].strip() if lines else "",
        cwd=lines[1].strip() if len(lines) >= 2 else "",
        creation_ft=lines[2].strip() if len(lines) >= 3 else "",
        mtime=mtime,
    )


def read_state(path, pid, mtime=0.0):
    return parse_state(_read_text(path), pid, mtime)


def parse_anchor(text):
    fields = _decode_fields(text)
    return Anchor(
        nonce=fields.get("nonce", ""),
        drawer_pid=_to_int(fields.get("drawer_pid"), 0),
        hwnd=_to_int(fields.get("hwnd"), 0),
        owner_pid=_to_int(fields.get("owner_pid"), 0),
        owner_ft=fields.get("owner_ft", ""),
        started=fields.get("started", ""),
    )


def read_anchor(path):
    """读锚；文件缺失或不可读时返回 None。"""
    try:
        text = _read_text(path)
    except OSError:
        return None
    return parse_anchor(text)


# ============================================================
# 序列化
# ============================================================

def format_anchor(anchor):
    lines = [
        "nonce=" + anchor.nonce,
        "drawer_pid=%d" % anchor.drawer_pid,
        "hwnd=%d" % anchor.hwnd,
        "owner_pid=%d" % anchor.owner_pid,
        "owner_ft=" + anchor.owner_ft,
        "started=" + anchor.started,
    ]
    return "\n".join(lines) + "\n"


def write_anchor(path, anchor):
    """同目录临时文件 + 重命名，原子替换（不加锁）。"""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".win-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(format_anchor(anchor))
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def touch_anchor(path):
    """显式刷新锚 mtime（心跳）；锚已消失时返回 False。"""
    try:
        os.utime(path, None)
        return True
    except OSError:
        return False
