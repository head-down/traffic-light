#!/bin/bash
# Feedback loop: does the daemon's heartbeat trust <project>.cbpid blindly?
# Usage: repro-heartbeat.sh <project> <cbpid-value> [wait-seconds]
# Exit: 0 = daemon ALIVE after wait, 1 = daemon DEAD
export LC_ALL=C.UTF-8
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$SCRIPT_DIR/.traffic-light-states"
PROJ="${1:?project required}"
FAKE="${2:?cbpid value required}"
WAIT="${3:-12}"

# 1) stop any existing daemon for this project
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$SCRIPT_DIR/stop-daemon.ps1" -Project "$PROJ" >/dev/null 2>&1
rm -f "$STATE/$PROJ.pid"
sleep 1

# 2) plant the cbpid we want the daemon to read
printf '%s' "$FAKE" > "$STATE/$PROJ.cbpid"

# 3) launch daemon via Task Scheduler (escapes the CodeBuddy Job Object)
TASK="traffic-light-repro-$PROJ"
EXE="$(cygpath -w "$SCRIPT_DIR/traffic_light.exe" 2>/dev/null || echo "D:\\DevelopTools\\mine\\traffic-light\\traffic_light.exe")"
MSYS_NO_PATHCONV=1 schtasks /Create /TN "$TASK" /TR "'$EXE' --project $PROJ" /SC ONCE /ST 23:59 /F >/dev/null 2>&1
MSYS_NO_PATHCONV=1 schtasks /Run /TN "$TASK" >/dev/null 2>&1
sleep 4
MSYS_NO_PATHCONV=1 schtasks /Delete /TN "$TASK" /F >/dev/null 2>&1

# 4) wait past two heartbeat ticks (2 x 5s)
sleep "$WAIT"

# 5) verdict
DPID=$(cat "$STATE/$PROJ.pid" 2>/dev/null | tr -d '\r\n')
if [ -n "$DPID" ] && MSYS_NO_PATHCONV=1 tasklist /FI "PID eq $DPID" 2>/dev/null | grep -q "$DPID"; then
    echo "RESULT: ALIVE  (daemon PID=$DPID, cbpid=$FAKE)"
    powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$SCRIPT_DIR/stop-daemon.ps1" -Project "$PROJ" >/dev/null 2>&1
    rm -f "$STATE/$PROJ.pid"
    exit 0
else
    echo "RESULT: DEAD   (daemon started with cbpid=$FAKE, no longer running)"
    exit 1
fi
