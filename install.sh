#!/bin/bash
# ============================================================
# SignalLight 一键安装脚本
# 用法: bash install.sh <你的CodeBuddy项目路径>
#
# 示例:
#   bash install.sh /d/DevelopTools/my-project
#
# 智能合并：已有 settings.local.json 时只追加 SignalLight hooks，
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
TARGET_PROJECT=""
if [ $# -ge 1 ]; then
    TARGET_PROJECT="$1"
else
    if [ -n "${CODEBUDDY_PROJECT_DIR:-}" ]; then
        TARGET_PROJECT="$CODEBUDDY_PROJECT_DIR"
        echo -e "  检测到 CodeBuddy 项目: ${YELLOW}$TARGET_PROJECT${NC}"
    else
        echo -e "${RED}  用法: bash install.sh <项目路径>${NC}"
        echo ""
        echo "  示例:"
        echo "    bash install.sh /d/DevelopTools/my-project"
        echo "    bash install.sh \\$(pwd)  # 安装到当前目录"
        exit 1
    fi
fi

TARGET_PROJECT="$(cd "$TARGET_PROJECT" 2>/dev/null && pwd || echo "")"
if [ -z "$TARGET_PROJECT" ]; then
    echo -e "${RED}错误: 项目目录不存在${NC}"
    exit 1
fi

# ---- 获取当前脚本目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="$(basename "$TARGET_PROJECT")"

echo "  安装目录: ${YELLOW}$SCRIPT_DIR${NC}"
echo "  目标项目: ${YELLOW}$TARGET_PROJECT${NC}"
echo "  项目标识: ${YELLOW}$PROJECT_NAME${NC}"
echo ""

# ---- 检查必要文件 ----
if [ ! -f "$SCRIPT_DIR/traffic_light.exe" ] && [ ! -f "$SCRIPT_DIR/traffic_light.py" ]; then
    echo -e "${RED}错误: 找不到 traffic_light.exe 或 traffic_light.py${NC}"
    echo "  请确保在 SignalLight 目录下运行此脚本"
    exit 1
fi

# ---- PowerShell 路径转换 ----
WIN_SCRIPT_DIR="${SCRIPT_DIR:1:1}:${SCRIPT_DIR:2}"
TEMPLATE="$WIN_SCRIPT_DIR/.codebuddy-hooks.json"
OUTPUT="${TARGET_PROJECT:1:1}:${TARGET_PROJECT:2}\\.codebuddy\\settings.local.json"

# ---- 调用 merge-hooks.ps1 智能合并 ----
echo "  正在合并 hooks 配置..."
echo ""

RESULT=$(powershell -NoProfile -WindowStyle Hidden -File "$WIN_SCRIPT_DIR/merge-hooks.ps1" \
    -TemplatePath "$TEMPLATE" \
    -OutputPath "$OUTPUT" \
    -SignalLightDir "$WIN_SCRIPT_DIR" \
    -ProjectName "$PROJECT_NAME" 2>&1)
MERGE_EXIT=$?

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
echo "  下一步:"
echo "    打开项目的 CodeBuddy 终端，灯自动出现"
echo ""
echo "  如需为更多项目安装:"
echo "    bash $SCRIPT_DIR/install.sh <项目路径>"
echo ""
