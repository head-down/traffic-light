#!/usr/bin/env python
"""从 stdin 读取 PostToolUse JSON，检测工具执行失败。退出码 0=失败, 1=正常。"""
import sys, json

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

resp = data.get('tool_response', {})

if isinstance(resp, dict):
    # tool_response.success 显式为 False
    if resp.get('success') is False:
        sys.exit(0)

    # tool_response 包含 error 字段
    if 'error' in resp:
        sys.exit(0)

    # Bash 工具 exitCode 非零
    if data.get('tool_name') == 'Bash' and resp.get('exitCode', 0) != 0:
        sys.exit(0)

sys.exit(1)
