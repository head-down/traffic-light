#!/bin/bash
# ============================================================
# CodeBuddy Hook — 更新红绿灯状态
#
# 用法（由 CodeBuddy 自动调用）:
#   hooks/traffic-light.sh <state>
#
# 需要先通过 bind.sh 启动红绿灯实例，
# 端口保存在 /tmp/traffic-light-port-<NAME> 文件中。
# ============================================================

state="${1:-running}"
port_file="/tmp/traffic-light-port-codebuddy"

# 尝试从端口文件获取端口
if [ -f "$port_file" ]; then
    port=$(cat "$port_file")
else
    # fallback: 扫默认端口范围
    port=""
    for p in $(seq 9527 9536); do
        if curl -s --connect-timeout 0.5 "http://127.0.0.1:$p/health" >/dev/null 2>&1; then
            port=$p
            break
        fi
    done
fi

if [ -z "$port" ]; then
    # 没有找到红绿灯实例，静默退出
    exit 0
fi

case "$state" in
    running|success|failure|idle)
        curl -s -X POST "http://127.0.0.1:$port/state" \
            -H "Content-Type: application/json" \
            -d "{\"state\":\"$state\"}" >/dev/null 2>&1
        ;;
esac

exit 0
