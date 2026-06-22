"""
HTTP 服务 — stdlib http.server 运行于 QThread，零额外依赖
"""
import json
import socket
from http.server import HTTPServer, BaseHTTPRequestHandler
from PyQt5.QtCore import QThread, pyqtSignal


class _ExclusiveHTTPServer(HTTPServer):
    """禁用 SO_REUSEADDR，确保端口独占绑定，冲突时抛 OSError"""
    allow_reuse_address = False

    def server_bind(self):
        # Windows: 额外设置 SO_EXCLUSIVEADDRUSE 防止端口被复用
        if hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()


class _RequestHandler(BaseHTTPRequestHandler):
    """HTTP 请求处理器（在 QThread 中运行）"""
    state_manager = None
    server_name = "agent"

    def log_message(self, format, *args):
        pass

    def _json_response(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/state":
            state = self.state_manager.state if self.state_manager else "idle"
            self._json_response(200, {"state": state, "name": self.server_name})
        elif self.path == "/health":
            self._json_response(200, {"status": "ok"})
        else:
            self._json_response(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/state":
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(length)) if length > 0 else {}
                new_state = body.get("state", "").strip().lower()
            except (json.JSONDecodeError, ValueError):
                self._json_response(400, {"error": "invalid json"})
                return

            if self.state_manager:
                ok = self.state_manager.update_state(new_state)
                if ok:
                    self._json_response(200, {"status": "ok", "state": new_state})
                else:
                    self._json_response(400, {
                        "error": "invalid state",
                        "valid": ["idle", "running", "success", "failure"]
                    })
            else:
                self._json_response(500, {"error": "state manager not available"})
        else:
            self._json_response(404, {"error": "not found"})


class HTTPServerThread(QThread):
    """在独立线程中运行 HTTP 服务器，端口冲突时自动重试下一个"""

    port_bound = pyqtSignal(int)

    def __init__(self, start_port, state_manager, name="agent", max_retries=10):
        super().__init__()
        self._start_port = start_port
        self._state_manager = state_manager
        self._name = name
        self._max_retries = max_retries
        self._server = None
        self._running = True
        self._actual_port = 0

    @property
    def port(self):
        return self._actual_port

    def run(self):
        _RequestHandler.state_manager = self._state_manager
        _RequestHandler.server_name = self._name

        # 尝试绑定端口，冲突时自动递增（原子操作，无竞态）
        for offset in range(self._max_retries):
            port = self._start_port + offset
            try:
                self._server = _ExclusiveHTTPServer(("127.0.0.1", port), _RequestHandler)
                self._actual_port = port
                self.port_bound.emit(port)
                break
            except OSError:
                continue
        else:
            print(f"[traffic-light] 无法绑定端口 {self._start_port}-{self._start_port + self._max_retries - 1}")
            return

        self._server.timeout = 1
        while self._running:
            self._server.handle_request()

    def stop(self):
        self._running = False
        if self._server:
            try:
                self._server.server_close()
            except Exception:
                pass
        self.wait(2000)


def find_available_port(start=9527, max_attempts=10):
    """从 start 开始找可用端口"""
    import socket
    for offset in range(max_attempts):
        port = start + offset
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise RuntimeError(f"无法在 {start}-{start + max_attempts - 1} 范围内找到可用端口")
