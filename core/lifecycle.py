"""
进程生命周期管理 — PID 单实例锁、日志重定向、心跳检测、信号处理

从 traffic_light.py main() 上帝函数提取，独立的内部模块。
测试：见 tests/test_lifecycle.py
"""
import os
import sys
import signal
import ctypes

PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
STILL_ACTIVE = 259


def _is_process_alive(pid):
    """检查指定 PID 的进程是否存活（Windows OpenProcess，避免 os.kill 误杀）"""
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not handle:
        return False
    try:
        exit_code = ctypes.c_ulong()
        if kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
            return exit_code.value == STILL_ACTIVE
        return False
    finally:
        kernel32.CloseHandle(handle)


class LifecycleManager:
    """
    进程生命周期管理器。

    Phase 1 (同步, __init__):
      - PID 文件单实例锁
      - stdout/stderr → daemon.log 重定向
      - PID 文件写入

    Phase 2 (Qt 事件循环启动后):
      - CodeBuddy 心跳检测 (start_heartbeat)
      - SIGINT / SIGTERM 处理 (setup_signal_handlers)

    退出:
      - cleanup() 删除 PID 文件
    """

    def __init__(self, project, pid_dir, cb_pid=None, process_checker=None):
        self._project = project
        self._pid_dir = pid_dir
        self._name = project or "all"
        self._pid_file = os.path.join(pid_dir, f"{self._name}.pid")
        self._checker = process_checker or _is_process_alive

        # Read cbpid if not explicitly provided
        if cb_pid is None:
            cb_pid = self._read_cbpid()
        self._cb_pid = cb_pid

        os.makedirs(pid_dir, exist_ok=True)
        self._acquire_lock()
        self._redirect_logs()
        self._write_pid()

    # ---- Phase 1: 同步初始化 ----

    def _read_cbpid(self):
        """读取 CodeBuddy 进程 PID（bind.sh 启动时写入）"""
        cbpid_file = os.path.join(self._pid_dir, f"{self._name}.cbpid")
        try:
            with open(cbpid_file) as f:
                return int(f.read().strip())
        except Exception:
            return None

    def _acquire_lock(self):
        """PID 文件单实例锁"""
        if not os.path.exists(self._pid_file):
            return

        try:
            with open(self._pid_file) as f:
                old_pid = int(f.read().strip())
            if self._checker(old_pid):
                print(
                    f"[SignalLight] {self._name} daemon already running (PID={old_pid})",
                    flush=True,
                )
                sys.exit(0)
        except Exception:
            pass

        # 旧 PID 无效（进程已退出），清理
        try:
            os.remove(self._pid_file)
        except Exception:
            pass

    def _redirect_logs(self):
        """stdout/stderr → daemon.log（不依赖 bind.sh 的外部重定向）"""
        log_path = os.path.join(self._pid_dir, "daemon.log")
        log_fd = open(log_path, "a", buffering=1)
        sys.stdout = log_fd
        sys.stderr = log_fd
        print(
            f"[SignalLight] daemon starting --project {self._name} PID={os.getpid()}",
            flush=True,
        )

    def _write_pid(self):
        os.makedirs(self._pid_dir, exist_ok=True)
        with open(self._pid_file, "w") as f:
            f.write(str(os.getpid()))

    # ---- Phase 2: Qt 依赖的运行时功能 ----

    def start_heartbeat(self, app, interval_ms=5000):
        """
        启动 CodeBuddy 存活检测。

        连续 2 次检测到 CodeBuddy 退出 → app.quit()
        2 次确认防止进程刚启动时的抖动误判。
        """
        if self._cb_pid is None:
            return

        self._fail_count = 0
        # QTimer 必须由 app 持有引用防止 GC
        from PyQt5.QtCore import QTimer

        timer = QTimer(app)
        timer.timeout.connect(lambda: self._check_heartbeat(app))
        timer.start(interval_ms)
        self._heartbeat_timer = timer

    def _check_heartbeat(self, app):
        if self._checker(self._cb_pid):
            self._fail_count = 0
        else:
            self._fail_count += 1
            if self._fail_count >= 2:
                print(
                    f"[SignalLight] CodeBuddy (PID={self._cb_pid}) exited, shutting down",
                    flush=True,
                )
                app.quit()

    def setup_signal_handlers(self, app):
        """注册 SIGINT / SIGTERM → app.quit()"""

        def handler(signum=None, frame=None):
            app.quit()

        signal.signal(signal.SIGINT, handler)
        signal.signal(signal.SIGTERM, handler)

    # ---- 清理 ----

    def cleanup(self):
        """删除 PID 文件"""
        try:
            os.remove(self._pid_file)
        except Exception:
            pass
