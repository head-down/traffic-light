"""process_identity 测试：用真实进程验证 pid + 创建时间比对。"""
import ctypes
import os
import subprocess
import sys
from ctypes import wintypes

import pytest

import core.process_identity as process_identity

pytestmark = pytest.mark.skipif(os.name != "nt", reason="仅 Windows 进程 API")


def _own_creation_ft():
    """独立于被测代码，用 ctypes 直接查自己的创建时间"""
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL,
                                     wintypes.DWORD]
    kernel32.GetProcessTimes.argtypes = [wintypes.HANDLE] + [
        ctypes.POINTER(wintypes.FILETIME)] * 4
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]

    handle = kernel32.OpenProcess(0x1000, False, os.getpid())
    assert handle
    created, exited, kernel, user = (wintypes.FILETIME() for _ in range(4))
    ok = kernel32.GetProcessTimes(handle, ctypes.byref(created),
                                  ctypes.byref(exited),
                                  ctypes.byref(kernel),
                                  ctypes.byref(user))
    kernel32.CloseHandle(handle)
    assert ok
    return (created.dwHighDateTime << 32) | created.dwLowDateTime


def test_current_process_is_alive():
    assert process_identity.is_process_alive(os.getpid()) is True


def test_matching_creation_time_is_alive():
    ft = _own_creation_ft()
    assert process_identity.is_process_alive(os.getpid(), str(ft)) is True


def test_mismatched_creation_time_rejects_pid_reuse():
    ft = _own_creation_ft()
    assert process_identity.is_process_alive(os.getpid(), str(ft + 1)) is False


def test_missing_creation_time_treated_as_alive():
    assert process_identity.is_process_alive(os.getpid(), None) is True
    assert process_identity.is_process_alive(os.getpid(), "") is True


def test_finished_process_is_dead():
    proc = subprocess.Popen([sys.executable, "-c", "pass"])
    proc.wait()
    assert process_identity.is_process_alive(proc.pid) is False


def test_non_windows_returns_false(monkeypatch):
    monkeypatch.setattr(process_identity, "_IS_WINDOWS", False)
    assert process_identity.is_process_alive(os.getpid()) is False
