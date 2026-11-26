"""
终端窗口工具 — 按 hwnd 查询窗口状态，供 drawer 跟随定位使用

drawer 的 hwnd 由解析器通过命令行传入，Python 侧不再自行发现终端；
binding 的 hwnd 同样只由解析器写入。这里只保留纯窗口查询。

对外接口:
  get_window_rect()              — 获取窗口物理坐标
  is_window_visible_and_normal() — 检查窗口可见性/最小化
  is_window()                    — 窗口句柄是否仍然有效
  get_window_owner()             — 窗口所属进程 (pid, creation_ft)
  _enum_visible_windows()        — 枚举某 pid 的可见顶层窗口
"""
import ctypes
from ctypes import wintypes

user32 = ctypes.windll.user32

SW_SHOWMINIMIZED = 2
MIN_WINDOW_WIDTH = 50
MIN_WINDOW_HEIGHT = 50


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


def is_window(hwnd):
    """窗口句柄是否仍然有效（IsWindow）"""
    return bool(user32.IsWindow(hwnd))


def get_window_owner(hwnd):
    """窗口所属进程的 (pid, 创建时间 FILETIME 字符串)；无效窗口返回 (0, "")"""
    if not hwnd:
        return 0, ""
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    if not pid.value:
        return 0, ""
    from core.process_identity import process_creation_ft
    return int(pid.value), process_creation_ft(int(pid.value))
