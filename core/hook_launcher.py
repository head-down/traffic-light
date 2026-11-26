"""CodeBuddy hook 的无窗口启动器。

CodeBuddy 从不带控制台的进程里拉起 hook 命令：直接调 bash / powershell 会新建
一个可见的控制台窗口，每个事件闪一下。入口因此改成 GUI 子系统的宿主
（pythonw 或 traffic_light.exe），再用 CREATE_NO_WINDOW 拉起 bash；bash 在
隐藏控制台里继承给 powershell，整条链路都没有窗口。
"""
import os
import subprocess
import sys

CREATE_NO_WINDOW = 0x08000000
HOOK_SCRIPT = "traffic-light.sh"


def hooks_dir():
    """hook 脚本所在目录：源码版 = <repo>/hooks，frozen = 包内 / EXE 旁。"""
    if getattr(sys, "frozen", False):
        base = getattr(sys, "_MEIPASS", os.path.dirname(sys.executable))
        return os.path.join(base, "hooks")
    return os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks")


def exec_hidden(argv):
    """用 CREATE_NO_WINDOW 跑任意命令；给 hook 里的 powershell 用。"""
    if not argv:
        return 0
    return subprocess.run(
        list(argv),
        stdin=subprocess.DEVNULL if sys.stdin is None else sys.stdin,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=CREATE_NO_WINDOW,
    ).returncode


def run_hook(argv, hooks_path=None):
    """执行 hooks/traffic-light.sh <event...>，返回其退出码。"""
    if not argv:
        return 0
    script = hooks_path or os.path.join(hooks_dir(), HOOK_SCRIPT)
    env = dict(os.environ)
    env["LC_ALL"] = "C.UTF-8"
    stdin = subprocess.DEVNULL if sys.stdin is None else sys.stdin
    return subprocess.run(
        [os.environ.get("TRAFFIC_LIGHT_BASH", "bash"),
         "--noprofile", "--norc", script] + list(argv),
        env=env,
        stdin=stdin,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=CREATE_NO_WINDOW,
    ).returncode
