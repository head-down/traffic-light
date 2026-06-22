#!/usr/bin/env python
"""
CLI 红绿灯状态指示器 — Windows 桌面悬浮窗

用法:
    python traffic_light.py --name build
    curl -X POST http://127.0.0.1:9527/state -d '{"state":"running"}'
    curl -X POST http://127.0.0.1:9527/state -d '{"state":"success"}'
"""
import sys
import argparse
import signal

from PyQt5.QtWidgets import QApplication
from PyQt5.QtCore import Qt

from core.overlay_window import TrafficLightWindow
from core.light_panel import LightPanel
from core.state_manager import StateManager
from core.http_server import HTTPServerThread


def main():
    parser = argparse.ArgumentParser(description="CLI 红绿灯状态指示器")
    parser.add_argument("--name", default="agent", help="实例名称，显示在灯下方")
    parser.add_argument("--port", type=int, default=9527, help="HTTP 起始端口 (默认 9527)")
    args = parser.parse_args()

    # Qt 应用
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)

    # 设置进程标题（Windows 任务管理器中可见）
    app.setApplicationName(f"traffic-light ({args.name})")

    # 窗口
    window = TrafficLightWindow(name=args.name)

    # 灯面板
    panel = LightPanel(window)
    panel.setGeometry(0, 0, window.width(), window.height())

    # 状态管理器
    state_mgr = StateManager()
    state_mgr.state_changed.connect(panel.set_state)

    # HTTP 服务线程（端口冲突时自动递增，无竞态）
    http_thread = HTTPServerThread(args.port, state_mgr, name=args.name)

    def on_port_bound(port):
        print(f"[traffic-light] {args.name} 已启动, HTTP → http://127.0.0.1:{port}")

    http_thread.port_bound.connect(on_port_bound)
    http_thread.start()

    # 窗口显示
    window.show()

    # Ctrl+C 优雅退出
    def cleanup(signum=None, frame=None):
        http_thread.stop()
        app.quit()

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    # 确保 Python 能收到 Ctrl+C（Windows）
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
        http_thread.stop()


if __name__ == "__main__":
    main()
