"""SessionView 聚合 seam 测试：bind ⋈ state → 按 hwnd 过滤 → 按 pid 聚合。

断言的是外部可观察结果（哪盏灯、什么状态、标签、角标），不碰内部实现。
"""
import os

import pytest

from core.session_view import (
    Bind,
    FileSystemSources,
    InMemorySources,
    SessionView,
    StateEntry,
)


NOW = 1000.0


def _bind(pid, hwnd=100, project="proj", session_id=None, updated=NOW,
          degraded=False, creation_ft="1", cwd="C:/work"):
    return Bind(
        session_id=session_id or f"s-{pid}-{updated}",
        pid=pid,
        creation_ft=creation_ft,
        hwnd=hwnd,
        hwnd_owner_pid=1,
        hwnd_owner_ft="2",
        project=project,
        cwd=cwd,
        updated=updated,
        degraded=degraded,
    )


def _state(pid, state, cwd="C:/work", creation_ft="1", mtime=NOW):
    return StateEntry(pid=pid, state=state, cwd=cwd,
                      creation_ft=creation_ft, mtime=mtime)


def _sources(binds=(), states=()):
    return InMemorySources(binds=list(binds),
                           states={s.pid: s for s in states})


def _view(sources, hwnd=100, degraded=False, alive=None, now=NOW):
    return SessionView(
        sources,
        hwnd=hwnd,
        degraded=degraded,
        process_checker=alive if alive is not None else (lambda pid, ft: True),
        now=now,
    )


# ============================================================
# 空视图 / 单会话
# ============================================================

def test_empty_window_is_idle():
    snap = _view(_sources()).snapshot()
    assert snap.state == "idle"
    assert snap.label == ""
    assert snap.count == 0
    assert snap.sessions == []
    assert snap.degraded is False


def test_single_session_running():
    sources = _sources([_bind(1001, project="alpha")],
                       [_state(1001, "running")])
    snap = _view(sources).snapshot()
    assert snap.state == "running"
    assert snap.label == "alpha"
    assert snap.count == 1
    assert snap.degraded is False


# ============================================================
# 按 hwnd 过滤：同 cwd 两个 pid 互不覆盖
# ============================================================

def test_same_cwd_two_pids_do_not_overwrite_each_other():
    sources = _sources(
        [_bind(1001, hwnd=100, project="alpha"),
         _bind(1002, hwnd=200, project="beta")],
        [_state(1001, "failure"), _state(1002, "running")],
    )
    first = _view(sources, hwnd=100).snapshot()
    second = _view(sources, hwnd=200).snapshot()

    assert (first.state, first.label, first.count) == ("failure", "alpha", 1)
    assert (second.state, second.label, second.count) == ("running", "beta", 1)


def test_bind_from_other_hwnd_is_ignored():
    sources = _sources([_bind(1001, hwnd=200)], [_state(1001, "running")])
    snap = _view(sources, hwnd=100).snapshot()
    assert snap.count == 0
    assert snap.state == "idle"


def test_bind_without_hwnd_is_ignored_by_window_view():
    sources = _sources([_bind(1001, hwnd=0)], [_state(1001, "running")])
    snap = _view(sources, hwnd=100).snapshot()
    assert snap.count == 0


# ============================================================
# 聚合优先级与标签
# ============================================================

def test_aggregate_uses_priority_order():
    sources = _sources(
        [_bind(1, project="a"), _bind(2, project="b"), _bind(3, project="c")],
        [_state(1, "success"), _state(2, "thinking"), _state(3, "running")],
    )
    assert _view(sources).snapshot().state == "thinking"


def test_aggregate_waiting_beats_failure():
    sources = _sources(
        [_bind(1, project="a"), _bind(2, project="b")],
        [_state(1, "failure"), _state(2, "waiting")],
    )
    assert _view(sources).snapshot().state == "waiting"


def test_label_follows_highest_priority_session_across_projects():
    sources = _sources(
        [_bind(1, project="alpha"), _bind(2, project="beta")],
        [_state(1, "running"), _state(2, "waiting")],
    )
    snap = _view(sources).snapshot()
    assert snap.state == "waiting"
    assert snap.label == "beta"


def test_badge_counts_distinct_pids_not_bind_rows():
    sources = _sources(
        [_bind(1, session_id="a", updated=NOW - 5),
         _bind(1, session_id="b", updated=NOW),
         _bind(2, session_id="c")],
        [_state(1, "running"), _state(2, "idle")],
    )
    assert _view(sources).snapshot().count == 2


def test_same_pid_multiple_binds_use_latest_updated():
    sources = _sources(
        [_bind(1, session_id="old", project="old-proj", updated=NOW - 50),
         _bind(1, session_id="new", project="new-proj", updated=NOW)],
        [_state(1, "running")],
    )
    snap = _view(sources).snapshot()
    assert snap.count == 1
    assert snap.label == "new-proj"


