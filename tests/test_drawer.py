"""drawer 自灭判定测试 — 纯逻辑，不建真窗口。

覆盖 ticket 列出的判定：nonce 被替换、owner 不匹配、连续零活 pid、
hwnd 视图只聚合本窗绑定、角标。
"""
import os

from core.drawer import (
    EXIT_IDLE,
    EXIT_NONCE,
    EXIT_OWNER,
    Anchor,
    DrawerGuard,
    anchor_path,
    read_anchor,
    write_anchor,
)
from core.light_panel import format_badge
from core.session_view import Bind, InMemorySources, SessionView, StateEntry


def _anchor(nonce="abc", hwnd=100, owner_pid=42, owner_ft="111",
            drawer_pid=0):
    return Anchor(nonce=nonce, drawer_pid=drawer_pid, hwnd=hwnd,
                  owner_pid=owner_pid, owner_ft=owner_ft, started="1700000000")


# ============================================================
# 锚读写
# ============================================================

def test_anchor_roundtrip(tmp_path):
    path = anchor_path(str(tmp_path), 100)
    assert os.path.basename(path) == "w100.win"
    write_anchor(path, _anchor(drawer_pid=777))

    anchor = read_anchor(path)
    assert anchor.nonce == "abc"
    assert anchor.hwnd == 100
    assert anchor.owner_pid == 42
    assert anchor.owner_ft == "111"
    assert anchor.drawer_pid == 777


def test_read_missing_anchor_returns_none(tmp_path):
    assert read_anchor(anchor_path(str(tmp_path), 100)) is None


# ============================================================
# nonce 被替换
# ============================================================

def test_nonce_mismatch_exits_without_removing_anchor(tmp_path):
    path = anchor_path(str(tmp_path), 100)
    write_anchor(path, _anchor(nonce="new-nonce"))
    before = open(path, "rb").read()

    guard = DrawerGuard(nonce="old-nonce")
    decision = guard.check(read_anchor(path))

    assert decision is not None
    assert decision.reason == EXIT_NONCE
    assert decision.remove_anchor is False
    assert open(path, "rb").read() == before


def test_missing_anchor_counts_as_superseded(tmp_path):
    guard = DrawerGuard(nonce="abc")
    decision = guard.check(None)
    assert decision is not None
    assert decision.reason == EXIT_NONCE
    assert decision.remove_anchor is False


def test_matching_nonce_continues(tmp_path):
    path = anchor_path(str(tmp_path), 100)
    write_anchor(path, _anchor(nonce="abc"))
    assert DrawerGuard(nonce="abc").check(read_anchor(path),
                                          live_count=1) is None


# ============================================================
# owner（pid + 创建时间）不匹配
# ============================================================

def test_owner_pid_mismatch_exits():
    guard = DrawerGuard(nonce="abc")
    decision = guard.check(_anchor(owner_pid=42, owner_ft="111"),
                           owner=(43, "111"), live_count=1)
    assert decision is not None
    assert decision.reason == EXIT_OWNER
    assert decision.remove_anchor is True


def test_owner_creation_time_mismatch_exits():
    guard = DrawerGuard(nonce="abc")
    decision = guard.check(_anchor(owner_pid=42, owner_ft="111"),
                           owner=(42, "999"), live_count=1)
    assert decision is not None
    assert decision.reason == EXIT_OWNER


def test_owner_match_continues():
    guard = DrawerGuard(nonce="abc")
    assert guard.check(_anchor(owner_pid=42, owner_ft="111"),
                       owner=(42, "111"), live_count=1) is None


def test_owner_unknown_creation_time_is_tolerated():
    guard = DrawerGuard(nonce="abc")
    assert guard.check(_anchor(owner_pid=42, owner_ft=""),
                       owner=(42, ""), live_count=1) is None


# ============================================================
# 连续零活 pid
# ============================================================

def test_three_consecutive_zero_live_sessions_exit():
    guard = DrawerGuard(nonce="abc")
    anchor = _anchor()
    assert guard.check(anchor, live_count=0) is None
    assert guard.check(anchor, live_count=0) is None
    decision = guard.check(anchor, live_count=0)
    assert decision is not None
    assert decision.reason == EXIT_IDLE
    assert decision.remove_anchor is True


def test_recovery_resets_zero_live_streak():
    guard = DrawerGuard(nonce="abc")
    anchor = _anchor()
    guard.check(anchor, live_count=0)
    guard.check(anchor, live_count=0)
    assert guard.check(anchor, live_count=1) is None
    assert guard.check(anchor, live_count=0) is None
    assert guard.check(anchor, live_count=0) is None
    assert guard.check(anchor, live_count=0) is not None


# ============================================================
# hwnd 视图只聚合本窗绑定
# ============================================================

def _bind(pid, hwnd, project, updated=1000.0):
    return Bind(session_id="s-%d" % pid, pid=pid, creation_ft="1",
                hwnd=hwnd, hwnd_owner_pid=42, hwnd_owner_ft="111",
                project=project, cwd="C:/work", updated=updated)


def _state(pid, state, mtime=1000.0):
    return StateEntry(pid=pid, state=state, cwd="C:/work",
                      creation_ft="1", mtime=mtime)


def _snapshot(hwnd, binds, states):
    sources = InMemorySources(
        binds=binds,
        states={s.pid: s for s in states},
    )
    view = SessionView(sources, hwnd=hwnd,
                       process_checker=lambda pid, ft: True, now=1000.0)
    return view.snapshot()


def test_window_view_ignores_other_windows():
    view = _snapshot(
        100,
        [_bind(1, 100, "alpha"), _bind(2, 200, "beta")],
        [_state(1, "running"), _state(2, "failure")],
    )
    assert view.count == 1
    assert view.state == "running"
    assert view.label == "alpha"


def test_window_view_aggregates_same_window_tabs():
    view = _snapshot(
        100,
        [_bind(1, 100, "alpha"), _bind(2, 100, "beta")],
        [_state(1, "running"), _state(2, "failure")],
    )
    assert view.count == 2
    assert view.state == "failure"
    assert view.label == "beta"


# ============================================================
# 角标
# ============================================================

def test_badge_hidden_for_less_than_two_sessions():
    assert format_badge(0) == ""
    assert format_badge(1) == ""


def test_badge_shows_distinct_session_count():
    assert format_badge(2) == "·2"
    assert format_badge(7) == "·7"

