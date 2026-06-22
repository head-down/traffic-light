#!/usr/bin/env python
"""
信号灯守护进程 — Windows 桌面悬浮窗，聚合多个 CodeBuddy / CLI agent 状态

用法:
    python traffic_light.py              # 启动守护进程
    python traffic_light.py --port 9527  # 指定端口

Hook 脚本通过 HTTP 更新各自会话状态，守护进程按优先级聚合显示：
    红灯(失败) > 黄灯(运行中) > 绿灯(成功) > 灭灯(空闲)
"""
import sys
import argparse
import signal
import os

from PyQt5.QtWidgets import QApplication
from PyQt5.QtCore import Qt

from core.overlay_window import TrafficLightWindow
from core.light_panel import LightPanel
from core.state_manager import StateManager
from core.http_server import HTTPServerThread

PORT_FILE = "/tmp/traffic-light-port"


def main():
    parser = argparse.ArgumentParser(description="信号灯守护进程")
    parser.add_argument("--port", type=int, default=9527, help="HTTP 起始端口 (默认 9527)")
    args = parser.parse_args()

    # Qt 应用
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName("traffic-light")

    # 窗口
    window = TrafficLightWindow(name="SignalLight")

    # 灯面板
    panel = LightPanel(window)
    panel.setGeometry(0, 0, window.width(), window.height())

    # 状态管理器（多会话聚合）
    state_mgr = StateManager()
    state_mgr.state_changed.connect(panel.set_state)

    # HTTP 服务线程
    http_thread = HTTPServerThread(args.port, state_mgr, name="SignalLight")

    def on_port_bound(port):
        print(f"[SignalLight] 守护进程已启动, HTTP → http://127.0.0.1:{port}")
        print(f"[SignalLight] 等待 agent 连接...")
        # 写入端口文件
        try:
            with open(PORT_FILE, "w") as f:
                f.write(str(port))
        except Exception:
            pass

    http_thread.port_bound.connect(on_port_bound)
    http_thread.start()

    # 窗口显示
    window.show()

    # Ctrl+C 优雅退出
    def cleanup(signum=None, frame=None):
        http_thread.stop()
        try:
            os.remove(PORT_FILE)
        except Exception:
            pass
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
        http_thread.stop()
        try:
            os.remove(PORT_FILE)
        except Exception:
            pass


if __name__ == "__main__":
    main()
