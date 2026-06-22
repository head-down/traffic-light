"""
状态管理 — 四态状态机 (idle / running / success / failure)，带 Qt signal 通知
"""
from PyQt5.QtCore import QObject, pyqtSignal, QTimer

VALID_STATES = {"idle", "running", "success", "failure"}
AUTO_RESET_SECONDS = 5  # success/failure 自动回 idle 时间


class StateManager(QObject):
    """管理红绿灯状态，发射信号通知 UI"""

    state_changed = pyqtSignal(str)  # new_state

    def __init__(self):
        super().__init__()
        self._state = "idle"
        self._auto_reset_timer = QTimer(self)
        self._auto_reset_timer.setSingleShot(True)
        self._auto_reset_timer.timeout.connect(self._auto_reset)

        # 将 timer 控制逻辑挂在 state_changed 信号上，
        # 确保 timer.start()/stop() 始终在主线程执行（跨线程信号自动排队）
        self.state_changed.connect(self._handle_state_changed)

    @property
    def state(self):
        return self._state

    def update_state(self, new_state):
        """更新状态，无效状态返回 False（可被任意线程调用）"""
        if new_state not in VALID_STATES:
            return False

        if new_state == self._state:
            return True

        self._state = new_state
        self.state_changed.emit(new_state)
        return True

    def _handle_state_changed(self, new_state):
        """主线程槽：控制 auto-reset 定时器"""
        if new_state in ("success", "failure"):
            self._auto_reset_timer.start(AUTO_RESET_SECONDS * 1000)
        else:
            self._auto_reset_timer.stop()

    def _auto_reset(self):
        """成功/失败状态超时后自动回 idle"""
        if self._state in ("success", "failure"):
            self._state = "idle"
            self.state_changed.emit("idle")
