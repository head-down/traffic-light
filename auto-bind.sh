#!/bin/bash
# ============================================================
# Signal Light auto-bind — start daemon on SessionStart
# ============================================================
export LC_ALL=C.UTF-8

LOG_FILE="/d/DevelopTools/mine/traffic-light/.traffic-light-states/auto-bind.log"

# Extract project name from CODEBUDDY_PROJECT_DIR or PWD
if [ -n "${CODEBUDDY_PROJECT_DIR:-}" ]; then
    PROJECT=$(basename "$CODEBUDDY_PROJECT_DIR")
else
    PROJECT=$(basename "$PWD")
fi
[ -z "$PROJECT" ] && PROJECT="unknown"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
echo "$(date '+%Y-%m-%d %H:%M:%S') SessionStart PROJECT=$PROJECT PWD=$PWD" >> "$LOG_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/.traffic-light-states/$PROJECT.pid"

# ---- Kill old daemon ----
KILLED=0

# 1. Try PID file first
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        kill "$OLD_PID" 2>/dev/null && KILLED=1
        echo "$(date '+%Y-%m-%d %H:%M:%S') killed old daemon PID=$OLD_PID for $PROJECT" >> "$LOG_FILE"
        sleep 1
    fi
    rm -f "$PID_FILE"
fi

# 2. Fallback: use PowerShell to find/kill by command line
#    (ps on Git Bash does NOT show arguments, so grep fails)
if [ $KILLED -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') trying PowerShell fallback for $PROJECT" >> "$LOG_FILE"
    powershell -NoProfile -WindowStyle Hidden -Command "Get-Process -Name python* -ErrorAction SilentlyContinue | Where-Object { try { (Get-CimInstance Win32_Process -Filter \"ProcessId = \$($_.Id)\").CommandLine -match 'traffic_light.*--project $PROJECT' } catch { \$false } } | Stop-Process -Force -ErrorAction SilentlyContinue" 2>/dev/null
fi

# ---- Start daemon ----
bash "$SCRIPT_DIR/bind.sh" --project "$PROJECT" >/dev/null 2>&1

sleep 1
if [ -f "$PID_FILE" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') daemon started for $PROJECT (PID=$(cat $PID_FILE))" >> "$LOG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') daemon start FAILED for $PROJECT" >> "$LOG_FILE"
fi
