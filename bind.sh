#!/bin/bash
# ============================================================
# 信号灯守护进程启动脚本
#
# 用法:
#   source bind.sh                 启动守护进程（如已运行则复用）
#   light <state>                  手动更新状态
#   light status                   查询聚合状态
#
# 守护进程只有一个，多终端 agent 共享同一盏灯，
# 按优先级聚合显示：红灯 > 黄灯 > 绿灯 > 空闲
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="/d/software/python/python"
PORT_FILE="/tmp/traffic-light-port"

# ---- 启动守护进程 ----
_traffic_light_daemon() {
    # 检查是否已运行
    if [ -f "$PORT_FILE" ]; then
        local existing_port
        existing_port=$(cat "$PORT_FILE")
        if curl -s --connect-timeout 1 "http://127.0.0.1:$existing_port/health" >/dev/null 2>&1; then
            export TRAFFIC_LIGHT_PORT=$existing_port
            echo "[SignalLight] 已连接守护进程, HTTP → http://127.0.0.1:$existing_port"
            return 0
        fi
        # 端口文件残留，清理
        rm -f "$PORT_FILE"
    fi

    # 扫可用端口
    local port=""
    for ((i=0; i<10; i++)); do
        if ! curl -s --connect-timeout 0.5 "http://127.0.0.1:$((9527 + i))/health" >/dev/null 2>&1; then
            port=$((9527 + i))
            break
        fi
    done

    if [ -z "$port" ]; then
        echo "[SignalLight] 无法绑定端口，请检查是否已有其他实例运行"
        return 1
    fi

    # 启动守护进程
    "$PYTHON" "$SCRIPT_DIR/traffic_light.py" --port "$port" &
    local pid=$!
    sleep 2

    if [ -f "$PORT_FILE" ]; then
        local bound_port
        bound_port=$(cat "$PORT_FILE")
        export TRAFFIC_LIGHT_PORT=$bound_port
        export TRAFFIC_LIGHT_PID=$pid
        echo "[SignalLight] 守护进程已启动, HTTP → http://127.0.0.1:$bound_port"
    else
        echo "[SignalLight] 启动失败"
        kill $pid 2>/dev/null
        return 1
    fi
}

# ---- 更新状态 ----
light() {
    local state="${1:-}"
    local port="${TRAFFIC_LIGHT_PORT:-}"

    if [ -z "$port" ]; then
        echo "[light] 未连接守护进程"
        return 1
    fi

    case "$state" in
        running|success|failure|idle)
            curl -s -X POST "http://127.0.0.1:$port/state" \
                -H "Content-Type: application/json" \
                -d "{\"state\":\"$state\",\"session_id\":\"terminal-$$\"" \
                > /dev/null
            echo "[light] → $state"
            ;;
        status|"")
            curl -s "http://127.0.0.1:$port/state"
            echo
            ;;
        *)
            echo "[light] 无效状态: $state"
            return 1
            ;;
    esac
}

# ---- 入口 ----
_traffic_light_daemon "$@"
