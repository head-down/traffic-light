#!/bin/bash
# ============================================================
# CodeBuddy Hook — 更新红绿灯状态（文件系统方案，零进程启动）
#
# 用法（由 CodeBuddy 自动调用）:
#   hooks/traffic-light.sh <state>
#
# 用 bash 内置 echo > 写状态文件，不启动 curl 等外部进程。
# 守护进程 QTimer 300ms 轮询扫描状态目录，按 TTL 聚合显示。
#
# 说明：CodeBuddy hook 环境不传递 CODEBUDDY_SESSION_ID，
#       且 $$ 每次不同、$PPID 恒为 1，无法区分会话。
#       故采用单文件方案：所有 hook 写 current.state，
#       靠 mtime + TTL 判断状态新鲜度。
# ============================================================

state="${1:-running}"

# 项目路径（CODEBUDDY_PROJECT_DIR 在 hook 环境可用）
project_dir="${CODEBUDDY_PROJECT_DIR:-}"

# 状态目录：traffic-light/.traffic-light-states/
state_dir="${BASH_SOURCE[0]%/*}/../.traffic-light-states"

case "$state" in
    thinking|running|waiting|success|failure|idle)
        # 目录存在则跳过 mkdir，避免外部进程启动
        [ -d "$state_dir" ] || mkdir -p "$state_dir" 2>/dev/null
        # 格式：第一行状态，第二行项目路径
        printf '%s\n%s\n' "$state" "$project_dir" > "$state_dir/current.state"
        ;;
    end)
        # 会话结束：删除状态文件
        rm -f "$state_dir/current.state" 2>/dev/null
        ;;
esac

exit 0
