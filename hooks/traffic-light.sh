#!/bin/bash
# ============================================================
# CodeBuddy Hook — 更新红绿灯状态（文件系统方案）
export LC_ALL=C.UTF-8
#
# Hook → 状态 映射:
#   SessionStart      → idle       三灯暗色呼吸（agent 就绪）
#   UserPromptSubmit  → thinking   霓虹跑马灯（模型思考中）
#   PostToolUse       → running    黄灯呼吸（工具执行中）
#                      → failure   红灯双闪（工具执行失败，由 stdin 检测）
#   Notification      → waiting    红黄警灯（等待用户确认）
#   Stop              → success    绿灯脉冲（本轮完成，8s 后回 idle）
#   SessionEnd        → end        清除状态文件
#
# 聚合优先级: waiting > failure > thinking > running > success > idle
# 状态 TTL:   thinking 180s / running 90s / waiting 600s / success 8s / failure 30s
#
# 项目隔离: 文件名 <项目名>.state（由 CODEBUDDY_PROJECT_DIR 提取 basename）
# ============================================================

state="${1:-running}"

# PostToolUse 发送 JSON 到 stdin，检测工具执行是否失败
if [ ! -t 0 ] 2>/dev/null; then
    _hook_stdin=$(cat 2>/dev/null)
    if [ -n "$_hook_stdin" ]; then
        _check_script="d:/DevelopTools/mine/traffic-light/hooks/check_failure.py"
        if echo "$_hook_stdin" | /d/software/python/python "$_check_script" 2>/dev/null; then
            state="failure"
        fi
    fi
fi

# 项目路径（CODEBUDDY_PROJECT_DIR 在 hook 环境可用）
project_dir="${CODEBUDDY_PROJECT_DIR:-}"
# 提取项目目录名，作为命名空间（缺少时用 current 兼容旧方案）
if [ -n "$project_dir" ]; then
    project_name="$(basename "$project_dir")"
else
    project_name="current"
fi

# 状态目录：traffic-light/.traffic-light-states/
state_dir="${BASH_SOURCE[0]%/*}/../.traffic-light-states"

case "$state" in
    thinking|running|waiting|success|failure|idle)
        # 目录存在则跳过 mkdir，避免外部进程启动
        [ -d "$state_dir" ] || mkdir -p "$state_dir" 2>/dev/null
        # 格式：第一行状态，第二行项目路径
        # 文件名：<项目名>.state，实现项目级解耦
        printf '%s\n%s\n' "$state" "$project_dir" > "$state_dir/$project_name.state"
        ;;
    end)
        # 会话结束：删除该项目专属状态文件
        rm -f "$state_dir/$project_name.state" 2>/dev/null
        ;;
esac

exit 0
