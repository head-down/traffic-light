"""
终端窗口发现与跟踪 — 从 CodeBuddy PID 向上遍历进程树找到终端窗口

进程树结构（Windows 典型）:
    WindowsTerminal.exe → OpenConsole.exe → bash.exe → node.exe (CodeBuddy)
    cmd.exe → bash.exe → node.exe

两种终端类型:
  - GUI终端（WindowsTerminal等）：进程自己有可见窗口，EnumWindows 可找到
  - 控制台终端（cmd.exe/powershell.exe）：窗口由 conhost.exe 管理，
    需通过 AttachConsole + GetConsoleWindow 获取实际窗口句柄

算法: 从 node.exe 向上遍历，先尝试 EnumWindows 找有效窗口（w>50 h>50），
     找不到则用 AttachConsole 获取控制台窗口。
"""
import ctypes
import os
from ctypes import wintypes

kernel32 = ctypes.windll.kernel32
user32 = ctypes.windll.user32

TH32CS_SNAPPROCESS = 0x00000002
SW_SHOWMINIMIZED = 2
MIN_WINDOW_WIDTH = 50
MIN_WINDOW_HEIGHT = 50


class PROCESSENTRY32(ctypes.Structure):
    _fields_ = [
        ("dwSize", wintypes.DWORD),
        ("cntUsage", wintypes.DWORD),
        ("th32ProcessID", wintypes.DWORD),
        ("th32DefaultHeapID", ctypes.POINTER(wintypes.ULONG)),
        ("th32ModuleID", wintypes.DWORD),
        ("cntThreads", wintypes.DWORD),
        ("th32ParentProcessID", wintypes.DWORD),
        ("pcPriClassBase", wintypes.LONG),
        ("dwFlags", wintypes.DWORD),
        ("szExeFile", wintypes.CHAR * 260),
    ]


class WINDOWPLACEMENT(ctypes.Structure):
    _fields_ = [
        ("length", wintypes.DWORD),
        ("flags", wintypes.DWORD),
        ("showCmd", wintypes.DWORD),
        ("ptMinPosition", wintypes.POINT),
        ("ptMaxPosition", wintypes.POINT),
        ("rcNormalPosition", wintypes.RECT),
    ]


def get_parent_pid(pid):
    """通过 CreateToolhelp32Snapshot 获取父进程 PID"""
    snapshot = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snapshot == -1:
        return None

    entry = PROCESSENTRY32()
    entry.dwSize = ctypes.sizeof(PROCESSENTRY32)

    try:
        if kernel32.Process32First(snapshot, ctypes.byref(entry)):
            while True:
                if entry.th32ProcessID == pid:
                    kernel32.CloseHandle(snapshot)
                    return entry.th32ParentProcessID
                if not kernel32.Process32Next(snapshot, ctypes.byref(entry)):
                    break
    finally:
        kernel32.CloseHandle(snapshot)

    return None


def _enum_visible_windows(pid):
    """枚举指定 PID 的所有可见顶层窗口，返回 [(hwnd, title), ...]"""
    windows = []
    WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

    def callback(hwnd, lParam):
        process_id = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(process_id))
        if process_id.value == pid and user32.IsWindowVisible(hwnd):
            title_len = user32.GetWindowTextLengthW(hwnd)
            title = ""
            if title_len > 0:
                buf = ctypes.create_unicode_buffer(title_len + 1)
                user32.GetWindowTextW(hwnd, buf, title_len + 1)
                title = buf.value
            windows.append((hwnd, title))
        return True

    enum_proc = WNDENUMPROC(callback)
    user32.EnumWindows(enum_proc, 0)
    return windows


def _is_valid_window(hwnd):
    """检查窗口是否有合理的尺寸（排除零尺寸/无效窗口）"""
    rect = wintypes.RECT()
    if not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
        return False
    w = rect.right - rect.left
    h = rect.bottom - rect.top
    return w >= MIN_WINDOW_WIDTH and h >= MIN_WINDOW_HEIGHT


def _get_console_window_hwnd(pid):
    """
    获取控制台类型进程的实际可见终端窗口句柄。
    
    策略:
      1. AttachConsole → GetConsoleWindow → 获取伪控制台句柄
      2. 如果窗口类是 PseudoConsoleWindow（ConPTY），通过 GetWindow(GW_OWNER) 找到真正的宿主终端窗口
      3. 如果窗口类不是伪控制台，直接返回该窗口（传统 conhost 控制台）
    """
    saved_console = kernel32.GetConsoleWindow()

    kernel32.FreeConsole()
    hwnd = None
    if kernel32.AttachConsole(pid):
        hwnd = kernel32.GetConsoleWindow()
        kernel32.FreeConsole()

    # 恢复自己的控制台
    if saved_console:
        kernel32.AttachConsole(os.getpid())

    if not hwnd:
        return None, ""

    # 检查是否是伪控制台（ConPTY）
    GW_OWNER = 4
    owner = user32.GetWindow(hwnd, GW_OWNER)
    if owner and owner != hwnd:
        # ConPTY 伪控制台 → 用宿主终端窗口
        hwnd = owner

    if not _is_valid_window(hwnd):
        return None, ""

    # 获取终端窗口标题
    title_len = user32.GetWindowTextLengthW(hwnd)
    title = ""
    if title_len > 0:
        buf = ctypes.create_unicode_buffer(title_len + 1)
        user32.GetWindowTextW(hwnd, buf, title_len + 1)
        title = buf.value
    return hwnd, title


