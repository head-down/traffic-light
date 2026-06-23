"""
三色红绿灯绘制面板 — Glassmorphism + Neon 风格

参考: github.com/ChiFrontEnd/Chi-Frontend-Lab 的 Glassmorphism Traffic Light

状态视觉语义：
    idle      — 三灯暗色缓慢呼吸（空闲）
    thinking  — 三灯霓虹跑马灯红→黄→绿循环（模型思考中）
    running   — 黄灯呼吸（工具执行中）
    waiting   — 红黄交替霓虹警灯（等待用户确认）
    success   — 绿灯脉冲（完成）
    failure   — 红灯双闪（失败）
"""
from PyQt5.QtCore import (
    Qt, QTimer, QPropertyAnimation, QEasingCurve, pyqtProperty, QPointF,
    QSequentialAnimationGroup
)
from PyQt5.QtGui import QPainter, QColor, QRadialGradient, QLinearGradient, QBrush, QPen, QFont
from PyQt5.QtWidgets import QWidget


# 灯体颜色定义（参考 Glassmorphism Traffic Light）
LIGHT_COLORS = {
    "red": {
        "core": QColor(0xFF, 0x3B, 0x3B),
        "mid":  QColor(0xB1, 0x00, 0x00),
        "edge": QColor(0x57, 0x00, 0x00),
        "glow": QColor(0xFF, 0x3B, 0x3B, 220),
    },
    "yellow": {
        "core": QColor(0xFF, 0xD1, 0x66),
        "mid":  QColor(0xC8, 0xA0, 0x32),
        "edge": QColor(0x5A, 0x4A, 0x18),
        "glow": QColor(0xFF, 0xD1, 0x66, 220),
    },
    "green": {
        "core": QColor(0x2E, 0xE5, 0x9D),
        "mid":  QColor(0x1A, 0xA8, 0x70),
        "edge": QColor(0x0B, 0x3F, 0x2B),
        "glow": QColor(0x2E, 0xE5, 0x9D, 220),
    },
}

DIM_ALPHA = 30            # 熄灭灯透明度（参考 --off-opacity 0.12，但提高可见度）
GLOW_ALPHA_INNER = 130    # 内层发光 alpha
GLOW_ALPHA_MID = 70       # 中层发光 alpha
GLOW_ALPHA_OUTER = 30     # 外层发光 alpha
LIGHT_RADIUS = 20         # 灯半径
SPACING = 65              # 灯心距

# 黄灯呼吸
BREATHE_MIN = 14
BREATHE_MAX = 22
BREATHE_DURATION = 1200

# 空闲呼吸
IDLE_BREATHE_MIN = 15
IDLE_BREATHE_MAX = 18
IDLE_BREATHE_DURATION = 3000

# 切换弹跳
POP_EXPAND = 24
POP_DURATION_UP = 150
POP_DURATION_DOWN = 250

# 成功脉冲
SUCCESS_PULSE_MAX = 22
SUCCESS_PULSE_DURATION = 500
SUCCESS_SETTLE_DURATION = 300

# 红灯双闪阶段 (ms): 长亮 -> 短灭 -> 短亮 -> 长灭
BLINK_PHASES = [500, 200, 200, 500]

# 跑马灯（thinking）：每灯停留时间
CHASE_INTERVAL = 250

# 红黄交替警灯（waiting）：每灯停留时间
ALARM_INTERVAL = 300


