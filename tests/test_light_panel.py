"""LightPanel.set_state 的幂等性：drawer 每 300ms 刷一次，状态没变不能重启动画。"""
import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PyQt5.QtWidgets import QApplication

from core.light_panel import LightPanel


@pytest.fixture(scope="module")
def app():
    instance = QApplication.instance() or QApplication([])
    yield instance


@pytest.fixture()
def panel(app):
    widget = LightPanel()
    yield widget
    widget.deleteLater()


def test_same_state_does_not_restart_the_chase(panel):
    panel.set_state("thinking")
    panel._chase_index = 1
    panel.set_state("thinking")
    assert panel._chase_index == 1


def test_same_state_does_not_restart_the_alarm(panel):
    panel.set_state("waiting")
    panel._alarm_index = 1
    panel.set_state("waiting")
    assert panel._alarm_index == 1


def test_real_state_change_still_restarts(panel):
    panel.set_state("thinking")
    panel._chase_index = 1
    panel.set_state("running")
    panel.set_state("thinking")
    assert panel._chase_index == 0


def test_first_idle_state_starts_the_idle_breathing(panel):
    assert panel._state is None
    panel.set_state("idle")
    assert panel._state == "idle"
    assert panel._idle_breathe.state() == panel._idle_breathe.Running
