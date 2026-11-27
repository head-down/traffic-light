#!/bin/bash
# ============================================================
# CodeBuddy Hook — 一窗一灯 · 按会话 pid 写状态
#
#   hooks/traffic-light.sh <event>
#   event ∈ session-start | prompt | tool | notify | stop | end
#
# 事件 → 状态:
#   session-start → idle      解析会话进程/窗口（写绑定、抢窗、拉灯、GC）
#   prompt        → thinking  绑定 TTL 过期或灯锚失效时自愈重解析
#   tool          → running   检测到工具失败 → failure；绝不启动解析器
#   notify        → waiting   只写状态
#   stop          → success   当前为 idle 时忽略（保留 /clear 防抖）
#   end           → ended     不删文件、不杀灯
#
# 状态文件: <状态目录>/<pid>.state，三行 = state / cwd / creation_ft
# 绑定文件: <状态目录>/<session_id>.bind，每个事件只读一次
# 所有 ps1 调用统一 -NoProfile -ExecutionPolicy Bypass
#
# 可覆盖（测试注入用）:
#   TRAFFIC_LIGHT_STATE_DIR    状态目录
#   TRAFFIC_LIGHT_RESOLVE      resolve.ps1 路径
#   TRAFFIC_LIGHT_POWERSHELL   powershell 可执行文件（默认 PATH 里的 powershell）
# ============================================================
export LC_ALL=C.UTF-8

event="${1:-}"
case "$event" in
    session-start|prompt|tool|notify|stop|end) ;;
    *) exit 0 ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_dir="${TRAFFIC_LIGHT_STATE_DIR:-$script_dir/../.traffic-light-states}"
resolve_ps1="${TRAFFIC_LIGHT_RESOLVE:-$script_dir/../resolve.ps1}"
ps_bin="${TRAFFIC_LIGHT_POWERSHELL:-powershell}"

BIND_TTL_SECONDS=60
ANCHOR_STALE_SECONDS=10

# ---- stdin 只读一次 ---------------------------------------------------------

hook_stdin=""
if [ ! -t 0 ] 2>/dev/null; then
    hook_stdin="$(cat 2>/dev/null)"
fi

# 从 JSON 里取第一个字符串字段（不引 Python，避免控制台闪烁）
_json_str() {
    printf '%s' "$hook_stdin" \
        | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null \
        | head -1 \
        | sed -E 's/.*:[[:space:]]*"(.*)"$/\1/'
}

# 从 payload 里截出某个 key 对应的 JSON 对象（含花括号）。高频事件不能起
# python/jq，所以用一个手写扫描：只认字符串边界与花括号深度。
_json_object_after() {
    printf '%s' "$hook_stdin" | awk -v key="\"$1\"" '
        { text = text $0 "\n" }
        END {
            i = index(text, key)
            if (i == 0) exit 1
            i += length(key)
            while (i <= length(text) && substr(text, i, 1) ~ /[[:space:]:]/) i++
            if (substr(text, i, 1) != "{") exit 1
            start = i; depth = 0; quoted = 0; escaped = 0
            for (; i <= length(text); i++) {
                c = substr(text, i, 1)
                if (quoted) {
                    if (escaped) escaped = 0
                    else if (c == "\\") escaped = 1
                    else if (c == "\"") quoted = 0
                    continue
                }
                if (c == "\"") { quoted = 1; continue }
                if (c == "{") depth++
                else if (c == "}") {
                    depth--
                    if (depth == 0) { print substr(text, start, i - start + 1); exit 0 }
                }
            }
            exit 1
        }'
}

# 一次工具调用是否失败（0 = 失败）。规则只看 tool_response 对象内部，且 key
# 必须落在成员位置：工具刚读过一份含 "error": 的文件时，那段文字会以转义
# 形式出现在字符串里，不能当成失败。
_classify_tool_failure() {
    local body tool
    body="$(_json_object_after tool_response)" || return 1
    printf '%s' "$body" | grep -q '[{,][[:space:]]*"success"[[:space:]]*:[[:space:]]*false' && return 0
    printf '%s' "$body" | grep -q '[{,][[:space:]]*"error"[[:space:]]*:' && return 0
    tool="$(_json_str tool_name)"
    if [ "$tool" = "Bash" ] && printf '%s' "$body" | grep -q '[{,][[:space:]]*"exitCode"[[:space:]]*:[[:space:]]*[1-9]'; then
        return 0
    fi
    return 1
}

session_id="$(_json_str session_id)"
[ -z "$session_id" ] && session_id="${CODEBUDDY_SESSION_ID:-}"
[ -z "$session_id" ] && exit 0
# session_id is part of a filename: anything outside [A-Za-z0-9._-] could
# escape the state directory, so it is silently dropped
case "$session_id" in
    *[!A-Za-z0-9._-]*) exit 0 ;;
esac

payload_cwd="$(_json_str cwd)"
[ -z "$payload_cwd" ] && payload_cwd="${CODEBUDDY_PROJECT_DIR:-$PWD}"

bind_file="$state_dir/$session_id.bind"

# ---- 路径与绑定 -------------------------------------------------------------

