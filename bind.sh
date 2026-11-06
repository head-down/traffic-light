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

# 查找 pythonw.exe（从 PATH 自动检测而非硬编码路径）
_find_pythonw() {
    powershell -NoProfile -Command "
        \$pythonw = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
        if (\$pythonw) { \$pythonw } else { '' }
    " 2>/dev/null | tr -d '\r'
}
# 解析本会话 CodeBuddy 主进程 PID。
#
# 历史：这里曾用「node.exe + 命令行含 codebuddy + 创建时间最新」猜主进程，
# 已连续三次误判（containment launcher / node-pty agent / 一次性 CLI 子进程）。
# 一次性调用（codebuddy -p "..."）与主进程命令行同构、创建时间更晚，
# 一旦被选中，daemon 会在 10 秒内误判主进程退出而自杀。
#
# 现在只认一个确定性锚点：CODEBUDDY_SERVICE_PROXY_URL 的端口 → 监听该端口的进程。
# 每个窗口一个独立端口，与进程名、创建时间、进程数量都无关。
# 拿不到就返回非 0：宁可不启心跳（灯靠 state TTL 和 SessionEnd 收），
# 也不要一个会误判的心跳。
_get_codebuddy_pid() {
    local port
    port=$(printf '%s' "${CODEBUDDY_SERVICE_PROXY_URL:-}" | sed -n 's#.*:\([0-9][0-9]*\)/.*#\1#p')
    [ -z "$port" ] && return 1

    local pid
    pid=$(MSYS_NO_PATHCONV=1 netstat -ano 2>/dev/null \
        | grep -E "127\.0\.0\.1:${port}[[:space:]]+.*LISTENING" \
        | awk '{print $NF}' | head -1)
    [ -z "$pid" ] && return 1

    echo "$pid"
    return 0
}

# ---- 启动守护进程 ----
_traffic_light_daemon() {
    local pid_file=$(_pid_file)
    local proj=$(_get_project_name)

    # Windows 路径转换（PowerShell 不能解析 /d/... Unix 风格路径）
    local WIN_SCRIPT_DIR="${SCRIPT_DIR:1:1}:${SCRIPT_DIR:2}"
    local WIN_STATE_DIR="${STATE_DIR:1:1}:${STATE_DIR:2}"

    # /clear 防护 + 存活检查：PID 文件存在且进程存活 → 跳过重启
    # （tasklist 判活，避免依赖 powershell；进程死了则清理残留 PID 文件）
    if [ -f "$pid_file" ]; then
        local old_pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$old_pid" ] && MSYS_NO_PATHCONV=1 tasklist /FI "PID eq $old_pid" 2>/dev/null | grep -q "$old_pid"; then
            echo "[SignalLight] daemon already running (PID=$old_pid), skipping restart"
            return 0
        fi
        # 进程已死，清理旧 PID 文件
        rm -f "$pid_file"
    fi

    # 兜底：通过 stop-daemon.ps1 清理同名残留进程（PID 文件丢失的僵尸）
    powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$WIN_SCRIPT_DIR/stop-daemon.ps1" -Project "$proj"
    sleep 1

    # 记录 CodeBuddy 进程 PID，供守护进程检测 CodeBuddy 是否退出
    local cbpid_file=$(_cbpid_file)
    local cb_pid=$(_get_codebuddy_pid)
    if [ -n "$cb_pid" ]; then
        echo "$cb_pid" > "$cbpid_file"
    else
        rm -f "$cbpid_file" 2>/dev/null
    fi

    # 优先使用同目录下的 EXE 发布版，其次回退到 Python 源码
    # 启动方式：schtasks 一次性计划任务（Task Scheduler 服务启动，逃逸
    # CodeBuddy 的 Windows Job Object 进程管控 —— kill-on-close 会在
    # hook/工具任务结束时杀掉整棵子进程树，powershell Start-Process 无法逃逸）
    local task_name="traffic-light-$proj"
    local task_cmd=""
    local exe_path="$WIN_SCRIPT_DIR/traffic_light.exe"
    if [ -f "$SCRIPT_DIR/traffic_light.exe" ]; then
        # EXE 发布版
        task_cmd="'$exe_path' --project $proj"
    else
        # Python 源码版：查找 pythonw.exe 启动
        local pythonw_path=$(_find_pythonw)
        if [ -z "$pythonw_path" ]; then
            echo "[SignalLight] pythonw.exe not found in PATH — install Python first"
            return 1
        fi
        task_cmd="'$pythonw_path' '$WIN_SCRIPT_DIR\\traffic_light.py' --project $proj"
    fi
    MSYS_NO_PATHCONV=1 schtasks /Create /TN "$task_name" /TR "$task_cmd" /SC ONCE /ST 23:59 /F > /dev/null 2>&1
    # 关闭"电池供电时不启动/停止任务"：笔记本用电池时 schtasks 任务会被静默跳过
    # （schtasks CLI 无对应开关，需用 PowerShell 改写任务配置）
    powershell -NoProfile -Command "
        \$t = Get-ScheduledTask -TaskName '$task_name' -ErrorAction SilentlyContinue
        if (\$t) {
            \$t.Settings.DisallowStartIfOnBatteries = \$false
            \$t.Settings.StopIfGoingOnBatteries = \$false
            Set-ScheduledTask -TaskName '$task_name' -Settings \$t.Settings | Out-Null
        }
    " 2>/dev/null
    MSYS_NO_PATHCONV=1 schtasks /Run /TN "$task_name" > /dev/null 2>&1
    sleep 4

    # 读 Python 写入的 PID（os.getpid() 写入，比 bash $! 准确）
    # PID 文件存在 + 进程存活 = 启动成功（防止"启动后被外力杀死"的误报）
    if [ -f "$pid_file" ]; then
        local daemon_pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$daemon_pid" ] && MSYS_NO_PATHCONV=1 tasklist /FI "PID eq $daemon_pid" 2>/dev/null | grep -q "$daemon_pid"; then
            echo "[SignalLight] daemon started $PROJECT_ARG (PID=$daemon_pid)"
            return 0
        fi
        # PID 文件在但进程已死（EXE 崩溃 / 被进程管控杀死）
        echo "[SignalLight] start failed (PID $daemon_pid not alive after launch, check daemon.log)"
        rm -f "$pid_file" 2>/dev/null
        return 1
    fi

    # PID 文件不存在 = daemon 启动失败（EXE 崩溃 / _internal 缺失 / Python 报错）
    echo "[SignalLight] start failed (PID file not created, check daemon.log)"
    rm -f "$pid_file" 2>/dev/null
    return 1
}

# ---- 停止守护进程 ----
_traffic_light_stop() {
    local pid_file=$(_pid_file)
    local proj=$(_get_project_name)
    local WIN_SCRIPT_DIR="${SCRIPT_DIR:1:1}:${SCRIPT_DIR:2}"

    # 方法1：stop-daemon.ps1（最可靠，按项目名匹配进程）
    powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$WIN_SCRIPT_DIR/stop-daemon.ps1" -Project "$proj" 2>/dev/null

    # 方法2：PID 文件兜底
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ]; then
            powershell -NoProfile -ExecutionPolicy Bypass -Command "Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue" 2>/dev/null
        fi
        rm -f "$pid_file"
    fi

    # 方法3：进程名兜底（Python 脚本版残留）
    local cbpid_file=$(_cbpid_file)
    rm -f "$cbpid_file" 2>/dev/null

    # 方法4：清理 schtasks 启动任务（防止残留计划任务）
    MSYS_NO_PATHCONV=1 schtasks /Delete /TN "traffic-light-$proj" /F > /dev/null 2>&1
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
