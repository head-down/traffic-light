#!/bin/bash
# ============================================================
# SignalLight 一键安装脚本
#
# 项目级安装:  bash install.sh <项目路径>
# 全局安装:    bash install.sh --global
#
# 示例:
#   bash install.sh /d/DevelopTools/my-project
#   bash install.sh --global
#
# 智能合并：已有 settings 时只追加 SignalLight hooks，
# 保留用户已有的环境变量、权限、其他 hooks 等配置。
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
    if [ -n "${CODEBUDDY_PROJECT_DIR:-}" ]; then
        TARGET_PROJECT="$CODEBUDDY_PROJECT_DIR"
        echo -e "  检测到 CodeBuddy 项目: ${YELLOW}$TARGET_PROJECT${NC}"
    else
        echo -e "${RED}  用法:${NC}"
        echo    "  项目级安装: bash install.sh <项目路径>"
        echo    "  全局安装:   bash install.sh --global"
        echo ""
        echo "  示例:"
        echo "    bash install.sh /d/DevelopTools/my-project"
        echo "    bash install.sh \$(pwd)  # 安装到当前目录"
        echo "    bash install.sh --global"
        exit 1
    fi
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

# ---- 全局安装 ----
if [ "$GLOBAL_MODE" = true ]; then
    echo "  安装模式: ${YELLOW}全局（所有 CodeBuddy 项目）${NC}"
    echo ""

    echo "  正在合并 hooks 配置到全局 settings.json..."
    echo ""

    RESULT=$(powershell -NoProfile -WindowStyle Hidden -File "$WIN_SCRIPT_DIR/merge-hooks.ps1" \
        -TemplatePath "$TEMPLATE" \
        -SignalLightDir "$WIN_SCRIPT_DIR" \
        -Global 2>&1)
    MERGE_EXIT=$?
else
    # ---- 项目级安装 ----
    TARGET_PROJECT="$(cd "$TARGET_PROJECT" 2>/dev/null && pwd || echo "")"
    if [ -z "$TARGET_PROJECT" ]; then
        echo -e "${RED}错误: 项目目录不存在${NC}"
        exit 1
    fi

    PROJECT_NAME="$(basename "$TARGET_PROJECT")"
    OUTPUT="${TARGET_PROJECT:1:1}:${TARGET_PROJECT:2}\\.codebuddy\\settings.local.json"

    echo "  目标项目: ${YELLOW}$TARGET_PROJECT${NC}"
    echo "  项目标识: ${YELLOW}$PROJECT_NAME${NC}"
    echo ""

    echo "  正在合并 hooks 配置..."
    echo ""

    RESULT=$(powershell -NoProfile -WindowStyle Hidden -File "$WIN_SCRIPT_DIR/merge-hooks.ps1" \
        -TemplatePath "$TEMPLATE" \
        -OutputPath "$OUTPUT" \
        -SignalLightDir "$WIN_SCRIPT_DIR" \
        -ProjectName "$PROJECT_NAME" 2>&1)
    MERGE_EXIT=$?
fi

if [ $MERGE_EXIT -ne 0 ]; then
    echo -e "${RED}错误: hooks 合并失败${NC}"
    echo "$RESULT"
    exit 1
fi

# 解析输出
if echo "$RESULT" | grep -q "SIGNALLIGHT_ALREADY_INSTALLED"; then
    echo -e "${GREEN}  OK${NC} SignalLight 已安装（之前已配置，hooks 已更新）"
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

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         安装完成！                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""

if [ "$GLOBAL_MODE" = true ]; then
    echo "  所有 CodeBuddy 项目打开时，交通灯自动出现"
    echo ""
    echo "  如需卸载:"
    echo "    编辑 ~/.codebuddy/settings.json"
    echo "    删除 hooks 中的 SignalLight 相关配置"
else
    echo "  下一步:"
    echo "    打开项目的 CodeBuddy 终端，灯自动出现"
    echo ""
    echo "  如需为更多项目安装:"
    echo "    bash $SCRIPT_DIR/install.sh <项目路径>"
    echo ""
    echo "  如需全局安装（推荐）:"
    echo "    bash $SCRIPT_DIR/install.sh --global"
fi
echo ""
