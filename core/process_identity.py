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

# FILETIME 的单位是 100ns。creation_ft 有两个来源：CIM/WMI（微秒精度）和
# GetProcessTimes（精确到 tick），同一个进程两边实测差 4~7 个 tick。精确相等
# 会把活进程判成「pid 已复用」，所以留 10µs 的转换误差窗口——仍远小于任何
# 可能的 pid 复用间隔。
FT_TOLERANCE = 100  # 10µs

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


def creation_ft_matches(expected, actual, tolerance=FT_TOLERANCE):
    """两个 FILETIME 是否指向同一个进程；任一侧缺失按匹配处理（fail-open）。"""
    exp = _to_filetime(expected)
    act = _to_filetime(actual)
    if not exp or not act:
        return True
    return abs(exp - act) <= tolerance


def process_creation_ft(pid):
    """返回进程创建时间（十进制 FILETIME 字符串）；拿不到返回空串。"""
    if not _IS_WINDOWS:
        return ""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return ""
    if pid <= 0:
        return ""

    from ctypes import wintypes
    kernel32 = _get_kernel32()
    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,
                                  False, pid)
    if not handle:
        return ""
    try:
        created = wintypes.FILETIME()
        exited = wintypes.FILETIME()
        kernel = wintypes.FILETIME()
        user = wintypes.FILETIME()
        if not kernel32.GetProcessTimes(handle, ctypes.byref(created),
                                        ctypes.byref(exited),
                                        ctypes.byref(kernel),
                                        ctypes.byref(user)):
            return ""
        return str((created.dwHighDateTime << 32) | created.dwLowDateTime)
    finally:
        kernel32.CloseHandle(handle)


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
        return creation_ft_matches(expected, actual)
    finally:
        kernel32.CloseHandle(handle)
