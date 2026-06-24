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
PID_FILE="$SCRIPT_DIR/.traffic-light-states/$PROJECT.pid"

# ---- 1. Clean state file ----
bash "$SCRIPT_DIR/hooks/traffic-light.sh" end

# ---- 2. Kill daemon ----
STOPPED=0

# 2a. Try PID file
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$PID" ] && kill "$PID" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') SessionEnd: killed daemon PID=$PID for $PROJECT" >> "$LOG_FILE"
        STOPPED=1
    fi
    rm -f "$PID_FILE"
fi

# 2b. Fallback: PowerShell (ps on Git Bash doesn't show arguments)
if [ $STOPPED -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') SessionEnd: trying PowerShell fallback for $PROJECT" >> "$LOG_FILE"
    powershell -NoProfile -WindowStyle Hidden -Command "Get-Process -Name python* -ErrorAction SilentlyContinue | Where-Object { try { (Get-CimInstance Win32_Process -Filter \"ProcessId = \$($_.Id)\").CommandLine -match 'traffic_light.*--project $PROJECT' } catch { \$false } } | Stop-Process -Force -ErrorAction SilentlyContinue" 2>/dev/null
fi

exit 0
