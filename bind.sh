#!/bin/bash
# ============================================================
# 信号灯守护进程启动脚本
#
# 用法:
#   source bind.sh [--project <name>]  启动守护进程
#   source bind.sh --project mine      绑定到 mine 项目
#   light <state>                      手动更新状态
#   light status                       查询聚合状态
#
# --project <name>: 只显示指定项目的状态（绑定到项目）
# 不指定时聚合所有项目状态（兼容旧方案）
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="D:/software/python/python"
STATE_DIR="$SCRIPT_DIR/.traffic-light-states"

# 解析 --project 参数
PROJECT_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --project) PROJECT_ARG="--project $2"; shift 2 ;;
        *) shift ;;
    esac
done

# ---- 启动守护进程 ----
_traffic_light_daemon() {
    # 检查是否已有同项目守护进程在运行 (Git Bash 无 pgrep，用 ps + grep)
    local check_pattern="traffic_light.py.*$PROJECT_ARG"
    if [ -n "$PROJECT_ARG" ] && ps -eo pid,args 2>/dev/null | grep -q "$check_pattern"; then
        echo "[SignalLight] 守护进程已在运行 $PROJECT_ARG"
        return 0
    fi
    # 无 project 参数时检查是否有任何 traffic_light 进程
    if [ -z "$PROJECT_ARG" ] && ps -eo pid,args 2>/dev/null | grep -q "traffic_light.py"; then
        echo "[SignalLight] 守护进程已在运行"
        return 0
    fi

    # 启动守护进程
    (cd "$SCRIPT_DIR" && "$PYTHON" traffic_light.py $PROJECT_ARG >/dev/null 2>&1) &
    local pid=$!
    sleep 2

    if ps -eo pid,args 2>/dev/null | grep -q "traffic_light.py"; then
        if [ -n "$PROJECT_ARG" ]; then
            echo "[SignalLight] 守护进程已启动 $PROJECT_ARG"
        else
            echo "[SignalLight] 守护进程已启动 (文件轮询模式)"
        fi
    else
        echo "[SignalLight] 启动失败"
        kill $pid 2>/dev/null
        return 1
    fi
}

# ---- 更新状态（写状态文件） ----
light() {
    local state="${1:-}"
    # 用 CODEBUDDY_PROJECT_DIR 或当前目录名作为项目名
    local project_name="${CODEBUDDY_PROJECT_DIR##*/}"
    [ -z "$project_name" ] && project_name="current"

    case "$state" in
        thinking|running|waiting|success|failure|idle)
            [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null
            printf '%s\n%s\n' "$state" "${CODEBUDDY_PROJECT_DIR:-}" > "$STATE_DIR/$project_name.state"
            echo "[light] → $state ($project_name)"
            ;;
        status|"")
            # 读取所有状态文件
            if [ -d "$STATE_DIR" ]; then
                echo "Active sessions:"
                for f in "$STATE_DIR"/*.state; do
                    [ -f "$f" ] || continue
                    local sid state_val
                    sid="$(basename "$f" .state)"
                    state_val="$(head -1 "$f" 2>/dev/null)"
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
