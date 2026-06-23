"""state_manager 文件系统轮询 + 聚合状态机单元测试"""
import sys
import os
import time
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from PyQt5.QtCore import QCoreApplication
_app = QCoreApplication(sys.argv)

from core import state_manager as sm
from core.state_manager import StateManager, VALID_STATES


# ============================================================
# 辅助函数
# ============================================================

def _write_state(tmpdir, project, state, project_dir="", mtime=None):
    """写入一个 .state 文件，可指定 mtime 用于 TTL 测试"""
    fpath = os.path.join(tmpdir, f"{project}.state")
    content = f"{state}"
    if project_dir:
        content += f"\n{project_dir}"
    with open(fpath, "w") as f:
        f.write(content)
    if mtime is not None:
        os.utime(fpath, (mtime, mtime))
    return fpath


# ============================================================
# 初始状态
# ============================================================

def test_initial_state_is_idle(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    mgr = StateManager()
    assert mgr.state == "idle"
    assert mgr.session_count == 0


# ============================================================
# 单文件状态读取
# ============================================================

def test_single_file_running(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    _write_state(tmp_path, "mine", "running")

    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.state == "running"
    assert mgr.session_count == 1


def test_single_file_success(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    _write_state(tmp_path, "mine", "success")

    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.state == "success"


def test_invalid_state_skipped(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    _write_state(tmp_path, "mine", "invalid_state")

    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.state == "idle"
    assert mgr.session_count == 0


def test_non_state_files_ignored(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    # 写一个非 .state 文件
    with open(os.path.join(tmp_path, "README.txt"), "w") as f:
        f.write("not a state file")

    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.state == "idle"
    assert mgr.session_count == 0


# ============================================================
# 聚合优先级
# ============================================================

def test_aggregate_waiting_over_failure(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    _write_state(tmp_path, "a", "failure")
    _write_state(tmp_path, "b", "waiting")

    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.state == "waiting"  # waiting > failure


def test_aggregate_failure_over_thinking(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    _write_state(tmp_path, "a", "thinking")
    _write_state(tmp_path, "b", "failure")

    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.state == "failure"  # failure > thinking


def test_aggregate_thinking_over_running(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    _write_state(tmp_path, "a", "running")
    _write_state(tmp_path, "b", "thinking")

    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.state == "thinking"  # thinking > running


def test_aggregate_running_over_success(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    _write_state(tmp_path, "a", "success")
    _write_state(tmp_path, "b", "running")

    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.state == "running"  # running > success


def test_aggregate_success_over_idle(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    _write_state(tmp_path, "a", "idle")
    _write_state(tmp_path, "b", "success")

    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.state == "success"  # success > idle


def test_aggregate_all_idle(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    _write_state(tmp_path, "a", "idle")
    _write_state(tmp_path, "b", "idle")
    _write_state(tmp_path, "c", "idle")

    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.state == "idle"


# ============================================================
# TTL 过期
# ============================================================

def test_success_ttl_expired(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    past_time = time.time() - sm.STATE_TTL_SECONDS["success"] - 1
    fpath = _write_state(tmp_path, "mine", "success", mtime=past_time)

    mgr = StateManager()
    mgr._poll_from_dir()
    # success TTL = 8s，文件过期后应被清理，聚合回 idle
    assert mgr.state == "idle"
    assert mgr.session_count == 0
    assert not os.path.exists(fpath)  # 文件被删除


def test_failure_ttl_not_expired_early(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    # failure TTL = 30s，写 5s 前的文件应仍有效
    recent_time = time.time() - 5
    _write_state(tmp_path, "mine", "failure", mtime=recent_time)

    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.state == "failure"  # 未过期
    assert mgr.session_count == 1


def test_idle_never_expires(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    # idle TTL = inf，写一个很久以前的文件
    very_old = time.time() - 99999
    _write_state(tmp_path, "mine", "idle", mtime=very_old)

    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.state == "idle"
    assert mgr.session_count == 1  # idle 永不过期


# ============================================================
# 过期文件清理
# ============================================================

def test_stale_file_removed_from_disk(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    past_time = time.time() - sm.STATE_TTL_SECONDS["thinking"] - 1
    fpath = _write_state(tmp_path, "mine", "thinking", mtime=past_time)

    mgr = StateManager()
    mgr._poll_from_dir()
    assert not os.path.exists(fpath)  # 文件被物理删除


def test_only_expired_files_cleaned(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    # 一个过期文件 + 一个当前文件
    past_time = time.time() - sm.STATE_TTL_SECONDS["success"] - 1
    fpath_old = _write_state(tmp_path, "old", "success", mtime=past_time)
    _write_state(tmp_path, "current", "running")

    mgr = StateManager()
    mgr._poll_from_dir()
    assert not os.path.exists(fpath_old)  # 过期文件被删
    assert mgr.state == "running"  # 当前文件仍在
    assert mgr.session_count == 1  # 只有 current


# ============================================================
# 项目目录路径提取
# ============================================================

def test_project_dir_extracted_from_file(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    _write_state(tmp_path, "mine", "running", project_dir="/test/dir")

    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.project_dir == "/test/dir"


def test_project_dir_empty_if_missing(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    _write_state(tmp_path, "mine", "running")  # 无第二行

    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.project_dir == ""


# ============================================================
# --project 过滤
# ============================================================

def test_project_filter_only_matches_named(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    _write_state(tmp_path, "mine", "running")
    _write_state(tmp_path, "other", "failure")

    mgr = StateManager(project="mine")
    mgr._poll_from_dir()
    assert mgr.state == "running"  # 只看 mine，忽略 other 的 failure
    assert mgr.session_count == 1


def test_project_filter_no_match(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    _write_state(tmp_path, "other", "running")

    mgr = StateManager(project="mine")
    mgr._poll_from_dir()
    assert mgr.state == "idle"  # 没有 mine.state
    assert mgr.session_count == 0


# ============================================================
# 信号发射
# ============================================================

def test_state_changed_signal_emitted(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    mgr = StateManager()
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))

    _write_state(tmp_path, "mine", "running")
    mgr._poll_from_dir()
    assert calls == ["running"]


def test_same_state_no_duplicate_signal(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    _write_state(tmp_path, "mine", "running")

    mgr = StateManager()
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))

    mgr._poll_from_dir()
    assert calls == ["running"]

    # 再次轮询，状态未变，不触发信号
    mgr._poll_from_dir()
    assert calls == ["running"]


def test_full_priority_chain_signals(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    mgr = StateManager()
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))

    # idle → (初始 poll，无文件)
    mgr._poll_from_dir()
    assert calls == []  # 初始就是 idle

    # idle → success
    _write_state(tmp_path, "a", "success")
    mgr._poll_from_dir()
    assert mgr.state == "success"

    # success → running (running > success)
    _write_state(tmp_path, "b", "running")
    mgr._poll_from_dir()
    assert mgr.state == "running"

    # running → failure (failure > running)
    _write_state(tmp_path, "c", "failure")
    mgr._poll_from_dir()
    assert mgr.state == "failure"

    # 删除 c → 回到 running
    os.remove(os.path.join(tmp_path, "c.state"))
    mgr._poll_from_dir()
    assert mgr.state == "running"

    # 删除 b → 回到 success
    os.remove(os.path.join(tmp_path, "b.state"))
    mgr._poll_from_dir()
    assert mgr.state == "success"

    # 删除 a → 回到 idle
    os.remove(os.path.join(tmp_path, "a.state"))
    mgr._poll_from_dir()
    assert mgr.state == "idle"

    assert calls == ["success", "running", "failure", "running", "success", "idle"]


def test_project_dir_changed_signal(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    mgr = StateManager()
    calls = []
    mgr.project_dir_changed.connect(lambda d: calls.append(d))

    _write_state(tmp_path, "mine", "running", project_dir="/path/one")
    mgr._poll_from_dir()
    assert calls == ["/path/one"]

    # 同路径不重复触发
    mgr._poll_from_dir()
    assert calls == ["/path/one"]

    # 路径变化触发
    _write_state(tmp_path, "mine", "running", project_dir="/path/two")
    mgr._poll_from_dir()
    assert calls == ["/path/one", "/path/two"]


# ============================================================
# session_count
# ============================================================

def test_session_count_matches_files(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    _write_state(tmp_path, "a", "running")
    _write_state(tmp_path, "b", "thinking")
    _write_state(tmp_path, "c", "idle")

    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.session_count == 3


def test_session_count_zero_when_no_files(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "_STATE_DIR", str(tmp_path))
    mgr = StateManager()
    mgr._poll_from_dir()
    assert mgr.session_count == 0
