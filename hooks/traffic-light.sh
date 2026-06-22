#!/bin/bash
# ============================================================
# CodeBuddy Hook — 更新红绿灯状态（信号灯聚合模式）
#
# 用法（由 CodeBuddy 自动调用）:
#   hooks/traffic-light.sh <state>
#
# 自动从环境变量获取会话标识，多个 agent 并行时
# 红绿灯按优先级聚合显示（红灯 > 黄灯 > 绿灯 > 空闲）
# ============================================================

state="${1:-running}"

# 会话标识：优先使用 CodeBuddy 会话 ID，fallback 到终端 PID
if [ -n "$CODEBUDDY_SESSION_ID" ]; then
    session_id="$CODEBUDDY_SESSION_ID"
elif [ -n "$PPID" ]; then
    session_id="$$"
else
    session_id="unknown"
fi

# 端口：从文件读取（守护进程写入），或扫默认端口
port=""
port_file="/tmp/traffic-light-port"
if [ -f "$port_file" ]; then
    port=$(cat "$port_file")
fi

if [ -z "$port" ]; then
    for p in $(seq 9527 9536); do
        if curl -s --connect-timeout 0.5 "http://127.0.0.1:$p/health" >/dev/null 2>&1; then
            port=$p
            break
        fi
    done
fi

if [ -z "$port" ]; then
    exit 0  # 没找到守护进程，静默退出
fi

case "$state" in
    running|success|failure|idle)
        curl -s -X POST "http://127.0.0.1:$port/state" \
            -H "Content-Type: application/json" \
            -d "{\"state\":\"$state\",\"session_id\":\"$session_id\"}" \
            >/dev/null 2>&1
        ;;
    end)
        curl -s -X POST "http://127.0.0.1:$port/session/end" \
            -H "Content-Type: application/json" \
            -d "{\"session_id\":\"$session_id\"}" \
            >/dev/null 2>&1
        ;;
esac

exit 0
