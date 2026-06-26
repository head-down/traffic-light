"""
终端窗口发现 — 从 CodeBuddy PID 向上遍历进程树找到终端窗口

进程树结构（Windows 典型）:
    WindowsTerminal.exe → OpenConsole.exe → bash.exe → node.exe (CodeBuddy)
    cmd.exe → bash.exe → node.exe

两种终端类型:
  - GUI终端（WindowsTerminal等）：进程自己有可见窗口，EnumWindows 可找到
  - 控制台终端（cmd.exe/powershell.exe）：窗口由 conhost.exe 管理，
    需通过 AttachConsole + GetConsoleWindow 获取实际窗口句柄

对外接口:
  get_my_terminal()              — termwnd 算法，精确匹配当前终端
  find_terminal_for_codebuddy()  — 进程树遍历（用于 bind.sh）
  find_terminal_by_any_codebuddy() — 全局扫描 + claim 机制（用于 TerminalAdapter 回退）
  get_window_rect()              — 获取窗口物理坐标
  is_window_visible_and_normal() — 检查窗口可见性/最小化
"""
import ctypes
import os
import time
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


# ============================================================
# 内部辅助函数
# ============================================================

def _get_window_title(hwnd):
    """获取窗口标题"""
    title_len = user32.GetWindowTextLengthW(hwnd)
    if title_len > 0:
        buf = ctypes.create_unicode_buffer(title_len + 1)
        user32.GetWindowTextW(hwnd, buf, title_len + 1)
        return buf.value
    return ""


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
        hwnd = owner

    if not _is_valid_window(hwnd):
        return None, ""

    return hwnd, _get_window_title(hwnd)


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
            title = _get_window_title(hwnd)
            windows.append((hwnd, title))
        return True

    enum_proc = WNDENUMPROC(callback)
    user32.EnumWindows(enum_proc, 0)
    return windows


def _filter_valid_windows(windows):
    """过滤出尺寸有效且标题非空的窗口，按标题长度排序"""
    valid = [(hwnd, title) for hwnd, title in windows if _is_valid_window(hwnd)]
    valid.sort(key=lambda w: len(w[1]), reverse=True)
    return valid


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
                exe_name = entry.szExeFile.decode("ascii", errors="ignore").lower()
                if exe_name == "node.exe":
                    pids.append(entry.th32ProcessID)
                if not kernel32.Process32Next(snapshot, ctypes.byref(entry)):
                    break
    finally:
        kernel32.CloseHandle(snapshot)

    # 降序排列 — 最新的进程（高 PID）更有可能是当前会话的 CodeBuddy
    pids.sort(reverse=True)
    return pids


def _looks_like_codebuddy_terminal(title):
    """快速判断终端窗口标题是否属于 CodeBuddy 会话。
    非 CodeBuddy 终端（如 Wox node-host、独立 node.exe 等）标题通常为裸文件路径，
    而 CodeBuddy 终端标题包含 cmd.exe / powershell / 管理员 等关键字。"""
    if not title:
        return False
    key = title.lower()
    return any(k in key for k in ('cmd.exe', 'powershell', '管理员', 'codebuddy'))


# ============================================================
# 策略函数
# ============================================================

def get_my_terminal():
    """
    termwnd 算法：直接从当前进程的控制台入手，精确匹配当前终端窗口。

    ConPTY 路径:
      Python → GetConsoleWindow → PseudoConsoleWindow(隐藏) → GW_OWNER → WindowsTerminal窗口

    传统 Conhost 路径:
      Python → GetConsoleWindow → conhost窗口 → 直接返回

    返回 (hwnd, title) 或 (None, None)。
    """
    hwnd = kernel32.GetConsoleWindow()
    if not hwnd:
        return None, None

    # WM_GETICON 试探终端类型（Windows Terminal 返回 0）
    # 注意：Windows 11 部分 conhost 版本也可能返回 0，不能单独依赖此判断
    WM_GETICON = 0x007F
    is_terminal = user32.SendMessageW(hwnd, WM_GETICON, 0, 0) == 0

    if not is_terminal:
        # 非终端窗口（传统 conhost），直接返回
        return hwnd, _get_window_title(hwnd)

    # 可能是 Windows Terminal (ConPTY)：轮询 GW_OWNER 获取宿主窗口
    GW_OWNER = 4
    for _ in range(100):
        owner = user32.GetWindow(hwnd, GW_OWNER)
        if owner and owner != hwnd and _is_valid_window(owner):
            return owner, _get_window_title(owner)
        time.sleep(0.005)

    # GW_OWNER 未找到宿主窗口 → 可能是 conhost（被 WM_GETICON 误判）
    # 直接返回原始窗口（Windows 11 conhost 可能返回 WM_GETICON=0）
    if _is_valid_window(hwnd):
        return hwnd, _get_window_title(hwnd)
    return None, None


def find_terminal_for_codebuddy(start_pid, skip_own_process=True):
    """
    从指定 PID 向上遍历进程树，找到终端窗口。
    返回 (hwnd, pid, title) 或 (None, None, None)。

    两种查找策略（按精确度排序）：
      1. AttachConsole + GetConsoleWindow → 精确匹配控制台会话
      2. EnumWindows → 回退方案，适用于纯 GUI 终端

    skip_own_process=True 时跳过遍历自己的 PID，防止把 Qt 窗口误识别为终端。
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

        # 策略1: AttachConsole 精确匹配控制台会话
        hwnd, title = _get_console_window_hwnd(current_pid)
        if hwnd:
            return hwnd, current_pid, title

        # 策略2: EnumWindows — GUI 终端回退
        windows = _enum_visible_windows(current_pid)
        valid = _filter_valid_windows(windows)
        for hwnd, title in valid:
            process_id = wintypes.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(process_id))
            if process_id.value != own_pid:
                return hwnd, current_pid, title

        current_pid = get_parent_pid(current_pid)

    return None, None, None


def find_terminal_by_any_codebuddy(state_dir=None, project_name=None):
    """
    遍历所有 node.exe 进程，对每个向上遍历进程树找终端窗口。

    Claim 机制: 读取 state_dir 下所有 .cbpid 文件，收集已声明的 PID。
    跳过已声明的 PID，确保不同项目各自获得不同的 CodeBuddy PID。

    返回 (hwnd, title) 或 (None, None)。
    """
    claimed = set()
    if state_dir and os.path.isdir(state_dir):
        for fname in os.listdir(state_dir):
            if fname.endswith(".cbpid"):
                try:
                    fpath = os.path.join(state_dir, fname)
                    if project_name and fname == f"{project_name}.cbpid":
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
            # 跳过非 CodeBuddy 终端（如 Wox node-host、独立 node.exe）
            if not _looks_like_codebuddy_terminal(title):
                continue
            if state_dir and project_name:
                try:
                    cbpid_file = os.path.join(state_dir, f"{project_name}.cbpid")
                    os.makedirs(state_dir, exist_ok=True)
                    with open(cbpid_file, "w") as f:
                        f.write(str(pid))
                except Exception:
                    pass
            return hwnd, title
    return None, None


# ============================================================
# 窗口工具函数
# ============================================================

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
