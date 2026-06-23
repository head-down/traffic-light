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
import argparse
import signal

from PyQt5.QtWidgets import QApplication
from PyQt5.QtCore import Qt

from core.overlay_window import TrafficLightWindow
from core.light_panel import LightPanel
from core.state_manager import StateManager


def main():
    parser = argparse.ArgumentParser(description="信号灯守护进程")
    parser.add_argument("--project", type=str, default=None, help="绑定项目名（对应 <project>.state），不指定则聚合所有项目")
    args = parser.parse_args()

    # 单实例锁：同一项目只允许一个守护进程
    import ctypes as _ctypes
    _kernel32 = _ctypes.windll.kernel32
    _mutex_name = f"TrafficLight_{args.project or 'all'}"
    _mutex = _kernel32.CreateMutexW(None, False, _mutex_name)
    if _kernel32.GetLastError() == 183:  # ERROR_ALREADY_EXISTS
        print(f"[SignalLight] {args.project or 'all'} 的守护进程已在运行")
        _kernel32.CloseHandle(_mutex)
        sys.exit(0)

    # Qt 应用
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName("traffic-light")

    # 窗口
    window = TrafficLightWindow(name="SignalLight")

    # 灯面板
    panel = LightPanel(window)
    panel.setGeometry(0, 0, window.width(), window.height())

    # 状态管理器（文件系统轮询）
    state_mgr = StateManager(project=args.project)
    state_mgr.state_changed.connect(panel.set_state)
    state_mgr.state_changed.connect(window.set_glow_color)
    state_mgr.project_dir_changed.connect(panel.set_project_name)

    # 窗口显示
    window.show()

    # Ctrl+C 优雅退出
    def cleanup(signum=None, frame=None):
        app.quit()

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    try:
        import ctypes
        ctypes.windll.kernel32.SetConsoleCtrlHandler(None, False)
    except Exception:
        pass

    try:
        app.exec_()
    except KeyboardInterrupt:
        pass
    finally:
        _kernel32.CloseHandle(_mutex)


if __name__ == "__main__":
    main()
