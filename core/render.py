"""把 WindowView 画到灯上的唯一入口。

drawer 每 tick 只调 LampRenderer.render(view)：状态、标签、角标、边框 glow
怎么从视图算出来，都在这里。面板只管画与动，窗口只管渲染自己的边框，谁也不
再各自解释一遍 view。

降级灯不额外传模式：视图自己带 degraded（全机一盏、无 hwnd），标签加 "?"、
角标固定为 0 都由这个布尔决定。
"""


def lamp_label(view):
    """主标签：窗口灯用项目名；降级灯标成 `<project> ?`，无会话时不显示。"""
    if not view.degraded:
        return view.label
    if not view.count:
        return ""
    return ("%s ?" % view.label) if view.label else "?"


def lamp_badge(view):
    """角标数字：窗口灯数不同会话；降级灯是全机一盏，不画 ·N。"""
    return 0 if view.degraded else view.count


class LampRenderer:
    """一个 view 对应的全部可见输出（面板 + 窗口边框）。"""

    def __init__(self, panel, window):
        self._panel = panel
        self._window = window

    def render(self, view):
        self._panel.set_state(view.state)
        self._panel.set_project_name(lamp_label(view))
        self._panel.set_badge(lamp_badge(view))
        self._window.set_glow_color(view.state)