# ============================================================
# ended / 死 pid / 缺状态
# ============================================================

def test_ended_with_live_pid_renders_idle():
    sources = _sources([_bind(1)], [_state(1, "ended")])
    snap = _view(sources, alive=lambda pid, ft: True).snapshot()
    assert snap.state == "idle"
    assert snap.count == 1


def test_dead_pid_is_excluded():
    sources = _sources(
        [_bind(1, project="gone"), _bind(2, project="alive")],
        [_state(1, "failure"), _state(2, "running")],
    )
    snap = _view(sources, alive=lambda pid, ft: pid == 2).snapshot()
    assert snap.count == 1
    assert snap.label == "alive"
    assert snap.state == "running"


def test_pid_reuse_is_rejected_by_identity_check():
    sources = _sources([_bind(1, creation_ft="111")], [_state(1, "running")])
    snap = _view(sources,
                 alive=lambda pid, ft: str(ft) == "111").snapshot()
    assert snap.count == 1

    sources2 = _sources([_bind(1, creation_ft="111")], [_state(1, "running")])
    snap2 = _view(sources2,
                  alive=lambda pid, ft: str(ft) == "999").snapshot()
    assert snap2.count == 0


def test_missing_state_file_renders_idle():
    snap = _view(_sources([_bind(1)])).snapshot()
    assert snap.state == "idle"
    assert snap.count == 1


def test_expired_state_ttl_falls_back_to_idle():
    old = NOW - 10000
    sources = _sources([_bind(1)], [_state(1, "running", mtime=old)])
    snap = _view(sources).snapshot()
    assert snap.count == 1
    assert snap.state == "idle"


# ============================================================
# 降级视图
# ============================================================

def test_degraded_view_contains_only_degraded_binds():
    sources = _sources(
        [_bind(1, hwnd=100, project="win"),
         _bind(2, hwnd=0, project="lost", degraded=True)],
        [_state(1, "running"), _state(2, "failure")],
    )
    degraded = _view(sources, hwnd=None, degraded=True).snapshot()
    window = _view(sources, hwnd=100).snapshot()

    assert degraded.degraded is True
    assert degraded.count == 1
    assert degraded.label == "lost"
    assert degraded.state == "failure"

    assert window.degraded is False
    assert window.count == 1
    assert window.label == "win"


def test_degraded_view_ignores_hwnd():
    sources = _sources([_bind(1, hwnd=555, degraded=True)],
                       [_state(1, "thinking")])
    snap = _view(sources, hwnd=None, degraded=True).snapshot()
    assert snap.count == 1
    assert snap.state == "thinking"


def test_empty_degraded_view_is_idle_and_flagged():
    snap = _view(_sources(), hwnd=None, degraded=True).snapshot()
    assert snap.degraded is True
    assert snap.state == "idle"
    assert snap.count == 0


# ============================================================
# FileSystemSources：读真实目录
# ============================================================

def test_filesystem_sources_read_state_and_bind(tmp_path):
    (tmp_path / "4242.state").write_text(
        "running\nC:/work/alpha\n131000000000000000\n", encoding="utf-8")
    (tmp_path / "sess-1.bind").write_text(
        "\n".join([
            "session_id=sess-1",
            "pid=4242",
            "creation_ft=131000000000000000",
            "hwnd=777",
            "hwnd_owner_pid=9",
            "hwnd_owner_ft=131000000000000001",
            "project=alpha",
            "cwd=C:/work/alpha",
            f"updated={int(NOW)}",
            "degraded=0",
        ]) + "\n",
        encoding="utf-8",
    )

    view = SessionView(
        FileSystemSources(str(tmp_path)),
        hwnd=777,
        process_checker=lambda pid, ft: True,
        now=NOW,
    )
    snap = view.snapshot()
    assert snap.state == "running"
    assert snap.label == "alpha"
    assert snap.count == 1
    assert snap.sessions[0].pid == 4242


def test_filesystem_sources_skip_malformed_and_old_format(tmp_path):
    (tmp_path / "not-a-pid.state").write_text("running\n", encoding="utf-8")
    (tmp_path / "5.state").write_text("bogus\n", encoding="utf-8")
    (tmp_path / "x.bind").write_text("garbage without equals\n",
                                     encoding="utf-8")
    (tmp_path / "5.bind").write_text(
        "session_id=s5\npid=not-an-int\nhwnd=100\nupdated=1000\n",
        encoding="utf-8")

    view = SessionView(
        FileSystemSources(str(tmp_path)),
        hwnd=100,
        process_checker=lambda pid, ft: True,
        now=NOW,
    )
    assert view.snapshot().count == 0


def test_filesystem_sources_missing_dir_is_empty(tmp_path):
    view = SessionView(
        FileSystemSources(str(tmp_path / "missing")),
        hwnd=100,
        process_checker=lambda pid, ft: True,
        now=NOW,
    )
    assert view.snapshot().count == 0
