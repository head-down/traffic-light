#!/bin/bash
# ============================================================
# Signal Light auto-stop — kill daemon + cleanup on SessionEnd
# ============================================================
export LC_ALL=C.UTF-8

LOG_FILE="/d/DevelopTools/mine/traffic-light/.traffic-light-states/auto-bind.log"

# Extract project name
if [ -n "${CODEBUDDY_PROJECT_DIR:-}" ]; then
    PROJECT=$(basename "$CODEBUDDY_PROJECT_DIR")
else
    PROJECT=$(basename "$PWD")
fi
[ -z "$PROJECT" ] && PROJECT="unknown"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Windows 路径转换（PowerShell 不能解析 /d/... Unix 风格路径）
WIN_SCRIPT_DIR="${SCRIPT_DIR:1:1}:${SCRIPT_DIR:2}"
PID_FILE="$SCRIPT_DIR/.traffic-light-states/$PROJECT.pid"

# ---- 1. Clean state file ----
bash "$SCRIPT_DIR/hooks/traffic-light.sh" end

# ---- 2. Kill daemon ----
STOPPED=0

# 2a. Kill by PID file using PowerShell Stop-Process
#    bash 的 kill 对 Windows pythonw.exe 无效，且 2>/dev/null 遮盖了错误
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$PID" ]; then
        # 用 PowerShell 杀进程并验证是否成功（500ms 后复查）
        if powershell -NoProfile -Command "
            Stop-Process -Id $PID -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            if (Get-Process -Id $PID -ErrorAction SilentlyContinue) { exit 1 } else { exit 0 }
        " > /dev/null 2>&1; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') SessionEnd: killed daemon PID=$PID for $PROJECT" >> "$LOG_FILE"
            STOPPED=1
            rm -f "$PID_FILE"  # 只有杀成功才删 PID 文件
        fi
    fi
fi

# 2b. Fallback: stop-daemon.ps1（ps on Git Bash doesn't show arguments）
if [ $STOPPED -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') SessionEnd: stop-daemon.ps1 fallback for $PROJECT" >> "$LOG_FILE"
    powershell -NoProfile -WindowStyle Hidden -File "$WIN_SCRIPT_DIR/stop-daemon.ps1" -Project "$PROJECT" 2>/dev/null
fi

exit 0
