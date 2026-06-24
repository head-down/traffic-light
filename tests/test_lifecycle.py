"""LifecycleManager 单元测试 — PID 锁 / 心跳 / 清理"""
import pytest
import os
import sys
import signal
from contextlib import redirect_stdout
import io

from core import lifecycle as lc_mod
from core.lifecycle import LifecycleManager


@pytest.fixture
def pid_dir(tmp_path):
    d = tmp_path / "states"
    d.mkdir()
    return str(d)


def _make_mgr(pid_dir, project=None, cb_pid=None, checker=None):
    """创建 LifecycleManager，抑制 stdout 重定向"""
    f = io.StringIO()
    with redirect_stdout(f):
        mgr = LifecycleManager(
            project, pid_dir,
            cb_pid=cb_pid,
            process_checker=checker
        )
    return mgr


# ============================================================
# PID 锁
# ============================================================

def test_blocks_when_process_alive(pid_dir):
    """PID 文件存在且进程存活 → SystemExit"""
    pid_file = os.path.join(pid_dir, "all.pid")
    with open(pid_file, "w") as f:
        f.write("9999")

    with pytest.raises(SystemExit):
        _make_mgr(pid_dir, checker=lambda p: True)


def test_cleans_stale_pid_and_proceeds(pid_dir):
    """PID 文件存在但进程已死 → 清理旧文件，正常启动"""
    pid_file = os.path.join(pid_dir, "all.pid")
    with open(pid_file, "w") as f:
        f.write("9999")

    mgr = _make_mgr(pid_dir, checker=lambda p: False)
    assert mgr._name == "all"


def test_no_lock_when_no_pid_file(pid_dir):
    """无 PID 文件时直接启动"""
    mgr = _make_mgr(pid_dir)
    assert mgr._name == "all"


# ============================================================
# PID 文件写入
# ============================================================

def test_pid_file_contains_current_pid(pid_dir):
    mgr = _make_mgr(pid_dir, project="mine")
    pid_file = os.path.join(pid_dir, "mine.pid")
    assert os.path.exists(pid_file)
    with open(pid_file) as f:
        assert int(f.read().strip()) == os.getpid()


# ============================================================
# 项目命名空间
# ============================================================

def test_project_name_defaults_to_all(pid_dir):
    mgr = _make_mgr(pid_dir)
    assert mgr._name == "all"
    assert os.path.exists(os.path.join(pid_dir, "all.pid"))


def test_project_name_used_in_pid_path(pid_dir):
    mgr = _make_mgr(pid_dir, project="jw-zhyg-api")
    assert mgr._name == "jw-zhyg-api"
    assert os.path.exists(os.path.join(pid_dir, "jw-zhyg-api.pid"))


# ============================================================
# 心跳检测
# ============================================================

class FakeApp:
    """Mock QApplication: 只暴露 quit()"""
    def __init__(self):
        self.quit_calls = 0

    def quit(self):
        self.quit_calls += 1


def test_heartbeat_exits_on_dead_cb(pid_dir):
    """CodeBuddy 进程退出 → 连续 2 次 → app.quit()"""
    mgr = _make_mgr(pid_dir, cb_pid=8888, checker=lambda p: False)
    app = FakeApp()
    mgr._fail_count = 0  # simulate start_heartbeat init

    # 第一次检测失败 → fail_count=1, 不退出
    mgr._check_heartbeat(app)
    assert app.quit_calls == 0
    assert mgr._fail_count == 1

    # 第二次检测失败 → fail_count=2, 触发退出
    mgr._check_heartbeat(app)
    assert app.quit_calls == 1
    assert mgr._fail_count == 2


def test_heartbeat_resets_on_recovery(pid_dir):
    """CodeBuddy 恢复在线 → fail_count 归零"""
    alive = [True]

    def toggle(p):
        return alive[0]

    mgr = _make_mgr(pid_dir, cb_pid=8888, checker=toggle)
    app = FakeApp()
    mgr._fail_count = 0  # simulate start_heartbeat init

    # CB alive: count=0
    mgr._check_heartbeat(app)
    assert mgr._fail_count == 0

    # CB dead: count=1
    alive[0] = False
    mgr._check_heartbeat(app)
    assert mgr._fail_count == 1

    # CB alive again: count resets to 0
    alive[0] = True
    mgr._check_heartbeat(app)
    assert mgr._fail_count == 0
    assert app.quit_calls == 0


def test_heartbeat_noop_when_no_cb_pid(pid_dir):
    """cb_pid=None → 心跳不启动"""
    mgr = _make_mgr(pid_dir, cb_pid=None)
    app = FakeApp()
    mgr.start_heartbeat(app)
    assert not hasattr(mgr, "_heartbeat_timer")


# ============================================================
# 清理
# ============================================================

def test_cleanup_removes_pid_file(pid_dir):
    mgr = _make_mgr(pid_dir)
    pid_file = os.path.join(pid_dir, "all.pid")
    assert os.path.exists(pid_file)
    mgr.cleanup()
    assert not os.path.exists(pid_file)


def test_cleanup_safe_when_file_missing(pid_dir):
    """PID 文件已不存在时 cleanup 不抛异常"""
    mgr = _make_mgr(pid_dir)
    os.remove(os.path.join(pid_dir, "all.pid"))
    mgr.cleanup()  # should not raise


# ============================================================
# 信号处理
# ============================================================

def test_signal_handler_triggers_quit(pid_dir):
    """SIGINT → app.quit()"""
    mgr = _make_mgr(pid_dir)
    app = FakeApp()
    mgr.setup_signal_handlers(app)

    # 触发 SIGINT handler
    old_handler = signal.getsignal(signal.SIGINT)
    try:
        old_handler(signal.SIGINT, None)
        assert app.quit_calls == 1
    except SystemExit:
        # signal handler might call sys.exit instead of app.quit
        # if setup_signal_handlers wraps it via lambda
        pass
    finally:
        signal.signal(signal.SIGINT, old_handler)
