"""render 单入口：一个 WindowView 只经过 LampRenderer 变成可见输出。

用假面板/假窗口记录调用，断言的是「视图 → 各绘制面」的对应关系，不碰 Qt
的绘制细节。面板怎么画、窗口边框怎么渐变，各有自己的测试。
"""
from core.render import LampRenderer, lamp_badge, lamp_label
from core.session_view import WindowView


class FakePanel:
    def __init__(self):
        self.calls = []

    def set_state(self, state):
        self.calls.append(("state", state))

    def set_project_name(self, name):
        self.calls.append(("label", name))

    def set_badge(self, count):
        self.calls.append(("badge", count))


class FakeWindow:
    def __init__(self):
        self.calls = []

    def set_glow_color(self, state):
        self.calls.append(("glow", state))


def _view(state="running", label="alpha", count=2, degraded=False):
    return WindowView(state, label, count, degraded, [])


def _render(view):
    panel = FakePanel()
    window = FakeWindow()
    LampRenderer(panel, window).render(view)
    return panel.calls, window.calls


def test_window_lamp_renders_state_label_badge_and_glow():
    panel, window = _render(_view(state="waiting", label="beta", count=3))
    assert panel == [
        ("state", "waiting"),
        ("label", "beta"),
        ("badge", 3),
    ]
    assert window == [("glow", "waiting")]


def test_degraded_lamp_marks_the_project_and_draws_no_badge():
    panel, window = _render(
        _view(state="failure", label="beta", count=2, degraded=True))
    assert panel == [
        ("state", "failure"),
        ("label", "beta ?"),
        ("badge", 0),
    ]
    assert window == [("glow", "failure")]


def test_empty_view_renders_an_idle_blank_lamp():
    panel, _ = _render(_view(state="idle", label="", count=0))
    assert panel == [("state", "idle"), ("label", ""), ("badge", 0)]


def test_empty_degraded_view_has_no_label():
    view = _view(state="idle", label="", count=0, degraded=True)
    assert lamp_label(view) == ""
    assert lamp_badge(view) == 0


def test_degraded_lamp_without_a_project_still_marks_unknown():
    view = _view(state="running", label="", count=1, degraded=True)
    assert lamp_label(view) == "?"
