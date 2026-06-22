"""http_server HTTP API 单元测试（信号灯聚合模式）"""
import sys
import os
import json
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from PyQt5.QtCore import QCoreApplication
_app = QCoreApplication(sys.argv)

from core.state_manager import StateManager
from core.http_server import HTTPServerThread, find_available_port


def test_find_available_port_returns_port():
    port = find_available_port()
    assert port >= 9527


def test_find_available_port_skips_occupied():
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 9527))
    try:
        port = find_available_port()
        assert port >= 9528
    finally:
        s.close()


def test_find_available_port_all_occupied_raises():
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
            pass
    finally:
        for s in sockets:
            s.close()


# ---- HTTP 辅助 ----

def _get_json(url):
    import urllib.request
    with urllib.request.urlopen(url) as resp:
        return json.loads(resp.read())


def _post_json(url, data):
    import urllib.request
    body = json.dumps(data).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def _start_server(port=None, name="test"):
    if port is None:
        port = find_available_port()
    sm = StateManager()
    server = HTTPServerThread(port, sm, name=name)
    server.start()
    import time
    time.sleep(0.3)
    return server, sm, server.port


# ---- API 测试 ----

def test_get_health():
    server, _, port = _start_server()
    result = _get_json(f"http://127.0.0.1:{port}/health")
    assert result["status"] == "ok"
    server.stop()


def test_get_state_returns_idle_and_sessions():
    server, sm, port = _start_server()
    result = _get_json(f"http://127.0.0.1:{port}/state")
    assert result["state"] == "idle"
    assert result["sessions"] == 0
    server.stop()


def test_post_state_with_session_id():
    server, sm, port = _start_server()
    result = _post_json(f"http://127.0.0.1:{port}/state", {
        "state": "running",
        "session_id": "agent-1",
    })
    assert result["status"] == "ok"
    assert result["state"] == "running"
    assert result["session_id"] == "agent-1"
    assert result["aggregated"] == "running"
    assert result["sessions"] == 1
    server.stop()


def test_post_state_aggregates_multiple_sessions():
    server, sm, port = _start_server()

    _post_json(f"http://127.0.0.1:{port}/state", {"state": "success", "session_id": "s1"})
    _post_json(f"http://127.0.0.1:{port}/state", {"state": "running", "session_id": "s2"})
    result = _get_json(f"http://127.0.0.1:{port}/state")
    assert result["state"] == "running"  # running > success
    assert result["sessions"] == 2

    _post_json(f"http://127.0.0.1:{port}/state", {"state": "failure", "session_id": "s3"})
    result = _get_json(f"http://127.0.0.1:{port}/state")
    assert result["state"] == "failure"  # failure > running
    assert result["sessions"] == 3

    server.stop()


def test_post_session_end():
    server, sm, port = _start_server()

    _post_json(f"http://127.0.0.1:{port}/state", {"state": "running", "session_id": "s1"})
    _post_json(f"http://127.0.0.1:{port}/state", {"state": "success", "session_id": "s2"})
    assert sm.session_count == 2

    import urllib.request
    body = json.dumps({"session_id": "s1"}).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/session/end",
        data=body,
        headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req) as resp:
        result = json.loads(resp.read())

    assert result["status"] == "ok"
    assert result["aggregated"] == "success"
    assert result["sessions"] == 1
    server.stop()


def test_post_invalid_state_returns_400():
    server, sm, port = _start_server()
    import urllib.request, urllib.error
    try:
        _post_json(f"http://127.0.0.1:{port}/state", {"state": "invalid"})
        assert False
    except urllib.error.HTTPError as e:
        assert e.code == 400
    server.stop()


def test_post_invalid_json_returns_400():
    server, sm, port = _start_server()
    import urllib.request, urllib.error
    try:
        body = b"not json"
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/state", data=body,
            headers={"Content-Type": "application/json"}
        )
        urllib.request.urlopen(req)
        assert False
    except urllib.error.HTTPError as e:
        assert e.code == 400
    server.stop()


def test_unknown_path_404():
    server, sm, port = _start_server()
    import urllib.request, urllib.error
    try:
        _get_json(f"http://127.0.0.1:{port}/unknown")
        assert False
    except urllib.error.HTTPError as e:
        assert e.code == 404
    server.stop()
