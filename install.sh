#!/bin/bash
# ============================================================
# SignalLight 一键安装脚本
#
# 全局安装:    bash install.sh --global
# 项目级安装:  bash install.sh <项目路径>
#
# 安装 = 把 hooks 合并进 settings + 跑一次 GC 清掉旧格式资产。
# 一窗一灯按会话 pid / 窗口 hwnd 做键，不再有项目级键：
# 重复安装只会更新 hooks，不会新增第二个任务或第二盏灯。
# ============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       SignalLight 一键安装程序          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# ---- 获取参数 ----
GLOBAL_MODE=false
TARGET_PROJECT=""

if [ $# -ge 1 ]; then
    if [ "$1" = "--global" ]; then
        GLOBAL_MODE=true
    else
        TARGET_PROJECT="$1"
    fi
fi

if [ "$GLOBAL_MODE" = false ] && [ -z "$TARGET_PROJECT" ]; then
    echo -e "${RED}  用法:${NC}"
    echo    "  全局安装:   bash install.sh --global"
    echo    "  项目级安装: bash install.sh <项目路径>"
    echo ""
    echo "  示例:"
    echo "    bash install.sh --global"
    echo "    bash install.sh /d/DevelopTools/my-project"
    echo "    bash install.sh \$(pwd)"
    exit 1
fi

# ---- 获取当前脚本目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIN_SCRIPT_DIR="${SCRIPT_DIR:1:1}:${SCRIPT_DIR:2}"

# ---- 检查必要文件 ----
if [ ! -f "$SCRIPT_DIR/traffic_light.exe" ] && [ ! -f "$SCRIPT_DIR/traffic_light.py" ]; then
    echo -e "${RED}错误: 找不到 traffic_light.exe 或 traffic_light.py${NC}"
    echo "  请确保在 SignalLight 目录下运行此脚本"
    exit 1
fi

TEMPLATE="$WIN_SCRIPT_DIR/.codebuddy-hooks.json"
echo "  安装目录: ${YELLOW}$SCRIPT_DIR${NC}"

# ---- 合并 hooks ----
if [ "$GLOBAL_MODE" = true ]; then
    echo "  安装模式: ${YELLOW}全局（所有 CodeBuddy 项目）${NC}"
    echo ""
    echo "  正在合并 hooks 配置到全局 settings.json..."
    echo ""

    if RESULT=$(powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$WIN_SCRIPT_DIR/merge-hooks.ps1" \
        -TemplatePath "$TEMPLATE" \
        -SignalLightDir "$WIN_SCRIPT_DIR" \
        -Global 2>&1); then
        MERGE_EXIT=0
    else
        MERGE_EXIT=$?
    fi
else
    TARGET_PROJECT="$(cd "$TARGET_PROJECT" 2>/dev/null && pwd || echo "")"
    if [ -z "$TARGET_PROJECT" ]; then
        echo -e "${RED}错误: 项目目录不存在${NC}"
        exit 1
    fi

    OUTPUT="${TARGET_PROJECT:1:1}:${TARGET_PROJECT:2}\\.codebuddy\\settings.local.json"

    echo "  目标项目: ${YELLOW}$TARGET_PROJECT${NC}"
    echo ""
    echo "  正在合并 hooks 配置..."
    echo ""

    if RESULT=$(powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$WIN_SCRIPT_DIR/merge-hooks.ps1" \
        -TemplatePath "$TEMPLATE" \
        -OutputPath "$OUTPUT" \
        -SignalLightDir "$WIN_SCRIPT_DIR" 2>&1); then
        MERGE_EXIT=0
    else
        MERGE_EXIT=$?
    fi
fi

if [ $MERGE_EXIT -ne 0 ]; then
    echo -e "${RED}错误: hooks 合并失败${NC}"
    echo "$RESULT"
    exit 1
fi

# 解析输出
if echo "$RESULT" | grep -q "SIGNALLIGHT_ALREADY_INSTALLED"; then
    echo -e "${GREEN}  OK${NC} SignalLight 已安装（hooks 已是最新）"
elif echo "$RESULT" | grep -q "SIGNALLIGHT_INSTALLED"; then
    echo "$RESULT" | grep -E "^  " | while read -r line; do
        case "$line" in
            *"+"*) echo -e "  ${GREEN}+${NC}${line#*+}" ;;
            *"~"*) echo -e "  ${YELLOW}~${NC}${line#*~}" ;;
        esac
    done
else
    echo -e "${YELLOW}  !${NC} 解析安装结果失败"
fi

# ---- 一次性 GC：清掉旧格式任务 / 状态文件 / 孤儿锚，幂等 ----
echo ""
echo "  正在清理旧版本资产（计划任务 / .state / .pid / 孤儿锚）..."
if GC_RESULT=$(powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$WIN_SCRIPT_DIR/resolve.ps1" -GcOnly 2>&1); then
    if [ -n "$GC_RESULT" ]; then
        echo "$GC_RESULT" | sed 's/^/  /'
    else
        echo "  没有需要清理的旧资产"
    fi
else
    echo -e "${YELLOW}  !${NC} GC 失败（不影响本次安装），下次 SessionStart 会重试"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         安装完成！                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""

if [ "$GLOBAL_MODE" = true ]; then
    echo "  所有 CodeBuddy 项目打开时，每个终端窗口自动出现自己的灯"
    echo ""
    echo "  如需卸载:"
    echo "    编辑 ~/.codebuddy/settings.json"
    echo "    删除 hooks 中的 SignalLight 相关配置"
else
    echo "  下一步:"
    echo "    打开该项目的 CodeBuddy 终端，灯自动出现"
    echo ""
    echo "  如需全局安装（推荐）:"
    echo "    bash $SCRIPT_DIR/install.sh --global"
fi
echo ""
