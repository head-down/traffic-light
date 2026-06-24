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


# ============ termwnd 算法 ============
# 参考: https://github.com/german-one/termwnd
#
# 核心原理：直接用 GetConsoleWindow() 获取当前进程的控制台窗口，
# 不依赖 cb_pid/进程树/全局扫描。每个进程自己找自己的终端窗口，
# 天然不会在多终端场景下绑错。
#
# 算法流程:
#   1. GetConsoleWindow() — 获取当前进程的控制台窗口
#      (ConPTY 下返回隐藏的 PseudoConsoleWindow，传统 conhost 下返回 conhost 窗口)
#   2. SendMessage(WM_GETICON) — 判断终端类型:
#       返回 0 → Windows Terminal (ConPTY)
#       返回非 0 → 传统 Conhost
#   3a. 传统 Conhost: 直接返回该窗口
#   3b. Windows Terminal: GetWindow(hwnd, GW_OWNER) 获取宿主窗口
#
# 注意: 此算法要求进程有控制台（非 pythonw.exe，stdin 未被重定向关闭）


def get_my_terminal():
    """
    使用 termwnd 算法：直接从当前进程的控制台入手，精确匹配当前终端窗口。

    ConPTY 路径:
      Python → GetConsoleWindow → PseudoConsoleWindow(隐藏) → GW_OWNER → WindowsTerminal窗口

    传统 Conhost 路径:
      Python → GetConsoleWindow → conhost窗口 → 直接返回

    返回 (hwnd, title) 或 (None, None)。
    """
    import time

    hwnd = kernel32.GetConsoleWindow()
    if not hwnd:
        return None, None

    # WM_GETICON 判断终端类型
    WM_GETICON = 0x007F
    is_terminal = user32.SendMessageW(hwnd, WM_GETICON, 0, 0) == 0

    if not is_terminal:
        # 传统 conhost
        title = _get_window_title(hwnd)
        return hwnd, title

    # Windows Terminal: 轮询 GW_OWNER 获取宿主窗口
    GW_OWNER = 4
    for _ in range(100):
        owner = user32.GetWindow(hwnd, GW_OWNER)
        if owner and owner != hwnd and _is_valid_window(owner):
            title = _get_window_title(owner)
            return owner, title
        time.sleep(0.005)

    return None, None


def _get_window_title(hwnd):
    """获取窗口标题"""
    title_len = user32.GetWindowTextLengthW(hwnd)
    if title_len > 0:
        buf = ctypes.create_unicode_buffer(title_len + 1)
        user32.GetWindowTextW(hwnd, buf, title_len + 1)
        return buf.value
    return ""


def get_current_console_window():
    """
    获取当前 Python 进程的终端窗口句柄（不依赖任何外部 PID）。
    每个终端窗口有独立的控制台会话，Python 在该终端中启动，
    GetConsoleWindow 可直接定位到正确的窗口。

    ConPTY 路径: Python → GetConsoleWindow → PseudoConsoleWindow → GW_OWNER → WindowsTerminal
    传统控制台: Python → GetConsoleWindow → conhost 窗口

    如果 stdin 被重定向导致 GetConsoleWindow 返回 NULL（bind.sh 启动时
    </dev/null），则通过 AttachConsole(ATTACH_PARENT_PROCESS) 回退。

    返回 (hwnd, title) 或 (None, None)。
    """
    ATTACH_PARENT_PROCESS = -1
    GW_OWNER = 4

    hwnd = kernel32.GetConsoleWindow()
    if not hwnd:
        # stdin 重定向（</dev/null）时 GetConsoleWindow 可能返回 NULL
        # 用 ATTACH_PARENT_PROCESS 重新附加到父进程（bash）的控制台
        kernel32.FreeConsole()
        if kernel32.AttachConsole(ATTACH_PARENT_PROCESS):
            hwnd = kernel32.GetConsoleWindow()

    if not hwnd:
        return None, None

    owner = user32.GetWindow(hwnd, GW_OWNER)
    if owner and owner != hwnd:
        hwnd = owner

    if not _is_valid_window(hwnd):
        return None, None

    title = _get_window_title(hwnd)
    return hwnd, title