# PowerShell 不认 /d/... 的 MSYS 路径，转成 D:/...
_win_path() {
    case "$1" in
        /?/*) printf '%s:/%s\n' "$(printf '%s' "${1:1:1}" | tr '[:lower:]' '[:upper:]')" "${1:3}" ;;
        *)    printf '%s\n' "$1" ;;
    esac
}

bind_pid=""
bind_ft=""
bind_hwnd=""
bind_cwd=""
bind_updated=""
bind_degraded=""

# 每个事件只读一次绑定文件，字段进内存
_read_bind() {
    bind_pid=""; bind_ft=""; bind_hwnd=""; bind_cwd=""; bind_updated=""; bind_degraded=""
    [ -f "$bind_file" ] || return 1
    local key value
    while IFS='=' read -r key value; do
        value="${value%$'\r'}"
        case "$key" in
            pid)         bind_pid="$value" ;;
            creation_ft) bind_ft="$value" ;;
            hwnd)        bind_hwnd="$value" ;;
            cwd)         bind_cwd="$value" ;;
            updated)     bind_updated="$value" ;;
            degraded)    bind_degraded="$value" ;;
        esac
    done < "$bind_file"
    return 0
}

# pid 必须可用（身份层键），否则静默退出，不猜
_bind_usable() {
    case "$bind_pid" in
        ''|0|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

_bind_expired() {
    case "$bind_updated" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ $(( $(date +%s) - bind_updated )) -gt $BIND_TTL_SECONDS ]
}

# 锚不存在或超过 10s 未刷新 → 灯丢了，需要重新解析归窗
_anchor_stale() {
    case "$bind_hwnd" in
        ''|0|*[!0-9]*) return 0 ;;
    esac
    local anchor="$state_dir/w$bind_hwnd.win"
    [ -f "$anchor" ] || return 0
    local mtime
    mtime="$(stat -c %Y "$anchor" 2>/dev/null)" || return 0
    [ $(( $(date +%s) - mtime )) -gt $ANCHOR_STALE_SECONDS ]
}

# 从 bash 直接拉 powershell 会让它新建一个控制台（Windows Terminal 闪黑框），
# 有 pythonw 时经 run-hidden.pyw --exec 启动，走 CREATE_NO_WINDOW。
_hidden_exec() {
    # 注入的桩（测试）要按原样执行，只有真实 powershell 才需要无窗口宿主
    if [ "$ps_bin" = "powershell" ] && command -v pythonw >/dev/null 2>&1 && [ -f "$script_dir/run-hidden.pyw" ]; then
        pythonw "$script_dir/run-hidden.pyw" --exec "$@"
    else
        "$@"
    fi
}

_run_resolve() {
    # GC 只在安装与 SessionStart 跑；prompt 的 TTL/锚自愈重解析不得扫别人的状态目录
    local extra=()
    [ "$event" = "prompt" ] && extra+=("-NoGc")
    _hidden_exec "$ps_bin" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden \
        -File "$(_win_path "$resolve_ps1")" \
        -SessionId "$session_id" \
        -Cwd "$(_win_path "$payload_cwd")" \
        -StateDir "$(_win_path "$state_dir")" \
        ${extra[@]+"${extra[@]}"} \
        >/dev/null 2>&1
}

# ---- 决定是否需要重跑解析器（只在 session-start / prompt） -----------------

need_resolve=0
if [ "$event" = "session-start" ]; then
    need_resolve=1
elif _read_bind && _bind_usable; then
    if [ "$event" = "prompt" ]; then
        if _bind_expired || [ "$bind_degraded" = "1" ] || _anchor_stale; then
            need_resolve=1
        fi
    fi
else
    # 无绑定：只有 prompt 值得重试归窗，tool/notify/stop/end 静默
    [ "$event" = "prompt" ] || exit 0
    need_resolve=1
fi

if [ "$need_resolve" = "1" ]; then
    _run_resolve
    _read_bind && _bind_usable || exit 0
fi

bind_cwd="${bind_cwd:-$payload_cwd}"

# ---- 事件 → 状态 ------------------------------------------------------------

case "$event" in
    session-start) state="idle" ;;
    prompt)        state="thinking" ;;
    tool)          state="running" ;;
    notify)        state="waiting" ;;
    stop)          state="success" ;;
    end)           state="ended" ;;
esac

if [ "$event" = "tool" ] && [ -n "$hook_stdin" ]; then
    if _classify_tool_failure; then
        state="failure"
    fi
fi

# ---- 写 <pid>.state ---------------------------------------------------------

state_file="$state_dir/$bind_pid.state"

# /clear 防抖：新会话已写 idle，旧轮迟到的 success 不覆盖
if [ "$event" = "stop" ] && [ -f "$state_file" ]; then
    if [ "$(head -1 "$state_file" 2>/dev/null | tr -d '\r')" = "idle" ]; then
        exit 0
    fi
fi

[ -d "$state_dir" ] || mkdir -p "$state_dir" 2>/dev/null || exit 0

tmp_file="$state_file.tmp.$$"
if printf '%s\n%s\n%s\n' "$state" "$bind_cwd" "$bind_ft" > "$tmp_file" 2>/dev/null; then
    mv -f "$tmp_file" "$state_file" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null
else
    rm -f "$tmp_file" 2>/dev/null
fi

exit 0