def _filter_valid_windows(windows):
    """过滤出尺寸有效且标题非空的窗口，按标题长度排序"""
    valid = [(hwnd, title) for hwnd, title in windows if _is_valid_window(hwnd)]
    valid.sort(key=lambda w: len(w[1]), reverse=True)
    return valid


def find_terminal_for_codebuddy(cb_pid):
    """
    从 CodeBuddy PID 向上遍历进程树，找到终端窗口。
    返回 (hwnd, pid, title) 或 (None, None, None)。

    两种查找策略：
      1. EnumWindows → 适用于 GUI 终端（WindowsTerminal、mintty 等）
      2. AttachConsole + GetConsoleWindow → 适用于控制台终端（cmd.exe、powershell.exe 等）
    """
    current_pid = cb_pid
    visited = set()

    for _ in range(10):
        if not current_pid or current_pid in visited or current_pid <= 4:
            break
        visited.add(current_pid)

        # 策略1: 查找进程自己的可见窗口（GUI终端）
        windows = _enum_visible_windows(current_pid)
        valid = _filter_valid_windows(windows)
        if valid:
            return valid[0][0], current_pid, valid[0][1]

        # 策略2: 查找控制台窗口（cmd.exe / powershell.exe）
        hwnd, title = _get_console_window_hwnd(current_pid)
        if hwnd:
            return hwnd, current_pid, title

        current_pid = get_parent_pid(current_pid)

    return None, None, None


def get_window_rect(hwnd):
    """获取窗口屏幕坐标，返回 (left, top, right, bottom)。
    用 GetWindowRect（逻辑坐标），与 SetWindowPos 坐标系统一致。"""
    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    return rect.left, rect.top, rect.right, rect.bottom


def is_window_visible_and_normal(hwnd):
    """检查窗口是否可见且未最小化"""
    if not user32.IsWindowVisible(hwnd):
        return False

    placement = WINDOWPLACEMENT()
    placement.length = ctypes.sizeof(WINDOWPLACEMENT)
    if user32.GetWindowPlacement(hwnd, ctypes.byref(placement)):
        return placement.showCmd != SW_SHOWMINIMIZED
    return True


def get_window_display_text(hwnd):
    """获取窗口标题文字"""
    title_len = user32.GetWindowTextLengthW(hwnd)
    if title_len > 0:
        buf = ctypes.create_unicode_buffer(title_len + 1)
        user32.GetWindowTextW(hwnd, buf, title_len + 1)
        return buf.value
    return ""


# ============ SetWinEventHook 事件驱动跟踪 ============
# 替代轮询：终端窗口位置变化时系统立刻通知，零延迟

EVENT_OBJECT_LOCATIONCHANGE = 0x800B
EVENT_SYSTEM_FOREGROUND = 0x0003
EVENT_SYSTEM_MINIMIZESTART = 0x0016
EVENT_SYSTEM_MINIMIZEEND = 0x0017
WINEVENT_OUTOFCONTEXT = 0x0000
WINEVENT_SKIPOWNPROCESS = 0x0002

_tracked_hooks = {}     # hwnd → (hook_handle, callback, win_event_proc_ref)
_hook_callbacks = {}    # hwnd → callback  # lookup for dispatch


WINEVENTPROC = ctypes.WINFUNCTYPE(
    None, wintypes.HANDLE, wintypes.DWORD, wintypes.HWND,
    wintypes.LONG, wintypes.LONG, wintypes.DWORD, wintypes.DWORD
)


@WINEVENTPROC
def _global_win_event(hWinEventHook, event, hwnd, idObject, idChild, dwEventThread, dwmsEventTime):
    """全局事件回调：按 HWND 分派到注册的回调"""
    if idObject != 0:  # 只处理窗口对象级别事件
        return
    cb = _hook_callbacks.get(hwnd)
    if cb:
        cb(event)


def install_terminal_hook(hwnd, pid, callback):
    """
    为指定终端窗口安装事件钩子，位置变化时立刻回调。
    
    监听事件:
      - EVENT_OBJECT_LOCATIONCHANGE: 窗口移动/改变大小（高频，去抖动处理）
      - EVENT_SYSTEM_FOREGROUND: 前台切换（更新 z-order）
      - EVENT_SYSTEM_MINIMIZESTART/END: 最小化/恢复
    """
    if hwnd in _tracked_hooks:
        return

    _hook_callbacks[hwnd] = callback

    hook1 = user32.SetWinEventHook(
        EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE,
        0, _global_win_event, pid, 0,
        WINEVENT_OUTOFCONTEXT
    )

    hook2 = user32.SetWinEventHook(
        EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_MINIMIZEEND,
        0, _global_win_event, pid, 0,
        WINEVENT_OUTOFCONTEXT
    )

    _tracked_hooks[hwnd] = (hook1, hook2)


def uninstall_terminal_hook(hwnd):
    """卸载终端窗口事件钩子"""
    hooks = _tracked_hooks.pop(hwnd, None)
    if hooks:
        for h in hooks:
            if h:
                user32.UnhookWinEvent(h)
    _hook_callbacks.pop(hwnd, None)
