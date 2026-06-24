#!/bin/bash
# ============================================================
# 信号灯守护进程启动脚本
# ============================================================
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="D:/software/python/python"
STATE_DIR="$SCRIPT_DIR/.traffic-light-states"

# 解析参数
PROJECT_ARG=""
ACTION="daemon"
while [ $# -gt 0 ]; do
    case "$1" in
        --project) PROJECT_ARG="--project $2"; shift 2 ;;
        stop) ACTION="stop"; shift ;;
        *) shift ;;
    esac
done

# ---- 工具函数 ----
_get_project_name() {
    local proj
    for word in $PROJECT_ARG; do
        [ "$word" = "--project" ] && continue
        proj="$word"
    done
    echo "${proj:-all}"
}

_pid_file() {
    local proj=$(_get_project_name)
    echo "$STATE_DIR/$proj.pid"
}

_cbpid_file() {
    local proj=$(_get_project_name)
    echo "$STATE_DIR/$proj.cbpid"
}

# 获取 CodeBuddy 进程 PID（查找命令行匹配 codebuddy 的 node.exe 进程）
# 用于守护进程检测 CodeBuddy 是否退出（Ctrl+C 时 SessionEnd hook 不触发）
_get_codebuddy_pid() {
    powershell -NoProfile -Command "
        Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" |
        Where-Object { \$_.CommandLine -match 'codebuddy' } |
        Select-Object -First 1 -ExpandProperty ProcessId
    " 2>/dev/null | tr -d '\r\n '
}

# ---- 启动守护进程 ----
_traffic_light_daemon() {
    local pid_file=$(_pid_file)

    # 先杀掉旧实例
    if [ -f "$pid_file" ]; then
        local old_pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            kill "$old_pid" 2>/dev/null
            sleep 1
        fi
        rm -f "$pid_file"
    fi
    local proj=$(_get_project_name)
    powershell -NoProfile -Command "Get-Process -Name python* -ErrorAction SilentlyContinue | Where-Object { try { (Get-CimInstance Win32_Process -Filter \"ProcessId = \$($_.Id)\").CommandLine -match 'traffic_light.*--project $proj' } catch { \$false } } | Stop-Process -Force -ErrorAction SilentlyContinue" 2>/dev/null
    sleep 1

    # 记录 CodeBuddy 进程 PID，供守护进程检测 CodeBuddy 是否退出
    local cbpid_file=$(_cbpid_file)
    local cb_pid=$(_get_codebuddy_pid)
    if [ -n "$cb_pid" ]; then
        echo "$cb_pid" > "$cbpid_file"
    else
        rm -f "$cbpid_file" 2>/dev/null
    fi

    # 启动守护进程（需要 cd 到脚本目录，依赖相对导入）
    (cd "$SCRIPT_DIR" && "$PYTHON" traffic_light.py $PROJECT_ARG </dev/null >/dev/null 2>&1) &
    local bg_pid=$!
    sleep 4

    # 读 Python 写入的 PID（os.getpid() 写入，比 bash $! 准确）
    if [ -f "$pid_file" ]; then
        local daemon_pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
            echo "[SignalLight] daemon started $PROJECT_ARG (PID=$daemon_pid)"
            return 0
        fi
    fi

    # 回退：PID 文件未就绪但 bash 子进程尚存（pyqt 启动慢）
    if kill -0 "$bg_pid" 2>/dev/null; then
        echo "[SignalLight] daemon started $PROJECT_ARG (PID=$bg_pid)"
        return 0
    fi

    echo "[SignalLight] start failed"
    rm -f "$pid_file" 2>/dev/null
    return 1
}

# ---- 停止守护进程 ----
_traffic_light_stop() {
    local pid_file=$(_pid_file)

    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill "$pid" 2>/dev/null; then
            echo "[SignalLight] daemon stopped (PID=$pid) $PROJECT_ARG"
        fi
        rm -f "$pid_file"
    else
        # Fallback: ps on Git Bash doesn't show args, use PowerShell
        local proj=$(_get_project_name)
        powershell -NoProfile -Command "Get-Process -Name python* -ErrorAction SilentlyContinue | Where-Object { try { (Get-CimInstance Win32_Process -Filter \"ProcessId = \$($_.Id)\").CommandLine -match 'traffic_light.*--project $proj' } catch { \$false } } | ForEach-Object { Write-Host \"killed PID=\$($_.Id)\"; Stop-Process -Id \$($_.Id) -Force }" 2>/dev/null || echo "[SignalLight] no daemon found for $PROJECT_ARG"
    fi
}

# ---- 更新状态 ----
light() {
    local state="${1:-}"
    local project_name="${CODEBUDDY_PROJECT_DIR##*/}"
    [ -z "$project_name" ] && project_name="current"

    case "$state" in
        thinking|running|waiting|success|failure|idle)
            [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null
            printf '%s\n%s\n' "$state" "${CODEBUDDY_PROJECT_DIR:-}" > "$STATE_DIR/$project_name.state"
            echo "[light] -> $state ($project_name)"
            ;;
        status|"")
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
                echo "[light] no active sessions"
            fi
            ;;
        *)
            echo "[light] invalid state: $state"
            return 1
            ;;
    esac
}

# ---- 入口 ----
case "$ACTION" in
    stop) _traffic_light_stop ;;
    *)    _traffic_light_daemon ;;
esac
