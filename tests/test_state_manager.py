"""state_manager 多会话聚合 + 状态机单元测试"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from PyQt5.QtCore import QCoreApplication
_app = QCoreApplication(sys.argv)

from core.state_manager import StateManager, VALID_STATES


def test_initial_state_is_idle():
    mgr = StateManager()
    assert mgr.state == "idle"
    assert mgr.session_count == 0


# ---- 会话管理 ----

def test_update_session_creates_entry():
    mgr = StateManager()
    mgr.update_session("s1", "running")
    assert mgr.session_count == 1
    assert mgr.state == "running"


def test_update_session_updates_existing():
    mgr = StateManager()
    mgr.update_session("s1", "running")
    mgr.update_session("s1", "success")
    assert mgr.session_count == 1
    assert mgr.state == "success"


def test_remove_session():
    mgr = StateManager()
    mgr.update_session("s1", "running")
    mgr.remove_session("s1")
    assert mgr.session_count == 0
    assert mgr.state == "idle"


def test_invalid_state_rejected():
    mgr = StateManager()
    assert mgr.update_session("s1", "invalid") is False
    assert mgr.session_count == 0


# ---- 聚合优先级 ----

def test_aggregate_failure_over_running():
    mgr = StateManager()
    mgr.update_session("s1", "running")
    mgr.update_session("s2", "failure")
    assert mgr.state == "failure"


def test_aggregate_running_over_success():
    mgr = StateManager()
    mgr.update_session("s1", "success")
    mgr.update_session("s2", "running")
    assert mgr.state == "running"


def test_aggregate_success_over_idle():
    mgr = StateManager()
    mgr.update_session("s1", "idle")
    mgr.update_session("s2", "success")
    assert mgr.state == "success"


def test_aggregate_all_idle():
    mgr = StateManager()
    mgr.update_session("s1", "idle")
    mgr.update_session("s2", "idle")
    mgr.update_session("s3", "idle")
    assert mgr.state == "idle"


def test_aggregate_full_priority_chain():
    """红灯 > 黄灯 > 绿灯 > 空闲"""
    mgr = StateManager()
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))

    mgr.update_session("a", "idle")
    assert mgr.state == "idle"
    # 初始 idle → 同状态，不触发信号

    mgr.update_session("a", "success")
    assert mgr.state == "success"

    mgr.update_session("b", "running")
    assert mgr.state == "running"  # running > success

    mgr.update_session("c", "failure")
    assert mgr.state == "failure"  # failure > running

    mgr.remove_session("c")
    assert mgr.state == "running"  # 回到 running

    mgr.remove_session("b")
    assert mgr.state == "success"  # 回到 success

    mgr.remove_session("a")
    assert mgr.state == "idle"

    assert calls == ["success", "running", "failure", "running", "success", "idle"]


def test_same_state_no_duplicate_signal():
    mgr = StateManager()
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))

    mgr.update_session("s1", "running")
    assert calls == ["running"]

    mgr.update_session("s2", "running")  # 聚合状态未变
    assert calls == ["running"]  # 不重复触发


# ---- 兼容旧接口 ----

def test_update_state_uses_default_session():
    mgr = StateManager()
    mgr.update_state("running")
    assert mgr.state == "running"
    assert mgr.session_count == 1


# ---- 信号发射 ----

def test_state_changed_signal_when_aggregated_changes():
    mgr = StateManager()
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))

    mgr.update_session("s1", "running")
    mgr.update_session("s2", "success")  # running > success, 聚合不变
    assert calls == ["running"]
