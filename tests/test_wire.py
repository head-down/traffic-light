"""wire format 契约测试：状态目录里那三种文件长什么样。

这里直接比对 PowerShell / bash 的写出端，因为格式有三个实现，Python 只是
其中之一：字段改名或新增而不同步，灯会安静地不亮，不会报错，所以在 CI 里
把它变成红。
"""
import re
from pathlib import Path

import pytest

from core import wire

ROOT = Path(__file__).resolve().parents[1]

# resolve-lib.ps1 在真实 SessionStart 里写出来的样子（含 hwnd_source）
REAL_BIND = """\
session_id=3f0a1b2c
pid=17324
creation_ft=133500000000000000
hwnd=44434952
hwnd_owner_pid=9844
hwnd_owner_ft=133500000000000001
project=traffic-light
cwd=D:/workspace/traffic-light
updated=1764000000
degraded=0
hwnd_source=chain
"""

REAL_ANCHOR = """\
nonce=9c1f2e3d4b5a
drawer_pid=0
hwnd=44434952
owner_pid=17324
owner_ft=133500000000000000
started=1764000000
"""


# ============================================================
# 解析
# ============================================================

def test_real_bind_from_resolver_is_read_completely():
    bind = wire.parse_bind(REAL_BIND)
    assert bind.session_id == "3f0a1b2c"
    assert bind.pid == 17324
    assert bind.creation_ft == "133500000000000000"
    assert bind.hwnd == 44434952
    assert bind.hwnd_owner_pid == 9844
    assert bind.hwnd_owner_ft == "133500000000000001"
    assert bind.project == "traffic-light"
    assert bind.cwd == "D:/workspace/traffic-light"
    assert bind.updated == 1764000000.0
    assert bind.degraded is False
    assert bind.hwnd_source == "chain"


def test_bind_tolerates_unknown_keys_and_pid_zero():
    bind = wire.parse_bind("pid=0\nhwnd=7\nsomething_new=1\n")
    assert bind.pid == 0
    assert bind.hwnd == 7
    assert bind.session_id == ""


def test_bind_without_numeric_pid_is_damaged():
    with pytest.raises(ValueError):
        wire.parse_bind("session_id=s1\nhwnd=7\n")


def test_state_is_three_ordered_lines_and_two_lines_are_legacy():
    entry = wire.parse_state("running\nC:/work\n133500000000000000\n",
                             pid=42, mtime=10.0)
    assert (entry.pid, entry.state, entry.cwd) == (42, "running", "C:/work")
    assert entry.creation_ft == "133500000000000000"
    assert entry.mtime == 10.0

    old = wire.parse_state("idle\nC:/work\n", pid=42)
    assert old.state == "idle"
    assert old.creation_ft == ""


def test_state_filename_must_be_a_positive_pid():
    assert wire.parse_state_name("4242.state") == 4242
    assert wire.parse_state_name("0.state") is None
    assert wire.parse_state_name("not-a-pid.state") is None
    assert wire.parse_state_name("4242.bind") is None


def test_read_anchor_missing_returns_none(tmp_path):
    assert wire.read_anchor(str(tmp_path / "w1.win")) is None


# ============================================================
# 序列化
# ============================================================

def test_anchor_is_written_in_the_declared_field_order(tmp_path):
    anchor = wire.Anchor(nonce="9c1f2e3d4b5a", drawer_pid=0, hwnd=44434952,
                         owner_pid=17324, owner_ft="133500000000000000",
                         started="1764000000")
    path = tmp_path / "w44434952.win"
    wire.write_anchor(str(path), anchor)
    assert path.read_text(encoding="utf-8") == REAL_ANCHOR
    assert wire.read_anchor(str(path)) == anchor


def test_readers_take_crlf_because_powershell_writes_it():
    bind = wire.parse_bind(REAL_BIND.replace("\n", "\r\n"))
    assert bind.pid == 17324
    assert bind.hwnd_source == "chain"

    anchor = wire.parse_anchor(REAL_ANCHOR.replace("\n", "\r\n"))
    assert anchor.nonce == "9c1f2e3d4b5a"
    assert anchor.started == "1764000000"


# ============================================================
# 跨语言：Python 的字段表必须与写出端一致
# ============================================================

def _source(name):
    return (ROOT / name).read_text(encoding="utf-8-sig")


def test_bind_field_table_matches_the_powershell_writer():
    text = _source("resolve-lib.ps1")
    block = text.split("function Get-BindLines", 1)[1]
    block = block.split("function Get-ResolutionDecision", 1)[0]
    written = re.findall(r"^\s*'([a-z_]+)='\s*\+", block, re.M)
    assert written == list(wire.BIND_FIELDS)


def test_anchor_field_table_matches_the_powershell_writer():
    text = _source("resolve-lib.ps1")
    written = re.findall(r"\$sw\.WriteLine\('([a-z_]+)=", text)
    assert written == list(wire.ANCHOR_FIELDS)


def test_state_shape_matches_the_bash_writer():
    text = _source("hooks/traffic-light.sh")
    # 三行的顺序就是契约：state / cwd / creation_ft
    assert ("printf '%s\\n%s\\n%s\\n' "
            '"$state" "$bind_cwd" "$bind_ft"') in text


def test_aggregate_priority_states_are_valid_wire_states():
    # 渲染优先级与格式允许值是两张表，加状态时不能只改一处
    from core.session_view import AGGREGATE_PRIORITY
    assert set(AGGREGATE_PRIORITY) <= set(wire.VALID_STATES)


def test_bash_bind_reader_only_touches_known_fields():
    text = _source("hooks/traffic-light.sh")
    block = text.split("_read_bind()", 1)[1].split("_bind_usable", 1)[0]
    read = re.findall(r"^\s*([a-z_]+)\)\s+bind_", block, re.M)
    assert set(read) <= set(wire.BIND_FIELDS)
    assert "pid" in read
