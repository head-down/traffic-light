#!/bin/bash
# ============================================================
# SignalLight 一键安装脚本
# 用法: bash install.sh <你的CodeBuddy项目路径>
#
# 示例:
#   bash install.sh /d/DevelopTools/my-project
#
# 脚本会自动:
#   1. 提取项目名作为标识
#   2. 复制 hooks 配置到项目的 .codebuddy/settings.local.json
#   3. 替换 TRAFFIC_LIGHT_DIR 为当前目录路径
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
    # 尝试自动检测：当前 CodeBuddy 项目
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

# 规范化路径
TARGET_PROJECT="$(cd "$TARGET_PROJECT" 2>/dev/null && pwd || echo "")"
if [ -z "$TARGET_PROJECT" ]; then
    echo -e "${RED}错误: 项目目录不存在${NC}"
    exit 1
fi

# ---- 获取当前脚本目录（SignalLight 安装目录） ----
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

if [ ! -f "$SCRIPT_DIR/.codebuddy-hooks.json" ]; then
    echo -e "${RED}错误: 找不到 .codebuddy-hooks.json 模板文件${NC}"
    exit 1
fi

# ---- 创建 .codebuddy 目录 ----
HOOKS_DIR="$TARGET_PROJECT/.codebuddy"
if [ ! -d "$HOOKS_DIR" ]; then
    mkdir -p "$HOOKS_DIR"
    echo -e "  ${GREEN}+${NC} 创建 $HOOKS_DIR"
fi

# ---- Windows 路径：转为 Git Bash 可用的 Unix 格式 ----
WIN_PATH="${SCRIPT_DIR:1:1}:${SCRIPT_DIR:2}"
WIN_PATH="${WIN_PATH//\//\\\\}"  # 转义反斜杠用于 JSON

# ---- 生成 settings.local.json ----
OUTPUT_FILE="$HOOKS_DIR/settings.local.json"

if [ -f "$OUTPUT_FILE" ]; then
    echo -e "  ${YELLOW}!${NC} $OUTPUT_FILE 已存在"
    echo ""
    read -p "  是否覆盖? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}  已跳过。如需重新安装请删除该文件后重试。${NC}"
        exit 0
    fi
    # 备份旧文件
    cp "$OUTPUT_FILE" "$OUTPUT_FILE.bak"
    echo -e "  ${YELLOW}  已备份旧文件到 $OUTPUT_FILE.bak${NC}"
fi

# 使用 sed 替换占位符
# TRAFFIC_LIGHT_DIR -> SignalLight 目录的 Unix 路径（用于 bash 调用）
UNIX_PATH="${SCRIPT_DIR}"
# <YOUR_PROJECT> -> 项目目录名
sed -e "s|TRAFFIC_LIGHT_DIR|$UNIX_PATH|g" \
    -e "s|<YOUR_PROJECT>|$PROJECT_NAME|g" \
    "$SCRIPT_DIR/.codebuddy-hooks.json" > "$OUTPUT_FILE"

echo -e "  ${GREEN}+${NC} 写入 $OUTPUT_FILE"
echo ""

# ---- 检查 bash 是否可用 ----
if command -v bash &> /dev/null; then
    echo -e "  ${GREEN}OK${NC} bash 可用"
else
    echo -e "  ${RED}注意:${NC} 未检测到 bash，CodeBuddy hooks 需要 Git Bash"
    echo "        请安装 Git for Windows: https://git-scm.com"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         安装完成！                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "  下一步:"
echo ""
echo "  1. 打开项目的 CodeBuddy 终端"
echo "     cd $TARGET_PROJECT"
echo ""
echo "  2. 或者重启 CodeBuddy，灯会自动出现"
echo ""
echo "  如需为更多项目安装，重复运行:"
echo "    bash $SCRIPT_DIR/install.sh <项目路径>"
echo ""
