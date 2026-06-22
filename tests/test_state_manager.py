"""state_manager 状态机单元测试"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from PyQt5.QtCore import QCoreApplication, QTimer, QEventLoop
from PyQt5.QtTest import QTest

# 必须在任何 PyQt 对象创建前初始化 QApplication（只建一次）
_app = QCoreApplication(sys.argv)

from core.state_manager import StateManager, VALID_STATES


def _wait_ms(ms):
    """等待 ms 毫秒，保持 Qt 事件循环运行"""
    loop = QEventLoop()
    QTimer.singleShot(ms, loop.quit)
    loop.exec_()


# ---- 基础状态转换 ----

def test_initial_state_is_idle():
    mgr = StateManager()
    assert mgr.state == "idle"


def test_update_to_valid_states():
    mgr = StateManager()
    for s in VALID_STATES:
        assert mgr.update_state(s) is True
        assert mgr.state == s


def test_update_to_invalid_state_returns_false():
    mgr = StateManager()
    assert mgr.update_state("invalid") is False
    assert mgr.state == "idle"


def test_update_to_invalid_state_does_not_change():
    mgr = StateManager()
    mgr.update_state("running")
    assert mgr.update_state("garbage") is False
    assert mgr.state == "running"


def test_same_state_no_signal():
    """同状态不触发信号"""
    mgr = StateManager()
    mgr.update_state("running")
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))
    assert mgr.update_state("running") is True
    assert len(calls) == 0


def test_state_changed_signal_emitted():
    mgr = StateManager()
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))
    mgr.update_state("running")
    assert calls == ["running"]
    mgr.update_state("success")
    assert calls == ["running", "success"]


def test_reset_to_idle_explicitly():
    mgr = StateManager()
    mgr.update_state("running")
    mgr.update_state("idle")
    assert mgr.state == "idle"


# ---- auto-reset 定时器测试 ----

def test_auto_reset_after_failure():
    """failure → 5 秒后自动回 idle"""
    mgr = StateManager()
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))

    mgr.update_state("failure")
    assert mgr.state == "failure"
    assert calls == ["failure"]

    _wait_ms(6000)
    assert mgr.state == "idle"
    assert calls == ["failure", "idle"]


def test_auto_reset_after_success():
    """success → 5 秒后自动回 idle"""
    mgr = StateManager()
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))

    mgr.update_state("success")
    assert mgr.state == "success"
    assert calls == ["success"]

    _wait_ms(6000)
    assert mgr.state == "idle"
    assert calls == ["success", "idle"]


def test_running_does_not_auto_reset():
    """running 状态不会自动回 idle"""
    mgr = StateManager()
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))

    mgr.update_state("running")
    assert mgr.state == "running"

    _wait_ms(6000)
    assert mgr.state == "running"
    assert calls == ["running"]


def test_auto_reset_timer_cancelled_by_running():
    """failure → 切到 running 应该取消 timer"""
    mgr = StateManager()
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))

    mgr.update_state("failure")
    mgr.update_state("running")  # 取消 auto-reset
    assert mgr.state == "running"
    assert calls == ["failure", "running"]

    _wait_ms(6000)
    assert mgr.state == "running"


def test_full_state_cycle():
    """idle → running → success → (auto) idle → running → failure → (auto) idle"""
    mgr = StateManager()
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))

    mgr.update_state("running")
    mgr.update_state("success")
    mgr.update_state("running")
    mgr.update_state("failure")

    assert calls == ["running", "success", "running", "failure"]


def test_auto_reset_does_not_trigger_while_running():
    """running → success → 切回 running → 不计时"""
    mgr = StateManager()
    mgr.update_state("running")
    mgr.update_state("success")
    mgr.update_state("running")  # 立刻切回 running

    _wait_ms(6000)
    assert mgr.state == "running"  # 不应该变 idle


def test_multiple_auto_reset_cycles():
    """多次 failure/success 自动回 idle"""
    mgr = StateManager()
    calls = []
    mgr.state_changed.connect(lambda s: calls.append(s))

    mgr.update_state("failure")
    _wait_ms(6000)
    assert mgr.state == "idle"

    mgr.update_state("success")
    _wait_ms(6000)
    assert mgr.state == "idle"

    mgr.update_state("failure")
    _wait_ms(6000)
    assert mgr.state == "idle"

    # 每个终端状态 + 对应的 idle
    assert calls == ["failure", "idle", "success", "idle", "failure", "idle"]
