"""降级灯测试 — 全机一盏：只聚合 degraded=1 绑定，无会话即自灭。

被测 seam：
  - SessionView(degraded=True).snapshot()  —— 混合绑定过滤 / 同 pid 去重 / 标签素材
  - degraded_label(view)                  —— 标签 `<project> ?`
  - degraded_beat(guard, anchor, n)       —— 降级灯心跳自灭（3 次无会话 → 退出）
  - SessionView(hwnd=...).snapshot()       —— 窗口灯不受降级灯影响
"""
import os

from core.drawer import (
    EXIT_IDLE,
    DrawerGuard,
    badge_count,
    degraded_beat,
    degraded_label,
)
from core.session_view import InMemorySources, SessionView
from core.wire import (
    Anchor,
    Bind,
    StateEntry,
    anchor_path,
    read_anchor,
    write_anchor,
)

NOW = 1000.0


def _bind(pid, project, hwnd=0, degraded=True, updated=1000.0, sid=None):
    return Bind(
        session_id=sid or "s-%d" % pid,
        pid=pid,
        creation_ft="1",
        hwnd=hwnd,
        project=project,
        cwd="C:/work",
        updated=updated,
        degraded=degraded,
    )


def _state(pid, state="running", mtime=NOW):
    return StateEntry(pid=pid, state=state, cwd="C:/work",
                      creation_ft="1", mtime=mtime)


def _view(binds, states=None, hwnd=None, degraded=True):
    sources = InMemorySources(
        binds=binds,
        states={s.pid: s for s in (states or [])},
    )
    return SessionView(sources, hwnd=hwnd, degraded=degraded,
                       process_checker=lambda pid, ft: True, now=NOW).snapshot()


# ============================================================
# 混合绑定过滤
# ============================================================

def test_degraded_view_keeps_only_degraded_binds():
    snapshot = _view(
        [
            _bind(1, "alpha"),
            _bind(2, "beta", hwnd=555),          # 降级绑定忽略 hwnd
            _bind(3, "gamma", hwnd=100, degraded=False),
            _bind(4, "delta", hwnd=200, degraded=False),
            _bind(5, "epsilon", hwnd=300, degraded=False),
        ],
        [_state(pid) for pid in (1, 2, 3, 4, 5)],
    )

    assert snapshot.count == 2
    assert {session.pid for session in snapshot.sessions} == {1, 2}
    assert all(session.project in ("alpha", "beta")
               for session in snapshot.sessions)


# ============================================================
# 同 pid 多绑定只算 1
# ============================================================

def test_degraded_view_dedupes_same_pid():
    snapshot = _view(
        [
            _bind(1, "alpha", updated=1000.0, sid="old"),
            _bind(1, "alpha", updated=2000.0, sid="new"),
        ],
        [_state(1)],
    )

    assert snapshot.count == 1
    assert snapshot.sessions[0].session_id == "new"


# ============================================================
# 标签 <project> ?
# ============================================================

def test_degraded_label_marks_project_with_question_mark():
    snapshot = _view(
        [
            _bind(1, "alpha"),
            _bind(2, "beta", hwnd=555),
        ],
        [_state(1, "running"), _state(2, "waiting")],
    )

    # 主标签取优先级最高（waiting > running）那条会话的项目名
    assert snapshot.state == "waiting"
    assert degraded_label(snapshot) == "beta ?"


def test_degraded_label_empty_when_no_sessions():
    snapshot = _view([_bind(1, "alpha", degraded=False, hwnd=100)],
                     [_state(1)])
    assert snapshot.count == 0
    assert degraded_label(snapshot) == ""


# ============================================================
# 3 次心跳无降级绑定 → 自灭；期间新增 → 不退出
# ============================================================

def _anchor():
    return Anchor(nonce="n-1", drawer_pid=777, hwnd=0,
                  owner_pid=0, owner_ft="", started="1700000000")


def test_three_heartbeats_without_degraded_sessions_exit():
    guard = DrawerGuard(nonce="n-1")
    anchor = _anchor()

    assert degraded_beat(guard, anchor, 0) is None
    assert degraded_beat(guard, anchor, 0) is None
    decision = degraded_beat(guard, anchor, 0)

    assert decision is not None
    assert decision.reason == EXIT_IDLE
    assert decision.remove_anchor is True


def test_new_degraded_session_resets_heartbeat():
    guard = DrawerGuard(nonce="n-1")
    anchor = _anchor()

    assert degraded_beat(guard, anchor, 0) is None
    assert degraded_beat(guard, anchor, 0) is None
    assert degraded_beat(guard, anchor, 1) is None   # 新降级会话 → 重置
    assert degraded_beat(guard, anchor, 0) is None
    assert degraded_beat(guard, anchor, 0) is None
    assert degraded_beat(guard, anchor, 0) is not None


def test_degraded_lamp_removes_w0_anchor_on_exit(tmp_path):
    path = anchor_path(str(tmp_path), 0)
    assert os.path.basename(path) == "w0.win"
    write_anchor(path, _anchor())

    guard = DrawerGuard(nonce="n-1")
    for _ in range(2):
        assert degraded_beat(guard, read_anchor(path), 0) is None
    decision = degraded_beat(guard, read_anchor(path), 0)

    assert decision is not None
    assert decision.remove_anchor is True


# ============================================================
# 窗口灯不受降级灯影响
# ============================================================

def test_window_view_unaffected_by_degraded_bind():
    binds = [
        _bind(1, "alpha", hwnd=100, degraded=False),
        _bind(2, "beta", hwnd=100),            # 同 hwnd 的降级绑定
    ]
    states = [_state(1, "running"), _state(2, "failure")]

    window = _view(binds, states, hwnd=100, degraded=False)
    assert window.count == 1
    assert window.label == "alpha"
    assert window.state == "running"
    assert window.degraded is False

    degraded = _view(binds, states, degraded=True)
    assert degraded.count == 1
    assert degraded.label == "beta"


# ============================================================
# 角标：窗口灯才显示 ·N，降级灯不显示
# ============================================================

def test_degraded_lamp_never_draws_a_badge():
    snapshot = _view(
        [_bind(1, "alpha"), _bind(2, "beta")],
        [_state(1), _state(2)],
    )
    assert snapshot.count == 2
    assert badge_count(snapshot, degraded=True) == 0


def test_window_lamp_badge_counts_distinct_sessions():
    snapshot = _view(
        [_bind(1, "alpha", hwnd=100, degraded=False),
         _bind(2, "beta", hwnd=100, degraded=False)],
        [_state(1), _state(2)],
        hwnd=100,
        degraded=False,
    )
    assert snapshot.count == 2
    assert badge_count(snapshot, degraded=False) == 2
