"""http_server HTTP API 单元测试"""
import sys
import os
import json
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from PyQt5.QtCore import QCoreApplication
_app = QCoreApplication(sys.argv)

from core.state_manager import StateManager
from core.http_server import (
    HTTPServerThread,
    find_available_port,
    _RequestHandler,
)


def test_find_available_port_returns_port():
    port = find_available_port()
    assert port >= 9527
    assert port <= 9536


def test_find_available_port_skips_occupied():
    """占用一个端口后自动跳到下一个"""
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 9527))
    try:
        port = find_available_port()
        assert port >= 9528  # 应跳过 9527
    finally:
        s.close()


def test_find_available_port_all_occupied_raises():
    """所有端口被占时应抛异常"""
    import socket
    sockets = []
    try:
        for offset in range(10):
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.bind(("127.0.0.1", 9527 + offset))
            sockets.append(s)
        try:
            find_available_port()
            assert False, "should have raised"
        except RuntimeError:
            pass  # 符合预期
    finally:
        for s in sockets:
            s.close()


# ---- HTTP API 集成测试 ----

def _get_json(url):
    """HTTP GET 返回 JSON"""
    import urllib.request
    with urllib.request.urlopen(url) as resp:
        return json.loads(resp.read())


def _post_json(url, data):
    """HTTP POST 返回 JSON"""
    import urllib.request
    body = json.dumps(data).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def test_get_health():
    port = find_available_port()
    sm = StateManager()
    server = HTTPServerThread(port, sm, name="test")
    server.start()

    import time
    time.sleep(0.3)

    result = _get_json(f"http://127.0.0.1:{port}/health")
    assert result["status"] == "ok"

    server.stop()


def test_get_state_returns_idle_initially():
    port = find_available_port()
    sm = StateManager()
    server = HTTPServerThread(port, sm, name="my-agent")
    server.start()

    import time
    time.sleep(0.3)

    result = _get_json(f"http://127.0.0.1:{port}/state")
    assert result["state"] == "idle"
    assert result["name"] == "my-agent"

    server.stop()


def test_post_state_updates_correctly():
    port = find_available_port()
    sm = StateManager()
    server = HTTPServerThread(port, sm, name="test")
    server.start()

    import time
    time.sleep(0.3)

    for state in ["running", "success", "failure", "idle"]:
        result = _post_json(f"http://127.0.0.1:{port}/state", {"state": state})
        assert result["status"] == "ok"
        assert result["state"] == state

        check = _get_json(f"http://127.0.0.1:{port}/state")
        assert check["state"] == state

    server.stop()


def test_post_invalid_state_returns_400():
    port = find_available_port()
    sm = StateManager()
    server = HTTPServerThread(port, sm, name="test")
    server.start()

    import time
    time.sleep(0.3)

    import urllib.request, urllib.error
    try:
        _post_json(f"http://127.0.0.1:{port}/state", {"state": "invalid"})
        assert False, "should have raised HTTPError"
    except urllib.error.HTTPError as e:
        assert e.code == 400
        body = json.loads(e.read())
        assert "error" in body

    # 状态未改变
    result = _get_json(f"http://127.0.0.1:{port}/state")
    assert result["state"] == "idle"

    server.stop()


def test_post_invalid_json_returns_400():
    port = find_available_port()
    sm = StateManager()
    server = HTTPServerThread(port, sm, name="test")
    server.start()

    import time
    time.sleep(0.3)

    import urllib.request, urllib.error
    try:
        body = b"not json"
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/state",
            data=body,
            headers={"Content-Type": "application/json"}
        )
        urllib.request.urlopen(req)
        assert False, "should have raised"
    except urllib.error.HTTPError as e:
        assert e.code == 400

    server.stop()


def test_get_unknown_path_returns_404():
    port = find_available_port()
    sm = StateManager()
    server = HTTPServerThread(port, sm, name="test")
    server.start()

    import time
    time.sleep(0.3)

    import urllib.request, urllib.error
    try:
        _get_json(f"http://127.0.0.1:{port}/unknown")
        assert False, "should have raised"
    except urllib.error.HTTPError as e:
        assert e.code == 404

    server.stop()


def test_post_unknown_path_returns_404():
    port = find_available_port()
    sm = StateManager()
    server = HTTPServerThread(port, sm, name="test")
    server.start()

    import time
    time.sleep(0.3)

    import urllib.request, urllib.error
    try:
        _post_json(f"http://127.0.0.1:{port}/unknown", {})
        assert False, "should have raised"
    except urllib.error.HTTPError as e:
        assert e.code == 404

    server.stop()
