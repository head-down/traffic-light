"""进程身份校验 — pid 必须配上正确的创建时间（FILETIME）。

PID 会被系统复用；只比对 pid 会把新进程认成旧会话，因此带
`creation_ft` 时用 GetProcessTimes 的创建时间做二次校验。
拿不到创建时间或查询失败时按存活处理（fail-open），避免误杀灯。
非 Windows 平台没有该 API，一律返回 False。
"""
import ctypes
import os

PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
STILL_ACTIVE = 259

_IS_WINDOWS = os.name == "nt"
_kernel32 = None


def _get_kernel32():
    global _kernel32
    if _kernel32 is None:
        from ctypes import wintypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.OpenProcess.restype = wintypes.HANDLE
        kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL,
                                         wintypes.DWORD]
        kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE,
                                                ctypes.POINTER(wintypes.DWORD)]
        kernel32.GetProcessTimes.argtypes = [wintypes.HANDLE] + [
            ctypes.POINTER(wintypes.FILETIME)] * 4
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        _kernel32 = kernel32
    return _kernel32


def _to_filetime(value):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def is_process_alive(pid, creation_ft=None):
    """pid 存活且创建时间匹配（若提供）时返回 True。

    creation_ft 为十进制 FILETIME 字符串（可空）：空值只校验存活；
    查询不到创建时间时按存活处理。
    """
    if not _IS_WINDOWS:
        return False
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False

    from ctypes import wintypes
    kernel32 = _get_kernel32()
    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,
                                  False, pid)
    if not handle:
        return False
    try:
        exit_code = wintypes.DWORD()
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
            return False
        if exit_code.value != STILL_ACTIVE:
            return False

        expected = _to_filetime(creation_ft) if creation_ft else None
        if not expected:
            return True

        created = wintypes.FILETIME()
        exited = wintypes.FILETIME()
        kernel = wintypes.FILETIME()
        user = wintypes.FILETIME()
        if not kernel32.GetProcessTimes(handle, ctypes.byref(created),
                                        ctypes.byref(exited),
                                        ctypes.byref(kernel),
                                        ctypes.byref(user)):
            return True
        actual = (created.dwHighDateTime << 32) | created.dwLowDateTime
        return actual == expected
    finally:
        kernel32.CloseHandle(handle)
