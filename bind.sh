#!/bin/bash
# ============================================================
# 终端红绿灯绑定脚本
#
# 用法:
#   source bind.sh <name>          绑定终端到红绿灯实例
#   light <state>                  更新状态 (running|success|failure|idle)
#   light status                   查询当前状态
#
# 示例:
#   source bind.sh build           # 启动红绿灯 "build"
#   light running                   # 设为运行中
#   npm run build                   # 执行任务
#   light success                   # 设为成功
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="/d/software/python/python"

# ---- 启动红绿灯实例 ----
_traffic_light_start() {
    local name="${1:-agent}"

    # 找可用端口
    local port=9527
    for ((i=0; i<10; i++)); do
        if ! (echo >/dev/tcp/127.0.0.1/$((port+i))) 2>/dev/null; then
            port=$((port+i))
            break
        fi
    done

    # 启动红绿灯（后台）
    "$PYTHON" "$SCRIPT_DIR/traffic_light.py" --name "$name" --port "$port" &
    local pid=$!
    sleep 2

    # 导出环境变量
    export TRAFFIC_LIGHT_PORT=$port
    export TRAFFIC_LIGHT_NAME=$name
    export TRAFFIC_LIGHT_PID=$pid

    # 注册退出时自动清理
    trap 'light idle; sleep 6; kill $TRAFFIC_LIGHT_PID 2>/dev/null' EXIT

    echo "[traffic-light] $name 已绑定, HTTP → http://127.0.0.1:$port"
}

# ---- 更新状态 ----
light() {
    local state="${1:-}"
    local port="${TRAFFIC_LIGHT_PORT:-}"

    if [ -z "$port" ]; then
        echo "[light] 未绑定红绿灯，请先执行: source bind.sh <name>"
        return 1
    fi

    case "$state" in
        running|success|failure|idle)
            curl -s -X POST "http://127.0.0.1:$port/state" \
                -H "Content-Type: application/json" \
                -d "{\"state\":\"$state\"}" > /dev/null
            echo "[light] $TRAFFIC_LIGHT_NAME → $state"
            ;;
        status|"")
            curl -s "http://127.0.0.1:$port/state"
            echo
            ;;
        *)
            echo "[light] 无效状态: $state (支持: running|success|failure|idle|status)"
            return 1
            ;;
    esac
}

# ---- 入口 ----
if [ $# -eq 0 ]; then
    echo "用法: source bind.sh <name>"
    echo "示例: source bind.sh build"
    return 1
fi

_traffic_light_start "$@"