class LightPanel(QWidget):
    """在父窗口内绘制三盏红绿灯"""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._state = "idle"
        self._project_name = ""
        self._active_radius = LIGHT_RADIUS
        self._idle_radius = LIGHT_RADIUS
        self._current_color = QColor(0, 0, 0, 0)
        self._blink_on = True
        self._blink_phase = 0
        self._pop_callback = None
        self._pulse_settle = None

        # 跑马灯状态（thinking）
        self._chase_index = 0  # 0=红, 1=黄, 2=绿

        # 红黄交替警灯状态（waiting）
        self._alarm_index = 0  # 0=红, 1=黄

        # 红灯双闪定时器
        self._blink_timer = QTimer(self)
        self._blink_timer.timeout.connect(self._blink_step)

        # 跑马灯定时器
        self._chase_timer = QTimer(self)
        self._chase_timer.timeout.connect(self._chase_step)

        # 红黄交替警灯定时器
        self._alarm_timer = QTimer(self)
        self._alarm_timer.timeout.connect(self._alarm_step)

        # 颜色过渡动画
        self._color_anim = QPropertyAnimation(self, b"active_color")
        self._color_anim.setDuration(300)
        self._color_anim.setEasingCurve(QEasingCurve.OutCubic)

        # 黄灯呼吸动画
        self._breathe_anim = QPropertyAnimation(self, b"active_radius")
        self._breathe_anim.setDuration(BREATHE_DURATION)
        self._breathe_anim.setLoopCount(-1)
        self._breathe_anim.setEasingCurve(QEasingCurve.InOutSine)

        # 空闲呼吸动画
        self._idle_breathe = QPropertyAnimation(self, b"idle_radius")
        self._idle_breathe.setDuration(IDLE_BREATHE_DURATION)
        self._idle_breathe.setLoopCount(-1)
        self._idle_breathe.setEasingCurve(QEasingCurve.InOutSine)

        # 切换弹跳动画组
        self._pop_group = QSequentialAnimationGroup()
        self._pop_group.finished.connect(self._on_pop_finished)

        # 成功脉冲动画组
        self._pulse_group = QSequentialAnimationGroup()

        self.setMinimumSize(200, 100)

    # ---- 属性 ----
    def _get_active_color(self):
        return self._current_color

    def _set_active_color(self, color):
        self._current_color = color
        self.update()

    active_color = pyqtProperty(QColor, _get_active_color, _set_active_color)

    def _get_active_radius(self):
        return self._active_radius

    def _set_active_radius(self, r):
        self._active_radius = r
        self.update()

    active_radius = pyqtProperty(float, _get_active_radius, _set_active_radius)

    def _get_idle_radius(self):
        return self._idle_radius

    def _set_idle_radius(self, r):
        self._idle_radius = r
        self.update()

    idle_radius = pyqtProperty(float, _get_idle_radius, _set_idle_radius)

    # ---- 状态切换 ----
    def set_state(self, state):
        """更新显示状态"""
        self._state = state

        # 停止旧动画
        self._breathe_anim.stop()
        self._blink_timer.stop()
        self._chase_timer.stop()
        self._alarm_timer.stop()
        self._pop_group.stop()
        self._pulse_group.stop()
        self._idle_breathe.stop()

        # 重置半径
        self._active_radius = LIGHT_RADIUS
        self._idle_radius = LIGHT_RADIUS

        if state == "thinking":
            self._animate_color(QColor(0, 0, 0, 0))
            self._start_chase()
        elif state == "running":
            self._animate_color(LIGHT_COLORS["yellow"]["core"])
            self._play_pop(self._start_breathe)
        elif state == "waiting":
            self._animate_color(QColor(0, 0, 0, 0))
            self._start_alarm()
        elif state == "success":
            self._animate_color(LIGHT_COLORS["green"]["core"])
            self._play_pop(self._play_success_pulse)
        elif state == "failure":
            self._animate_color(LIGHT_COLORS["red"]["core"])
            self._play_pop(self._start_blink)
        else:  # idle
            self._animate_color(QColor(0, 0, 0, 0))
            self._start_idle_breathe()

        self.update()

    def set_project_name(self, name):
        """设置项目路径显示"""
        display_name = name if name else ""
        if display_name != self._project_name:
            self._project_name = display_name
            self.update()

    def _play_pop(self, on_finished=None):
        """18 -> 24(OutQuad) -> 18(OutBack) 切换弹跳"""
        self._pop_group.stop()
        self._pop_callback = on_finished
        self._pop_group.clear()

        pop_up = QPropertyAnimation(self, b"active_radius")
        pop_up.setDuration(POP_DURATION_UP)
        pop_up.setStartValue(LIGHT_RADIUS)
        pop_up.setEndValue(POP_EXPAND)
        pop_up.setEasingCurve(QEasingCurve.OutQuad)

        pop_down = QPropertyAnimation(self, b"active_radius")
        pop_down.setDuration(POP_DURATION_DOWN)
        pop_down.setStartValue(POP_EXPAND)
        pop_down.setEndValue(LIGHT_RADIUS)
        pop_down_curve = QEasingCurve(QEasingCurve.OutBack)
        pop_down_curve.setOvershoot(1.5)
        pop_down.setEasingCurve(pop_down_curve)

        self._pop_group.addAnimation(pop_up)
        self._pop_group.addAnimation(pop_down)
        self._pop_group.start()

    def _on_pop_finished(self):
        if self._pop_callback:
            cb = self._pop_callback
            self._pop_callback = None
            cb()

    def _play_success_pulse(self):
        """绿灯满意脉冲"""
        self._pulse_group.stop()
        self._pulse_group.clear()

        pulse = QPropertyAnimation(self, b"active_radius")
        pulse.setDuration(SUCCESS_PULSE_DURATION)
        pulse.setStartValue(LIGHT_RADIUS)
        pulse.setEndValue(SUCCESS_PULSE_MAX)
        pulse_curve = QEasingCurve(QEasingCurve.OutBack)
        pulse_curve.setOvershoot(1.6)
        pulse.setEasingCurve(pulse_curve)

        settle = QPropertyAnimation(self, b"active_radius")
        settle.setDuration(SUCCESS_SETTLE_DURATION)
        settle.setStartValue(SUCCESS_PULSE_MAX)
        settle.setEndValue(LIGHT_RADIUS)
        settle.setEasingCurve(QEasingCurve.OutCubic)

        self._pulse_group.addAnimation(pulse)
        self._pulse_group.addAnimation(settle)
        self._pulse_group.start()

    def _start_breathe(self):
        """黄灯呼吸"""
        self._breathe_anim.stop()
        self._breathe_anim.setStartValue(BREATHE_MIN)
        self._breathe_anim.setEndValue(BREATHE_MAX)
        self._active_radius = BREATHE_MIN
        self._breathe_anim.start()

    def _start_blink(self):
        """红灯双闪"""
        self._blink_phase = 0
        self._blink_on = True
        self._blink_timer.setInterval(BLINK_PHASES[0])
        self._blink_timer.start()

    def _blink_step(self):
        """红灯双闪状态机"""
        self._blink_phase = (self._blink_phase + 1) % len(BLINK_PHASES)
        self._blink_on = self._blink_phase in (0, 2)
        self._blink_timer.setInterval(BLINK_PHASES[self._blink_phase])
        self.update()

    def _start_chase(self):
        """三灯霓虹跑马灯"""
        self._chase_index = 0
        self._chase_timer.setInterval(CHASE_INTERVAL)
        self._chase_timer.start()
        self.update()

    def _chase_step(self):
        """跑马灯推进"""
        self._chase_index = (self._chase_index + 1) % 3
        self.update()

    def _start_alarm(self):
        """红黄交替霓虹警灯"""
        self._alarm_index = 0
        self._alarm_timer.setInterval(ALARM_INTERVAL)
        self._alarm_timer.start()
        self.update()

    def _alarm_step(self):
        """红黄交替推进"""
        self._alarm_index = (self._alarm_index + 1) % 2
        self.update()

    def _start_idle_breathe(self):
        """空闲时三灯缓慢呼吸"""
        self._idle_breathe.stop()
        self._idle_breathe.setStartValue(IDLE_BREATHE_MIN)
        self._idle_breathe.setEndValue(IDLE_BREATHE_MAX)
        self._idle_radius = IDLE_BREATHE_MIN
        self._idle_breathe.start()

    def _animate_color(self, target):
        self._color_anim.stop()
        self._color_anim.setStartValue(self._current_color)
        self._color_anim.setEndValue(target)
        self._color_anim.start()

    # ---- 绘制 ----
    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

        w = self.width()
        h = self.height()

        # 项目路径（顶部常驻显示）
        if self._project_name:
            display_name = self._shorten_path(self._project_name, w - 24)
            pfont = QFont(self.parent().font()) if self.parent() else QFont()
            pfont.setPointSize(8)
            pfont.setBold(True)
            painter.setFont(pfont)

            fm = painter.fontMetrics()
            text_w = fm.boundingRect(display_name).width()
            pill_x = (w - text_w) // 2 - 8
            pill_y = 5
            pill_w = text_w + 16
            pill_h = 16

            # 深色半透明背景药丸
            painter.setPen(Qt.NoPen)
            painter.setBrush(QColor(0, 0, 0, 120))
            painter.drawRoundedRect(pill_x, pill_y, pill_w, pill_h, 8, 8)

            # 文字阴影 + 主文字
            painter.setPen(QColor(0, 0, 0, 200))
            painter.drawText(4, 6, w - 8, 16, Qt.AlignHCenter, display_name)
            painter.setPen(QColor(255, 255, 255, 230))
            painter.drawText(4, 5, w - 8, 16, Qt.AlignHCenter, display_name)

        centers = [
            w // 2 - SPACING,
            w // 2,
            w // 2 + SPACING,
        ]
        light_types = ["red", "yellow", "green"]
        y_center = 80

        for i, (cx, lt) in enumerate(zip(centers, light_types)):
            self._draw_light_complete(painter, cx, y_center, lt, i)

        # 状态标签（底部）
        label = self._state_label()
        if label:
            painter.setPen(QColor(200, 210, 230, 180))
            font = QFont(self.parent().font()) if self.parent() else QFont()
            font.setPointSize(9)
            font.setLetterSpacing(QFont.PercentageSpacing, 105)
            painter.setFont(font)
            painter.drawText(0, h - 24, w, 20, Qt.AlignHCenter, label)

    def _state_label(self):
        labels = {
            "idle": "IDLE",
            "thinking": "THINKING",
            "running": "RUNNING",
            "waiting": "WAITING",
            "success": "SUCCESS",
            "failure": "FAILURE",
        }
        return labels.get(self._state, "")

    def _shorten_path(self, path, max_width):
        """缩短路径显示：优先只显示项目目录名，必要时再截断"""
        import os
        if not path:
            return ""
        # 8pt 加粗字体约 5px/字符
        max_chars = max_width // 5
        basename = os.path.basename(path).strip()
        if basename and len(basename) <= max_chars:
            return basename
        if len(path) <= max_chars:
            return path
        # 取尾部
        return "..." + path[-(max_chars - 3):]

    def _draw_light_complete(self, painter, cx, cy, lt, index):
        """绘制一盏完整的霓虹灯（含边框、内阴影、发光、灯体、高光）"""
        # 当前状态对应的亮度系数
        intensity = self._light_intensity(index, lt)

        color = LIGHT_COLORS[lt]
        base = color["core"]
        radius = LIGHT_RADIUS

        # 实际发光半径随亮度缩放
        glow_radius = radius * (1.0 + 0.6 * intensity)

        if intensity > 0.05:
            # 外层扩散光晕
            self._draw_glow_layer(painter, cx, cy, base, glow_radius * 2.2,
                                  int(GLOW_ALPHA_OUTER * intensity))
            # 中层光晕
            self._draw_glow_layer(painter, cx, cy, base, glow_radius * 1.5,
                                  int(GLOW_ALPHA_MID * intensity))
            # 内层强光
            self._draw_glow_layer(painter, cx, cy, base, glow_radius * 1.0,
                                  int(GLOW_ALPHA_INNER * intensity))

        # 灯体底座（带边框和内阴影）
        self._draw_light_base(painter, cx, cy, radius, intensity)

        # 发光核心（LED 灯珠）
        if intensity > 0.05:
            self._draw_led_core(painter, cx, cy, color, radius * 0.82, intensity)

        # 同心圆环装饰
        self._draw_rings(painter, cx, cy, radius, intensity)

        # 玻璃高光条（gloss）
        self._draw_gloss(painter, cx, cy, radius, intensity)

    def _light_intensity(self, index, lt):
        """根据当前状态计算第 index 个灯的亮度系数 (0.0 ~ 1.0)"""
        if self._state == "idle":
            # 空闲时三灯缓慢呼吸（用 idle_radius 控制）
            t = (self._idle_radius - IDLE_BREATHE_MIN) / (IDLE_BREATHE_MAX - IDLE_BREATHE_MIN)
            return 0.12 + 0.18 * t
        elif self._state == "thinking":
            # 跑马灯平滑过渡：当前灯 1.0，其他 0.12
            distance = abs(index - self._chase_index)
            if distance == 0:
                return 1.0
            elif distance == 1:
                return 0.12
            else:
                return 0.12
        elif self._state == "waiting":
            # 红黄交替警灯：当前灯 1.0，另一灯 0.12，第三灯 0.05
            if lt == "red":
                return 1.0 if self._alarm_index == 0 else 0.12
            elif lt == "yellow":
                return 1.0 if self._alarm_index == 1 else 0.12
            else:
                return 0.05
        elif self._state == "running":
            return 1.0 if lt == "yellow" else 0.12
        elif self._state == "success":
            return 1.0 if lt == "green" else 0.12
        elif self._state == "failure":
            if lt == "red":
                return 1.0 if self._blink_on else 0.08
            return 0.12
        return 0.12

    def _draw_glow_layer(self, painter, cx, cy, base_color, radius, alpha):
        """绘制一层发光"""
        if alpha <= 0:
            return
        gradient = QRadialGradient(QPointF(cx, cy), radius)
        glow_color = QColor(base_color.red(), base_color.green(), base_color.blue(), alpha)
        gradient.setColorAt(0.0, glow_color)
        gradient.setColorAt(0.6, QColor(glow_color.red(), glow_color.green(), glow_color.blue(), int(alpha * 0.4)))
        gradient.setColorAt(1.0, QColor(0, 0, 0, 0))
        painter.setBrush(QBrush(gradient))
        painter.setPen(Qt.NoPen)
        painter.drawEllipse(QPointF(cx, cy), radius, radius)

    def _draw_light_base(self, painter, cx, cy, radius, intensity):
        """绘制灯体底座（深色凹槽 + 内阴影）"""
        # 外边框
        border_color = QColor(255, 255, 255, 25 + int(20 * intensity))
        painter.setPen(QPen(border_color, 1.0))

        # 底座渐变：上亮下暗，模拟内阴影
        gradient = QRadialGradient(QPointF(cx, cy + radius * 0.1), radius * 1.2)
        gradient.setColorAt(0.0, QColor(40, 44, 58, 180 + int(30 * intensity)))
        gradient.setColorAt(0.7, QColor(20, 22, 32, 220))
        gradient.setColorAt(1.0, QColor(10, 11, 18, 240))
        painter.setBrush(QBrush(gradient))
        painter.drawEllipse(QPointF(cx, cy), radius, radius)

    def _draw_led_core(self, painter, cx, cy, color, radius, intensity):
        """绘制 LED 发光核心（中心白点 -> 主色 -> 深色边缘）"""
        gradient = QRadialGradient(QPointF(cx - radius * 0.18, cy - radius * 0.18), radius * 1.35)

        # 中心高光点
        center = QColor(255, 255, 255, int(220 * intensity))
        gradient.setColorAt(0.0, center)
        gradient.setColorAt(0.12, QColor(color["core"].red(), color["core"].green(), color["core"].blue(), int(255 * intensity)))
        gradient.setColorAt(0.45, QColor(color["mid"].red(), color["mid"].green(), color["mid"].blue(), int(230 * intensity)))
        gradient.setColorAt(1.0, QColor(color["edge"].red(), color["edge"].green(), color["edge"].blue(), int(120 * intensity)))

        painter.setBrush(QBrush(gradient))
        painter.setPen(Qt.NoPen)
        painter.drawEllipse(QPointF(cx, cy), radius, radius)

    def _draw_rings(self, painter, cx, cy, radius, intensity):
        """绘制同心圆环装饰"""
        ring_alpha = 30 + int(50 * intensity)
        painter.setPen(QPen(QColor(255, 255, 255, ring_alpha), 1.0))
        painter.setBrush(Qt.NoBrush)
        painter.drawEllipse(QPointF(cx, cy), radius * 0.68, radius * 0.68)
        painter.setPen(QPen(QColor(255, 255, 255, int(ring_alpha * 0.6)), 0.8))
        painter.drawEllipse(QPointF(cx, cy), radius * 0.45, radius * 0.45)

    def _draw_gloss(self, painter, cx, cy, radius, intensity):
        """绘制玻璃高光条"""
        gloss_alpha = 60 + int(120 * intensity)
        rect_w = int(radius * 0.32)
        rect_h = int(radius * 1.1)
        rect_x = int(cx - rect_w / 2)
        rect_y = int(cy - rect_h / 2)

        gradient = QLinearGradient(rect_x, rect_y, rect_x + rect_w, rect_y + rect_h)
        gradient.setColorAt(0.0, QColor(255, 255, 255, int(0.25 * gloss_alpha)))
        gradient.setColorAt(0.5, QColor(255, 255, 255, int(0.55 * gloss_alpha)))
        gradient.setColorAt(1.0, QColor(255, 255, 255, 0))

        painter.setBrush(QBrush(gradient))
        painter.setPen(Qt.NoPen)
        painter.drawRoundedRect(rect_x, rect_y, rect_w, rect_h, rect_w / 2, rect_w / 2)