def find_terminal_for_codebuddy(start_pid, skip_own_process=True):
    """
    从指定 PID 向上遍历进程树，找到终端窗口。
    返回 (hwnd, pid, title) 或 (None, None, None)。

    两种查找策略（按精确度排序）：
      1. AttachConsole + GetConsoleWindow → 精确匹配控制台会话（ConPTY / 传统控制台）
      2. EnumWindows → 回退方案，适用于纯 GUI 终端（mintty 等）

    注意：策略1必须在策略2之前执行。在多终端场景下，
    EnumWindows 可能误选其他项目的终端窗口，而 AttachConsole
    通过控制台会话精确关联到当前进程的终端窗口。

    skip_own_process=True 时跳过遍历自己的 PID，防止把自己的
    GUI 窗口（如 Qt 灯窗口）误识别为终端窗口。
    """
    current_pid = start_pid
    visited = set()
    own_pid = os.getpid() if skip_own_process else -1

    for _ in range(10):
        if not current_pid or current_pid in visited or current_pid <= 4:
            break
        visited.add(current_pid)

        if current_pid == own_pid:
            current_pid = get_parent_pid(current_pid)
            continue

        # 策略1 (PRECISE): AttachConsole 精确匹配控制台会话
        # 对 ConPTY（WindowsTerminal）：bash → AttachConsole → PseudoConsoleWindow → GW_OWNER → 宿主窗口
        # 对传统控制台（cmd.exe）：AttachConsole → GetConsoleWindow → conhost 窗口
        hwnd, title = _get_console_window_hwnd(current_pid)
        if hwnd:
            return hwnd, current_pid, title

        # 策略2 (FALLBACK): EnumWindows — 适用于不影响控制台的 GUI 终端
        windows = _enum_visible_windows(current_pid)
        valid = _filter_valid_windows(windows)
        for hwnd, title in valid:
            # 确保不是自己进程的窗口（防止误选 Qt 窗口）
            process_id = wintypes.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(process_id))
            if process_id.value != own_pid:
                return hwnd, current_pid, title

        current_pid = get_parent_pid(current_pid)

    return None, None, None


def _find_all_node_pids():
    """通过 CreateToolhelp32Snapshot 搜索所有 node.exe 进程 PID（不依赖 PowerShell）"""
    snapshot = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snapshot == -1:
        return []

    entry = PROCESSENTRY32()
    entry.dwSize = ctypes.sizeof(PROCESSENTRY32)
    pids = []

    try:
        if kernel32.Process32First(snapshot, ctypes.byref(entry)):
            while True:
                exe_name = entry.szExeFile.decode('ascii', errors='ignore').lower()
                if exe_name == 'node.exe':
                    pids.append(entry.th32ProcessID)
                if not kernel32.Process32Next(snapshot, ctypes.byref(entry)):
                    break
    finally:
        kernel32.CloseHandle(snapshot)

    # 降序排列 — 最新的进程（高 PID）更有可能是当前会话的 CodeBuddy
    pids.sort(reverse=True)
    return pids


def find_terminal_by_any_codebuddy(state_dir=None, project_name=None):
    """
    遍历所有 node.exe 进程，对每个向上遍历进程树找终端窗口。

    Claim 机制: 读取 state_dir 下所有 .cbpid 文件，收集已声明的 PID。
    跳过已声明的 PID，确保不同项目各自获得不同的 CodeBuddy PID。

    返回 (hwnd, title) 或 (None, None)。
    """
    # 读取已声明的 PID（其他项目的 cbpid）
    claimed = set()
    if state_dir and os.path.isdir(state_dir):
        for fname in os.listdir(state_dir):
            if fname.endswith('.cbpid'):
                try:
                    fpath = os.path.join(state_dir, fname)
                    # 如果是本项目自己的 cbpid，跳过
                    if project_name and fname == f'{project_name}.cbpid':
                        continue
                    with open(fpath) as f:
                        claimed.add(int(f.read().strip()))
                except Exception:
                    pass

    for pid in _find_all_node_pids():
        if pid in claimed:
            continue
        hwnd, found_pid, title = find_terminal_for_codebuddy(pid)
        if hwnd:
            # 写入 cbpid 文件（声明此 PID 属于本项目）
            if state_dir and project_name:
                try:
                    cbpid_file = os.path.join(state_dir, f'{project_name}.cbpid')
                    os.makedirs(state_dir, exist_ok=True)
                    with open(cbpid_file, 'w') as f:
                        f.write(str(pid))
                except Exception:
                    pass
            return hwnd, title
    return None, None


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
