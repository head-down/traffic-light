"""CodeBuddy hook 的无窗口入口（GUI 子系统，不产生控制台窗口）。

安装脚本把 hook 命令指向本文件：pythonw run-hidden.pyw <event>。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from core.hook_launcher import HOOK_SCRIPT, run_hook

if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    sys.exit(run_hook(sys.argv[1:], os.path.join(here, HOOK_SCRIPT)))
