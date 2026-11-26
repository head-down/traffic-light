"""窗口矩形选择 — 纯函数，不触碰真实窗口。

规格 §解析：最小化窗口的 GetWindowRect 只有 159x27 的桩尺寸，尺寸与定位
必须改用 GetWindowPlacement 的还原矩形；IsIconic 单独作为最小化信号。
最大化 / 正常窗口仍要真实矩形，否则灯会贴到旧的还原位置。
"""
from core.terminal_tracker import choose_window_rect

VISIBLE = (0, 0, 1000, 800)
RESTORE = (100, 100, 900, 700)
STUB = (0, 0, 159, 27)


def test_iconic_window_uses_restore_rect():
    assert choose_window_rect(VISIBLE, RESTORE, iconic=True) == RESTORE


def test_stub_sized_visible_rect_uses_restore_rect():
    assert choose_window_rect(STUB, RESTORE, iconic=False) == RESTORE


def test_normal_visible_rect_is_kept():
    assert choose_window_rect(VISIBLE, RESTORE, iconic=False) == VISIBLE


def test_missing_restore_falls_back_to_visible_rect():
    assert choose_window_rect(STUB, None, iconic=True) == STUB
