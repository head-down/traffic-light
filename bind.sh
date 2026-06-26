#!/bin/bash
# ============================================================
# 信号灯守护进程启动脚本
# ============================================================
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# 获取 CodeBuddy 进程 PID（纯 bash，无 python.exe 调用）
# PowerShell 过滤 node.exe 命令行含 codebuddy，排除已声明的 PID
_get_codebuddy_pid() {
    local proj=$(_get_project_name)

    # PowerShell 获取所有 CodeBuddy node.exe PID（降序）
    local cb_pids=$(powershell -NoProfile -WindowStyle Hidden -Command "
        Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" |
        Where-Object { \$_.CommandLine -match 'codebuddy' } |
        Sort-Object -Property ProcessId -Descending |
        ForEach-Object { Write-Output \$_.ProcessId }
    " 2>/dev/null | tr -d '\r')
    [ -z "$cb_pids" ] && return 1

    # 读取已声明 PID（排除自己项目）
    local claimed=""
    for f in "$STATE_DIR"/*.cbpid; do
        [ "$f" = "$(_cbpid_file)" ] && continue
        local p=$(cat "$f" 2>/dev/null | tr -d '\r\n')
        [ -n "$p" ] && claimed="$claimed $p"
    done

    # 选第一个未声明 PID
    for pid in $cb_pids; do
        local is_claimed=0
        for c in $claimed; do
            [ "$c" = "$pid" ] && { is_claimed=1; break; }
        done
        [ $is_claimed -eq 0 ] && { echo "$pid"; return 0; }
    done
    return 1
}

# ---- 启动守护进程 ----
_traffic_light_daemon() {
    local pid_file=$(_pid_file)

    # 先杀掉旧实例
    # kill -0 在 Git Bash/Windows 上不可靠，直接用 PowerShell 清理旧进程
    if [ -f "$pid_file" ]; then
        rm -f "$pid_file"
    fi
    local proj=$(_get_project_name)
    powershell -NoProfile -WindowStyle Hidden -Command "Get-Process -Name python* -ErrorAction SilentlyContinue | Where-Object { try { (Get-CimInstance Win32_Process -Filter \"ProcessId = \$($_.Id)\").CommandLine -match 'traffic_light.*--project $proj' } catch { \$false } } | Stop-Process -Force -ErrorAction SilentlyContinue" 2>/dev/null
    sleep 1

    # 记录 CodeBuddy 进程 PID，供守护进程检测 CodeBuddy 是否退出
    local cbpid_file=$(_cbpid_file)
    local cb_pid=$(_get_codebuddy_pid)
    if [ -n "$cb_pid" ]; then
        echo "$cb_pid" > "$cbpid_file"
    else
        rm -f "$cbpid_file" 2>/dev/null
    fi

    # 启动守护进程
    # PowerShell Start-Process + pythonw.exe，-WindowStyle Hidden 彻底消除黑窗
    local WIN_SCRIPT_DIR="${SCRIPT_DIR:1:1}:${SCRIPT_DIR:2}"
    local WIN_STATE_DIR="${STATE_DIR:1:1}:${STATE_DIR:2}"
    powershell -NoProfile -WindowStyle Hidden -Command "Start-Process -FilePath 'D:\\software\\python\\pythonw.exe' -ArgumentList 'traffic_light.py','--project','$proj' -WorkingDirectory '$WIN_SCRIPT_DIR' -WindowStyle Hidden -RedirectStandardOutput '$WIN_STATE_DIR\\daemon.log'" &
    local bg_pid=$!
    sleep 4

    # 读 Python 写入的 PID（os.getpid() 写入，比 bash $! 准确）
    # PID 文件存在 = 守护进程已启动（main() 在进 Qt 事件循环前写入）
    if [ -f "$pid_file" ]; then
        local daemon_pid=$(cat "$pid_file" 2>/dev/null)
        echo "[SignalLight] daemon started $PROJECT_ARG (PID=$daemon_pid)"
        return 0
    fi

    # 回退：kill -0 不可靠，只检查 bg_pid 是否存在
    if [ -n "$bg_pid" ]; then
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
        powershell -NoProfile -WindowStyle Hidden -Command "Get-Process -Name python* -ErrorAction SilentlyContinue | Where-Object { try { (Get-CimInstance Win32_Process -Filter \"ProcessId = \$($_.Id)\").CommandLine -match 'traffic_light.*--project $proj' } catch { \$false } } | ForEach-Object { Write-Host \"killed PID=\$($_.Id)\"; Stop-Process -Id \$($_.Id) -Force }" 2>/dev/null || echo "[SignalLight] no daemon found for $PROJECT_ARG"
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
