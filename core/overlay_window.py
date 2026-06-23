"""
透明置顶窗口 — Glassmorphism + Neon 风格

参考: github.com/ChiFrontEnd/Chi-Frontend-Lab 的 Glassmorphism Traffic Light
"""
import ctypes
import sys
from PyQt5.QtCore import Qt, QTimer, QPoint, QPropertyAnimation, QEasingCurve, pyqtProperty
from PyQt5.QtGui import QPainter, QBrush, QColor, QPainterPath, QPen, QLinearGradient, QRadialGradient
from PyQt5.QtWidgets import QWidget, QApplication


class TrafficLightWindow(QWidget):
    """红绿灯主窗口：玻璃拟态背景、圆角、置顶、霓虹状态边框"""

    WIDTH = 200
    HEIGHT = 148
    RADIUS = 18  # 圆角半径

    # 状态霓虹色（alpha 用于辉光强度）
    GLOW_COLORS = {
        "thinking": QColor(0xFF, 0xD1, 0x66, 100),   # 跑马灯 — 暖金
        "running":  QColor(0xFF, 0xD1, 0x66, 85),    # 黄灯呼吸 — 琥珀
        "waiting":  QColor(0xFF, 0x3B, 0x3B, 110),   # 红黄警灯 — 霓虹红
        "success":  QColor(0x2E, 0xE5, 0x9D, 85),    # 绿灯脉冲 — 薄荷绿
        "failure":  QColor(0xFF, 0x3B, 0x3B, 85),    # 红灯双闪 — 霓虹红
        "idle":     QColor(140, 150, 180, 45),        # 空闲 — 冷灰微光
    }

    def __init__(self, name="agent"):
        super().__init__()
        self._name = name
        self._drag_pos = None
        self._glow_color = QColor(140, 150, 180, 45)

        self._init_ui()
        self._start_keep_on_top()

        # 边框颜色过渡动画
        self._glow_anim = QPropertyAnimation(self, b"glow_color")
        self._glow_anim.setDuration(400)
        self._glow_anim.setEasingCurve(QEasingCurve.OutCubic)

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

        # 定位到屏幕右下角
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

    # ---- 属性 ----
    def _get_glow_color(self):
        return self._glow_color

    def _set_glow_color(self, color):
        self._glow_color = color
        self.update()

    glow_color = pyqtProperty(QColor, _get_glow_color, _set_glow_color)

    def set_glow_color(self, state):
        """根据状态设置霓虹边框颜色"""
        target = self.GLOW_COLORS.get(state, self.GLOW_COLORS["idle"])
        self._glow_anim.stop()
        self._glow_anim.setStartValue(self._glow_color)
        self._glow_anim.setEndValue(target)
        self._glow_anim.start()

    # ---- 拖拽移动 ----
    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self._drag_pos = event.globalPos() - self.frameGeometry().topLeft()

    def mouseMoveEvent(self, event):
        if self._drag_pos is not None and event.buttons() == Qt.LeftButton:
            self.move(event.globalPos() - self._drag_pos)

    def mouseReleaseEvent(self, event):
        self._drag_pos = None

    # ---- 绘制 ----
    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

        # 外层霓虹辉光（多层）
        self._draw_outer_glow(painter)

        # 主体玻璃面板
        self._draw_glass_panel(painter)

    def _draw_outer_glow(self, painter):
        """多层霓虹外发光"""
        base = self._glow_color
        r = self.RADIUS

        for offset, alpha_scale in [(14, 0.15), (10, 0.28), (6, 0.5)]:
            glow = QColor(
                base.red(),
                base.green(),
                base.blue(),
                int(base.alpha() * alpha_scale),
            )
            path = QPainterPath()
            path.addRoundedRect(
                -offset, -offset,
                self.width() + 2 * offset, self.height() + 2 * offset,
                r + offset, r + offset
            )
            painter.fillPath(path, QBrush(glow))

    def _draw_glass_panel(self, painter):
        """绘制玻璃拟态面板"""
        r = self.RADIUS
        path = QPainterPath()
        path.addRoundedRect(0, 0, self.width(), self.height(), r, r)

        # 背景渐变：深蓝黑到微亮，模拟玻璃厚度
        gradient = QLinearGradient(0, 0, 0, self.height())
        gradient.setColorAt(0.0, QColor(18, 22, 38, 230))
        gradient.setColorAt(0.5, QColor(12, 15, 28, 235))
        gradient.setColorAt(1.0, QColor(8, 10, 20, 240))
        painter.fillPath(path, QBrush(gradient))

        # 顶部高光边框
        highlight_pen = QPen(QColor(255, 255, 255, 55), 1.0)
        painter.setPen(highlight_pen)
        painter.drawPath(path)

        # 内部上边缘高光（inset 效果）
        inner_path = QPainterPath()
        inner_path.addRoundedRect(1, 1, self.width() - 2, self.height() - 2, r - 1, r - 1)
        painter.setPen(QPen(QColor(255, 255, 255, 25), 1.0))
        painter.drawPath(inner_path)

        # 底部阴影
        bottom_glow = QLinearGradient(0, self.height() - 20, 0, self.height() + 8)
        bottom_glow.setColorAt(0.0, QColor(0, 0, 0, 0))
        bottom_glow.setColorAt(1.0, QColor(0, 0, 0, 120))
        painter.setBrush(QBrush(bottom_glow))
        painter.setPen(Qt.NoPen)
        painter.drawRect(0, self.height() - 20, self.width(), 28)

    @property
    def name(self):
        return self._name
