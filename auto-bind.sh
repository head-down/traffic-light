#!/bin/bash
# ============================================================
# 信号灯自动绑定 — 从 CODEBUDDY_PROJECT_DIR / PWD 提取项目名
# 供 CodeBuddy 全局 SessionStart hook 调用
# ============================================================

LOG_FILE="/d/DevelopTools/mine/traffic-light/.traffic-light-states/auto-bind.log"

# 提取项目名：优先 CODEBUDDY_PROJECT_DIR，其次当前目录
if [ -n "${CODEBUDDY_PROJECT_DIR:-}" ]; then
    PROJECT=$(basename "$CODEBUDDY_PROJECT_DIR")
else
    PROJECT=$(basename "$PWD")
fi

# No project name → fallback
[ -z "$PROJECT" ] && PROJECT="unknown"

# Debug log
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
echo "$(date '+%Y-%m-%d %H:%M:%S') CODEBUDDY_PROJECT_DIR='${CODEBUDDY_PROJECT_DIR:-}' PWD='$PWD' PROJECT='$PROJECT'" >> "$LOG_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 先强制停掉该项目的旧守护进程（处理上次 codebuddy 关闭后残留的进程）
PROC_NAME="traffic_light.py.*--project $PROJECT"
OLD_PID=$(ps -eo pid,args 2>/dev/null | grep "$PROC_NAME" | grep -v grep | awk '{print $1}')
if [ -n "$OLD_PID" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') killing old daemon PID=$OLD_PID for $PROJECT" >> "$LOG_FILE"
    kill $OLD_PID 2>/dev/null
    sleep 1
fi

bash "$SCRIPT_DIR/bind.sh" --project "$PROJECT" 2>&1 | while IFS= read -r line; do
    echo "$(date '+%Y-%m-%d %H:%M:%S') $line" >> "$LOG_FILE"
done
