#!/usr/bin/env python
"""
信号灯守护进程 — Windows 桌面悬浮窗，聚合多个 CodeBuddy / CLI agent 状态

用法:
    python traffic_light.py                      # 启动守护进程（聚合所有项目）
    python traffic_light.py --project mine       # 绑定到指定项目

Hook 脚本通过文件系统写状态文件，守护进程 300ms 轮询聚合显示:
    红灯(失败) > 黄灯(运行中) > 绿灯(成功) > 灭灯(空闲)
"""
import sys
import os
import ctypes
import argparse

# 必须在 QApplication 创建前设置 DPI awareness
# 系统 DPI 缩放 150%，不设置的话 GetWindowRect 返回虚拟化坐标（缩放后的），
# 导致 SetWindowPos 定位错误
# 用 SetProcessDpiAwarenessContext (Per-Monitor V2) 优先，回退到 V1
_dpi_set = False
try:
    # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
    ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
    _dpi_set = True
except Exception:
    pass
if not _dpi_set:
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)  # PER_MONITOR_AWARE
        _dpi_set = True
    except Exception:
        try:
            ctypes.windll.user32.SetProcessDPIAware()
            _dpi_set = True
        except Exception:
            pass

from PyQt5.QtWidgets import QApplication

from core.overlay_window import TrafficLightWindow
from core.light_panel import LightPanel
from core.state_manager import StateManager
from core.lifecycle import LifecycleManager
from core.terminal_adapter import TerminalAdapter
from core.position_engine import PositionEngine


def main():
    parser = argparse.ArgumentParser(description="信号灯守护进程")
    parser.add_argument(
        "--project", type=str, default=None,
        help="绑定项目名（对应 <project>.state），不指定则聚合所有项目",
    )
    args = parser.parse_args()

    pid_dir = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), ".traffic-light-states"
    )

    # Phase 1: 进程生命周期（PID 锁 + 日志重定向 + PID 文件写入）
    lifecycle = LifecycleManager(args.project, pid_dir)

    # Phase 2: Qt 应用
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName("traffic-light")

    lifecycle.start_heartbeat(app)
    lifecycle.setup_signal_handlers(app)

    # UI: 窗口 + 灯面板
    window = TrafficLightWindow(name="SignalLight")
    panel = LightPanel(window)
    panel.setGeometry(0, 0, window.width(), window.height())

    # 状态管理（文件系统轮询 → UI）
    state_mgr = StateManager(project=args.project)
    state_mgr.state_changed.connect(panel.set_state)
    state_mgr.state_changed.connect(window.set_glow_color)
    state_mgr.project_dir_changed.connect(panel.set_project_name)

    # 终端发现 + 60fps 位置跟踪
    terminal = TerminalAdapter(args.project, pid_dir)
    position = PositionEngine(app, window, terminal)
    position.start()

    try:
        app.exec_()
    except KeyboardInterrupt:
        pass
    finally:
        lifecycle.cleanup()


if __name__ == "__main__":
    main()
