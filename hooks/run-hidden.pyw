"""CodeBuddy hook 的无窗口入口（GUI 子系统，不产生控制台窗口）。

安装脚本把 hook 命令指向本文件：pythonw run-hidden.pyw <event>。
--exec 模式供 hook 内部启动 powershell 用：从 bash 直接拉 powershell 会让它
新建一个控制台（Windows Terminal 会闪一个黑框），经这里启动则没有窗口。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from core.hook_launcher import HOOK_SCRIPT, exec_hidden, run_hook

if __name__ == "__main__":
    if sys.argv[1:2] == ["--exec"]:
        sys.exit(exec_hidden(sys.argv[2:]))
    here = os.path.dirname(os.path.abspath(__file__))
    sys.exit(run_hook(sys.argv[1:], os.path.join(here, HOOK_SCRIPT)))
