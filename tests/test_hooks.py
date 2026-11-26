"""hook 入口契约测试：事件 → <pid>.state、TTL/自愈、零额外进程。

seam 是 `hooks/traffic-light.sh <event>` 的命令行入口：给定 stdin JSON、
临时状态目录和一个假 powershell 桩，只断言外部可观察结果——写出哪个状态
文件、三行内容、是否调用解析器、退出码。
"""
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
HOOK = REPO / "hooks" / "traffic-light.sh"
BASH = shutil.which("bash")

PINNED_PID = 4242
PINNED_FT = "133000000000000000"
PINNED_HWND = 900
PINNED_CWD = "C:/work/proj"

STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
sid=""; cwd=""; dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        -SessionId) sid="$2"; shift 2 ;;
        -Cwd) cwd="$2"; shift 2 ;;
        -StateDir) dir="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$STUB_PID" ] || exit 0
[ -n "$dir" ] || exit 0
mkdir -p "$dir"
{
    printf 'session_id=%s\n' "$sid"
    printf 'pid=%s\n' "$STUB_PID"
    printf 'creation_ft=%s\n' "$STUB_FT"
    printf 'hwnd=%s\n' "$STUB_HWND"
    printf 'hwnd_owner_pid=111\n'
    printf 'hwnd_owner_ft=%s\n' "$STUB_FT"
    printf 'project=proj\n'
    printf 'cwd=%s\n' "$cwd"
    printf 'updated=%s\n' "$(date +%s)"
    printf 'degraded=%s\n' "$STUB_DEGRADED"
} > "$dir/$sid.bind"
if [ "$STUB_HWND" != "0" ]; then touch "$dir/w$STUB_HWND.win"; fi
exit 0
"""


class Env:
    def __init__(self, root):
        self.root = root
        self.bin = root / "bin"
        self.state = root / "states"
        self.log = root / "stub.log"
        self.bin.mkdir()
        self.state.mkdir()
        self.stub = self.bin / "powershell"
        self.stub.write_text(STUB, encoding="utf-8", newline="\n")
        self.stub.chmod(0o755)

        self.vars = dict(os.environ)
        self.vars.pop("CODEBUDDY_SESSION_ID", None)
        self.vars.update({
            "TRAFFIC_LIGHT_STATE_DIR": self.state.as_posix(),
            "TRAFFIC_LIGHT_RESOLVE": (root / "resolve.ps1").as_posix(),
            "TRAFFIC_LIGHT_POWERSHELL": self.stub.as_posix(),
            "STUB_LOG": self.log.as_posix(),
            "STUB_PID": str(PINNED_PID),
            "STUB_FT": PINNED_FT,
            "STUB_HWND": str(PINNED_HWND),
            "STUB_DEGRADED": "0",
        })

    def calls(self):
        if not self.log.exists():
            return []
        return [line for line in self.log.read_text(encoding="utf-8").splitlines() if line]

    def state_path(self, pid=PINNED_PID):
        return self.state / f"{pid}.state"

    def bind_path(self, sid="sid-1"):
        return self.state / f"{sid}.bind"

    def write_bind(self, sid="sid-1", pid=PINNED_PID, ft=PINNED_FT,
                   hwnd=PINNED_HWND, cwd=PINNED_CWD, updated=None,
                   degraded=0):
        updated = int(time.time()) if updated is None else updated
        lines = [
            f"session_id={sid}",
            f"pid={pid}",
            f"creation_ft={ft}",
            f"hwnd={hwnd}",
            "hwnd_owner_pid=111",
            f"hwnd_owner_ft={ft}",
            "project=proj",
            f"cwd={cwd}",
            f"updated={updated}",
            f"degraded={degraded}",
        ]
        self.bind_path(sid).write_text("\n".join(lines) + "\n",
                                       encoding="utf-8", newline="\n")

    def touch_anchor(self, hwnd=PINNED_HWND, age=0):
        anchor = self.state / f"w{hwnd}.win"
        anchor.write_text("nonce=x\n", encoding="utf-8", newline="\n")
        if age:
            stamp = time.time() - age
            os.utime(anchor, (stamp, stamp))
        return anchor

    def run(self, event, payload=None, stdin=None):
        if stdin is None:
            stdin = json.dumps(payload) if payload is not None else ""
        return subprocess.run(
            [BASH, HOOK.as_posix(), event],
            input=stdin, text=True, capture_output=True,
            env=self.vars, cwd=str(REPO), timeout=60,
        )


@pytest.fixture
def env(tmp_path):
    return Env(tmp_path)


def _payload(sid="sid-1", cwd=PINNED_CWD, **extra):
    data = {"session_id": sid, "cwd": cwd}
    data.update(extra)
    return data


def _lines(path):
    return path.read_text(encoding="utf-8").splitlines()


def _assert_no_tmp(env):
    leftovers = [p.name for p in env.state.iterdir() if p.name.endswith(".tmp")]
    assert leftovers == []


# ============================================================
# tool — 高频事件，零额外进程
# ============================================================

def test_tool_writes_running_without_resolver(env):
    env.write_bind()
    env.touch_anchor()
    result = env.run("tool", _payload())
    assert result.returncode == 0
    assert _lines(env.state_path()) == ["running", PINNED_CWD, PINNED_FT]
    assert env.calls() == []


def test_tool_detects_failed_tool_response(env):
    env.write_bind()
    payload = _payload(tool_name="Bash", tool_response={"success": False})
    assert env.run("tool", payload).returncode == 0
    assert _lines(env.state_path())[0] == "failure"
    assert env.calls() == []


def test_tool_detects_error_field(env):
    env.write_bind()
    payload = _payload(tool_response={"error": "boom"})
    assert env.run("tool", payload).returncode == 0
    assert _lines(env.state_path())[0] == "failure"


def test_tool_detects_bash_nonzero_exit(env):
    env.write_bind()
    payload = _payload(tool_name="Bash", tool_response={"exitCode": 2})
    assert env.run("tool", payload).returncode == 0
    assert _lines(env.state_path())[0] == "failure"


def test_tool_without_bind_is_silent(env):
    result = env.run("tool", _payload())
    assert result.returncode == 0
    assert list(env.state.glob("*.state")) == []
    assert env.calls() == []


# ============================================================
# prompt — TTL 与自愈
# ============================================================

def test_prompt_writes_thinking_and_keeps_fresh_bind(env):
    env.write_bind()
    env.touch_anchor()
    assert env.run("prompt", _payload()).returncode == 0
    assert _lines(env.state_path())[0] == "thinking"
    assert env.calls() == []


def test_prompt_reruns_resolver_when_bind_expired(env):
    env.write_bind(updated=int(time.time()) - 120)
    env.touch_anchor()
    assert env.run("prompt", _payload()).returncode == 0
    assert len(env.calls()) == 1
    assert _lines(env.state_path())[0] == "thinking"
    assert _lines(env.state_path())[2] == PINNED_FT


def test_prompt_reruns_resolver_when_anchor_missing(env):
    env.write_bind()
    assert env.run("prompt", _payload()).returncode == 0
    assert len(env.calls()) == 1


def test_prompt_reruns_resolver_when_anchor_stale(env):
    env.write_bind()
    env.touch_anchor(age=30)
    assert env.run("prompt", _payload()).returncode == 0
    assert len(env.calls()) == 1


def test_prompt_reruns_resolver_when_degraded(env):
    env.write_bind(hwnd=0, degraded=1)
    assert env.run("prompt", _payload()).returncode == 0
    assert len(env.calls()) == 1


def test_prompt_without_bind_resolves_then_writes(env):
    assert env.run("prompt", _payload()).returncode == 0
    assert len(env.calls()) == 1
    assert _lines(env.state_path())[0] == "thinking"


# ============================================================
# notify / stop / end
# ============================================================

def test_notify_writes_waiting(env):
    env.write_bind()
    assert env.run("notify", _payload()).returncode == 0
    assert _lines(env.state_path())[0] == "waiting"


def test_stop_ignores_success_when_idle(env):
    env.write_bind()
    env.state_path().write_text("idle\n%s\n%s\n" % (PINNED_CWD, PINNED_FT),
                                encoding="utf-8", newline="\n")
    assert env.run("stop", _payload()).returncode == 0
    assert _lines(env.state_path())[0] == "idle"


def test_stop_writes_success_when_busy(env):
    env.write_bind()
    env.state_path().write_text("running\n%s\n%s\n" % (PINNED_CWD, PINNED_FT),
                                encoding="utf-8", newline="\n")
    assert env.run("stop", _payload()).returncode == 0
    assert _lines(env.state_path())[0] == "success"


def test_end_writes_ended_and_keeps_bind(env):
    env.write_bind()
    assert env.run("end", _payload()).returncode == 0
    assert _lines(env.state_path())[0] == "ended"
    assert env.bind_path().exists()


# ============================================================
# session-start
# ============================================================

def test_session_start_resolves_and_writes_idle(env):
    assert env.run("session-start", _payload()).returncode == 0
    assert len(env.calls()) == 1
    assert _lines(env.state_path()) == ["idle", PINNED_CWD, PINNED_FT]


def test_session_start_degraded_bind_still_writes_idle(env):
    env.vars["STUB_HWND"] = "0"
    env.vars["STUB_DEGRADED"] = "1"
    assert env.run("session-start", _payload()).returncode == 0
    assert _lines(env.state_path()) == ["idle", PINNED_CWD, PINNED_FT]


def test_session_start_without_pid_is_silent(env):
    env.vars["STUB_PID"] = ""
    result = env.run("session-start", _payload())
    assert result.returncode == 0
    assert list(env.state.glob("*.state")) == []


# ============================================================
# 通用：session_id 与原子写
# ============================================================

def test_missing_session_id_is_silent(env):
    env.write_bind()
    result = env.run("prompt", {"cwd": PINNED_CWD})
    assert result.returncode == 0
    assert list(env.state.glob("*.state")) == []
    assert env.calls() == []


def test_state_file_is_pid_keyed_and_leaves_no_tmp(env):
    env.write_bind()
    env.touch_anchor()
    env.run("tool", _payload())
    names = sorted(p.name for p in env.state.iterdir())
    assert "4242.state" in names
    assert "sid-1.bind" in names
    _assert_no_tmp(env)
    text = env.state_path().read_text(encoding="utf-8")
    assert text == "running\n%s\n%s\n" % (PINNED_CWD, PINNED_FT)


def test_prompt_uses_session_id_from_environment(env):
    env.write_bind()
    env.touch_anchor()
    result = env.run("prompt", "", stdin="")
    # 没有 stdin session_id 且没有环境变量 → 静默
    assert result.returncode == 0
    assert list(env.state.glob("*.state")) == []

    env.vars["CODEBUDDY_SESSION_ID"] = "sid-1"
    assert env.run("prompt", "", stdin="").returncode == 0
    assert _lines(env.state_path())[0] == "thinking"
