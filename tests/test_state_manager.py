"""StateManager 状态聚合 + TTL + 信号测试（InMemoryStateSource 注入）"""
import time
import sys
from PyQt5.QtCore import QCoreApplication

_app = QCoreApplication(sys.argv)

from core.state_manager import (
    StateManager,
    InMemoryStateSource,
    STATE_TTL_SECONDS,
)


def _make_mgr(project=None):
    source = InMemoryStateSource()
    mgr = StateManager(project=project, source=source)
    return mgr, source


# ============================================================
# 初始状态
# ============================================================

def test_initial_state_is_idle():
    mgr, _ = _make_mgr()
    assert mgr.state == "idle"
    assert mgr.session_count == 0


# ============================================================
# 单条目状态读取
# ============================================================

def test_single_file_running():
    mgr, source = _make_mgr()
    source.add("mine", "running")
    mgr._poll()
    assert mgr.state == "running"
    assert mgr.session_count == 1


def test_single_file_success():
    mgr, source = _make_mgr()
    source.add("mine", "success")
    mgr._poll()
    assert mgr.state == "success"


def test_invalid_state_skipped():
    mgr, source = _make_mgr()
    source.add("mine", "invalid_state")
    mgr._poll()
    assert mgr.state == "idle"
    assert mgr.session_count == 0


# ============================================================
# 聚合优先级
# ============================================================

def test_aggregate_waiting_over_failure():
    mgr, source = _make_mgr()
    source.add("a", "failure")
    source.add("b", "waiting")
    mgr._poll()
    assert mgr.state == "waiting"


def test_aggregate_failure_over_thinking():
    mgr, source = _make_mgr()
    source.add("a", "thinking")
    source.add("b", "failure")
    mgr._poll()
    assert mgr.state == "failure"


def test_aggregate_thinking_over_running():
    mgr, source = _make_mgr()
    source.add("a", "running")
    source.add("b", "thinking")
    mgr._poll()
    assert mgr.state == "thinking"


def test_aggregate_running_over_success():
    mgr, source = _make_mgr()
    source.add("a", "success")
    source.add("b", "running")
    mgr._poll()
    assert mgr.state == "running"


def test_aggregate_success_over_idle():
    mgr, source = _make_mgr()
    source.add("a", "idle")
    source.add("b", "success")
    mgr._poll()
    assert mgr.state == "success"


def test_aggregate_all_idle():
    mgr, source = _make_mgr()
    source.add("a", "idle")
    source.add("b", "idle")
    source.add("c", "idle")
    mgr._poll()
    assert mgr.state == "idle"


# ============================================================
# TTL 过期
# ============================================================

def test_success_ttl_expired():
    mgr, source = _make_mgr()
    past = time.time() - STATE_TTL_SECONDS["success"] - 1
    source.add("mine", "success", mtime=past)
    mgr._poll()
    assert mgr.state == "idle"
    assert mgr.session_count == 0
    # 过期条目从 source 中移除
    assert len(source.read_all()) == 0


def test_failure_ttl_not_expired_early():
    mgr, source = _make_mgr()
    recent = time.time() - 5
    source.add("mine", "failure", mtime=recent)
    mgr._poll()
    assert mgr.state == "failure"
    assert mgr.session_count == 1
    assert len(source.read_all()) == 1  # 未过期，未删除


def test_idle_never_expires():
    mgr, source = _make_mgr()
    very_old = time.time() - 99999
    source.add("mine", "idle", mtime=very_old)
    mgr._poll()
    assert mgr.state == "idle"
    assert mgr.session_count == 1


# ============================================================
# 过期清理
# ============================================================

def test_stale_entry_removed_from_source():
    mgr, source = _make_mgr()
    past = time.time() - STATE_TTL_SECONDS["thinking"] - 1
    source.add("mine", "thinking", mtime=past)
    mgr._poll()
    assert len(source.read_all()) == 0


def test_only_expired_entries_cleaned():
    mgr, source = _make_mgr()
    past = time.time() - STATE_TTL_SECONDS["success"] - 1
    source.add("old", "success", mtime=past)
    source.add("current", "running")
    mgr._poll()
    assert mgr.state == "running"
    assert mgr.session_count == 1
    # old 被删，current 还在
    entries = source.read_all()
    assert len(entries) == 1
    assert entries[0].project == "current"


# ============================================================
# 项目目录路径
# ============================================================

def test_project_dir_extracted():
    mgr, source = _make_mgr()
    source.add("mine", "running", project_dir="/test/dir")
    mgr._poll()
    assert mgr.project_dir == "/test/dir"


def test_project_dir_empty_if_missing():
    mgr, source = _make_mgr()
    source.add("mine", "running")
    mgr._poll()
    assert mgr.project_dir == ""


# ============================================================
# --project 过滤
# ============================================================

def test_project_filter_only_matches_named():
    mgr, source = _make_mgr(project="mine")
    source.add("mine", "running")
    source.add("other", "failure")
    mgr._poll()
    assert mgr.state == "running"
    assert mgr.session_count == 1


def test_project_filter_no_match():
    mgr, source = _make_mgr(project="mine")
    source.add("other", "running")
    mgr._poll()
    assert mgr.state == "idle"
    assert mgr.session_count == 0


# ============================================================
# 信号发射
# ============================================================

def test_state_changed_signal_emitted():
    mgr, source = _make_mgr()
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))
    source.add("mine", "running")
    mgr._poll()
    assert calls == ["running"]


def test_same_state_no_duplicate_signal():
    mgr, source = _make_mgr()
    source.add("mine", "running")
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))
    mgr._poll()
    assert calls == ["running"]
    mgr._poll()
    assert calls == ["running"]  # 无重复信号


def test_full_priority_chain_signals():
    mgr, source = _make_mgr()
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))

    # idle (初始)
    mgr._poll()
    assert calls == []

    # idle → success
    source.add("a", "success")
    mgr._poll()
    assert mgr.state == "success"

    # success → running
    source.add("b", "running")
    mgr._poll()
    assert mgr.state == "running"

    # running → failure
    source.add("c", "failure")
    mgr._poll()
    assert mgr.state == "failure"

    # 删除 c → running
    source.remove("c")
    mgr._poll()
    assert mgr.state == "running"

    # 删除 b → success
    source.remove("b")
    mgr._poll()
    assert mgr.state == "success"

    # 删除 a → idle
    source.remove("a")
    mgr._poll()
    assert mgr.state == "idle"

    assert calls == ["success", "running", "failure", "running", "success", "idle"]


def test_project_dir_changed_signal():
    mgr, source = _make_mgr()
    calls = []
    mgr.project_dir_changed.connect(lambda d: calls.append(d))

    source.add("mine", "running", project_dir="/path/one")
    mgr._poll()
    assert calls == ["/path/one"]

    # 同路径不重复触发
    mgr._poll()
    assert calls == ["/path/one"]

    # 路径变化触发
    source.add("mine", "running", project_dir="/path/two")
    mgr._poll()
    assert calls == ["/path/one", "/path/two"]


# ============================================================
# session_count
# ============================================================

def test_session_count_matches_entries():
    mgr, source = _make_mgr()
    source.add("a", "running")
    source.add("b", "thinking")
    source.add("c", "idle")
    mgr._poll()
    assert mgr.session_count == 3


def test_session_count_zero_when_no_entries():
    mgr, source = _make_mgr()
    mgr._poll()
    assert mgr.session_count == 0
