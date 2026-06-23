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
STATE_DIR="$SCRIPT_DIR/.traffic-light-states"

# ---- 启动守护进程 ----
_traffic_light_daemon() {
    # 检查是否已运行（用 tasklist 查 python 进程）
    if pgrep -f "traffic_light.py" >/dev/null 2>&1; then
        echo "[SignalLight] 守护进程已在运行"
        return 0
    fi

    # 启动守护进程（文件轮询模式，无 HTTP）
    (cd "$SCRIPT_DIR" && "$PYTHON" traffic_light.py >/dev/null 2>&1) &
    local pid=$!
    sleep 2

    if pgrep -f "traffic_light.py" >/dev/null 2>&1; then
        echo "[SignalLight] 守护进程已启动 (文件轮询模式)"
    else
        echo "[SignalLight] 启动失败"
        kill $pid 2>/dev/null
        return 1
    fi
}

# ---- 更新状态（写状态文件） ----
light() {
    local state="${1:-}"
    local session_id="terminal-$$"

    case "$state" in
        running|success|failure|idle)
            [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null
            echo "$state" > "$STATE_DIR/$session_id.state"
            echo "[light] → $state"
            ;;
        status|"")
            # 读取所有状态文件
            if [ -d "$STATE_DIR" ]; then
                echo "Active sessions:"
                for f in "$STATE_DIR"/*.state; do
                    [ -f "$f" ] || continue
                    local sid state_val
                    sid="$(basename "$f" .state)"
                    state_val="$(cat "$f" 2>/dev/null)"
                    echo "  $sid: $state_val"
                done
            else
                echo "[light] 无活动会话"
            fi
            ;;
        *)
            echo "[light] 无效状态: $state"
            return 1
            ;;
    esac
}

# ---- 入口 ----
_traffic_light_daemon "$@"
