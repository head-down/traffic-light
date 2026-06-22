"""
三色红绿灯绘制面板 — 抗锯齿圆形 + 外发光 + 呼吸动画 + 闪烁动画
"""
from PyQt5.QtCore import Qt, QTimer, QPropertyAnimation, QEasingCurve, pyqtProperty, QPointF
from PyQt5.QtGui import QPainter, QColor, QRadialGradient, QBrush, QPen
from PyQt5.QtWidgets import QWidget


# 颜色定义
COLORS = {
    "red":    QColor(0xFF, 0x44, 0x44),
    "yellow": QColor(0xFF, 0xAA, 0x00),
    "green":  QColor(0x44, 0xFF, 0x44),
}

DIM_ALPHA = 40      # 熄灭灯的透明度
GLOW_ALPHA = 80     # 发光最大透明度
LIGHT_RADIUS = 18   # 灯半径（px）
GLOW_RADIUS = 32    # 发光半径（px）
BREATHE_MIN = 14    # 呼吸最小半径
BREATHE_MAX = 22    # 呼吸最大半径
SPACING = 50        # 灯心距


class LightPanel(QWidget):
    """在父窗口内绘制三盏红绿灯"""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._state = "idle"
        self._active_radius = LIGHT_RADIUS  # 当前亮灯实际半径（动画驱动）

        # 闪烁定时器（红灯用）
        self._blink_timer = QTimer(self)
        self._blink_timer.timeout.connect(self._toggle_blink)
        self._blink_on = True

        self._current_color = QColor(0, 0, 0, 0)

        # 颜色过渡动画
        self._color_anim = QPropertyAnimation(self, b"active_color")
        self._color_anim.setDuration(300)
        self._color_anim.setEasingCurve(QEasingCurve.OutCubic)

        # 呼吸动画（黄灯用）
        self._breathe_anim = QPropertyAnimation(self, b"active_radius")
        self._breathe_anim.setDuration(1200)
        self._breathe_anim.setLoopCount(-1)  # 无限循环
        self._breathe_anim.setEasingCurve(QEasingCurve.InOutSine)

        self.setMinimumSize(200, 100)

    # ---- 属性：颜色动画 ----
    def _get_active_color(self):
        return self._current_color

    def _set_active_color(self, color):
        self._current_color = color
        self.update()

    active_color = pyqtProperty(QColor, _get_active_color, _set_active_color)

    # ---- 属性：呼吸动画 ----
    def _get_active_radius(self):
        return self._active_radius

    def _set_active_radius(self, r):
        self._active_radius = r
        self.update()

    active_radius = pyqtProperty(float, _get_active_radius, _set_active_radius)

    # ---- 状态切换 ----
    def set_state(self, state):
        """更新显示状态"""
        old_state = self._state
        self._state = state

        # 停止旧动画
        self._breathe_anim.stop()
        self._blink_timer.stop()

        if state == "running":
            # 黄灯：亮起 + 呼吸动画
            self._animate_color(COLORS["yellow"])
            self._start_breathe()
        elif state == "success":
            # 绿灯：亮起
            self._animate_color(COLORS["green"])
            self._active_radius = LIGHT_RADIUS
        elif state == "failure":
            # 红灯：亮起 + 闪烁
            self._animate_color(COLORS["red"])
            self._active_radius = LIGHT_RADIUS
            self._blink_on = True
            self._blink_timer.start(500)
        else:  # idle
            self._animate_color(QColor(0, 0, 0, 0))
            self._active_radius = LIGHT_RADIUS

        self.update()

    def _animate_color(self, target):
        self._color_anim.stop()
        self._color_anim.setStartValue(self._current_color)
        self._color_anim.setEndValue(target)
        self._color_anim.start()

    def _start_breathe(self):
        self._breathe_anim.stop()
        self._breathe_anim.setStartValue(BREATHE_MIN)
        self._breathe_anim.setEndValue(BREATHE_MAX)
        self._active_radius = BREATHE_MIN
        self._breathe_anim.start()

    def _toggle_blink(self):
        self._blink_on = not self._blink_on
        self.update()

    # ---- 绘制 ----
    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

        w = self.width()
        h = self.height()

        # 三盏灯的水平中心 X
        centers = [
            w // 2 - SPACING,   # 红灯
            w // 2,              # 黄灯
            w // 2 + SPACING,   # 绿灯
        ]
        light_types = ["red", "yellow", "green"]
        y_center = h // 2 - 5   # 微上调给标签留空间

        for i, (cx, lt) in enumerate(zip(centers, light_types)):
            is_active = (
                self._state != "idle"
                and self._state == {0: "failure", 1: "running", 2: "success"}[i]
            )

            # 红灯闪烁：灭的帧不画
            if is_active and self._state == "failure" and not self._blink_on:
                is_active = False

            color = COLORS[lt]
            radius = self._active_radius if is_active else LIGHT_RADIUS

            if is_active:
                # 外发光
                self._draw_glow(painter, cx, y_center, color)
                # 灯本体
                self._draw_light(painter, cx, y_center, color, radius)
            else:
                # 暗色轮廓
                dim = QColor(color.red(), color.green(), color.blue(), DIM_ALPHA)
                self._draw_light(painter, cx, y_center, dim, LIGHT_RADIUS)

        # 状态标签
        painter.setPen(QColor(255, 255, 255, 180))
        painter.setFont(self.parent().font())
        label = self.parent().name if self.parent() else ""
        painter.drawText(0, h - 8, w, 16, Qt.AlignHCenter, label)

    def _draw_glow(self, painter, cx, cy, color):
        """径向渐变模拟外发光"""
        for r in range(GLOW_RADIUS, 0, -4):
            alpha = int(GLOW_ALPHA * (r / GLOW_RADIUS) ** 2)
            c = QColor(color.red(), color.green(), color.blue(), alpha)
            gradient = QRadialGradient(QPointF(cx, cy), r)
            gradient.setColorAt(1, c)
            gradient.setColorAt(0, QColor(0, 0, 0, 0))
            painter.setBrush(QBrush(gradient))
            painter.setPen(Qt.NoPen)
            painter.drawEllipse(QPointF(cx, cy), r, r)

    def _draw_light(self, painter, cx, cy, color, radius):
        """画一个带渐变立体感的圆灯"""
        # 径向渐变 — 中心亮边缘暗
        gradient = QRadialGradient(QPointF(cx - radius * 0.3, cy - radius * 0.3), radius * 1.2)
        highlight = QColor(
            min(color.red() + 80, 255),
            min(color.green() + 80, 255),
            min(color.blue() + 80, 255),
            color.alpha(),
        )
        gradient.setColorAt(0, highlight)
        gradient.setColorAt(0.5, color)
        dark = QColor(
            max(color.red() - 60, 0),
            max(color.green() - 60, 0),
            max(color.blue() - 60, 0),
            color.alpha(),
        )
        gradient.setColorAt(1, dark)

        painter.setBrush(QBrush(gradient))
        painter.setPen(Qt.NoPen)
        painter.drawEllipse(QPointF(cx, cy), radius, radius)
