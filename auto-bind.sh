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

# ---- Start daemon (cleanup handled by bind.sh's PID alive check + stop-daemon.ps1) ----
bash "$SCRIPT_DIR/bind.sh" --project "$PROJECT" >/dev/null 2>&1

sleep 1
if [ -f "$PID_FILE" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') daemon started for $PROJECT (PID=$(cat $PID_FILE))" >> "$LOG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') daemon start FAILED for $PROJECT" >> "$LOG_FILE"
fi
