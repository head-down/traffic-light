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

def _read_placement(hwnd):
    """一次 GetWindowPlacement，返回 (还原矩形, showCmd)；失败返回 None。"""
    placement = WINDOWPLACEMENT()
    placement.length = ctypes.sizeof(WINDOWPLACEMENT)
    if not user32.GetWindowPlacement(hwnd, ctypes.byref(placement)):
        return None
    normal = placement.rcNormalPosition
    return ((normal.left, normal.top, normal.right, normal.bottom),
            int(placement.showCmd))


def get_window_placement(hwnd):
    """窗口的还原矩形与 showCmd；调用失败返回 (None, 0)。"""
    result = _read_placement(hwnd)
    if result is None:
        return None, 0
    return result


def choose_window_rect(visible, restore, iconic=False):
    """在真实可见矩形与还原矩形之间选择。

    最小化的窗口只有 159x27 的桩尺寸，IsIconic 或尺寸异常时一律用还原
    矩形；正常/最大化窗口必须用真实矩形，否则灯会贴到旧的还原位置。
    """
    if restore is None:
        return visible
    if iconic or visible is None:
        return restore
    left, top, right, bottom = visible
    if right - left < MIN_WINDOW_WIDTH or bottom - top < MIN_WINDOW_HEIGHT:
        return restore
    return visible


def get_window_rect(hwnd):
    """获取可用的窗口矩形，返回 (left, top, right, bottom)。

    GetWindowRect（逻辑坐标，与 SetWindowPos 一致）优先；最小化或桩尺寸时
    退回 GetWindowPlacement 的还原矩形。
    """
    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    visible = (rect.left, rect.top, rect.right, rect.bottom)
    restore, _ = get_window_placement(hwnd)
    return choose_window_rect(visible, restore, iconic=bool(user32.IsIconic(hwnd)))


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
