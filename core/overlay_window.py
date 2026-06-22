"""
透明置顶窗口 — 无边框、圆角、毛玻璃半透明背景、始终置顶
"""
import ctypes
import sys
from PyQt5.QtCore import Qt, QTimer, QPoint
from PyQt5.QtGui import QPainter, QBrush, QColor, QPainterPath
from PyQt5.QtWidgets import QWidget, QApplication


class TrafficLightWindow(QWidget):
    """红绿灯主窗口：透明无边框、圆角、置顶"""

    WIDTH = 200
    HEIGHT = 120
    RADIUS = 12  # 圆角半径

    def __init__(self, name="agent"):
        super().__init__()
        self._name = name
        self._drag_pos = None

        self._init_ui()
        self._start_keep_on_top()

    def _init_ui(self):
        self.setWindowTitle(f"Traffic Light - {self._name}")
        self.setFixedSize(self.WIDTH, self.HEIGHT)

        # 无边框 + 透明背景
        self.setWindowFlags(
            Qt.FramelessWindowHint
            | Qt.WindowStaysOnTopHint
            | Qt.Tool
        )
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAttribute(Qt.WA_ShowWithoutActivating)

        # 定位到屏幕右下角（自动检测显示这个窗口的屏幕）
        screen = QApplication.primaryScreen()
        if screen:
            geom = screen.availableGeometry()
            x = geom.right() - self.WIDTH - 20
            y = geom.bottom() - self.HEIGHT - 20
            self.move(x, y)

    def _start_keep_on_top(self):
        """每 2 秒抬升一次，防止全屏窗口抢占"""
        def keep():
            if not self.isVisible():
                return
            try:
                self.raise_()
                self.setWindowFlag(Qt.WindowStaysOnTopHint, True)
                if sys.platform == "win32":
                    hwnd = int(self.winId())
                    ctypes.windll.user32.SetWindowPos(
                        hwnd, -1, 0, 0, 0, 0, 0x0002 | 0x0001 | 0x0040
                    )
            except Exception:
                pass

        self._topmost_timer = QTimer(self)
        self._topmost_timer.timeout.connect(keep)
        self._topmost_timer.start(2000)
        keep()

    # ---- 拖拽移动 ----
    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self._drag_pos = event.globalPos() - self.frameGeometry().topLeft()

    def mouseMoveEvent(self, event):
        if self._drag_pos is not None and event.buttons() == Qt.LeftButton:
            self.move(event.globalPos() - self._drag_pos)

    def mouseReleaseEvent(self, event):
        self._drag_pos = None

    # ---- 圆角 + 毛玻璃背景绘制 ----
    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

        # 圆角矩形路径
        path = QPainterPath()
        path.addRoundedRect(0, 0, self.width(), self.height(), self.RADIUS, self.RADIUS)

        # 半透明暗色背景
        bg_color = QColor(26, 26, 46, 220)
        painter.fillPath(path, QBrush(bg_color))

        # 边框（微弱亮线增强立体感）
        painter.setPen(QColor(255, 255, 255, 30))
        painter.drawPath(path)

    @property
    def name(self):
        return self._name
