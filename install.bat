@echo off
:: ============================================================
:: SignalLight 一键安装脚本 (Windows)
:: 用法: install.bat <你的CodeBuddy项目路径>
::
:: 示例:
::   install.bat D:\DevelopTools\my-project
::   install.bat .          (安装到当前目录)
::
:: 脚本会自动:
::   1. 提取项目名作为标识
::   2. 复制 hooks 配置到项目的 .codebuddy\settings.local.json
::   3. 替换 TRAFFIC_LIGHT_DIR 为当前目录路径
:: ============================================================
setlocal enabledelayedexpansion

set "CYAN=[0;36m"
set "GREEN=[0;32m"
set "YELLOW=[1;33m"
set "RED=[0;31m"

echo ========================================
echo   SignalLight 一键安装程序
echo ========================================
echo.

:: ---- 获取脚本所在目录 ----
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

:: ---- 获取参数 ----
set "TARGET_PROJECT=%~1"
if "%TARGET_PROJECT%"=="" (
    echo 用法: install.bat ^<项目路径^>
    echo.
    echo 示例:
    echo   install.bat D:\DevelopTools\my-project
    echo   install.bat .
    echo.
    set /p TARGET_PROJECT="请输入项目路径: "
)

:: 规范化路径
pushd "%TARGET_PROJECT%" 2>nul || (
    echo 错误: 项目目录不存在
    pause
    exit /b 1
)
set "TARGET_PROJECT=%CD%"
popd

:: ---- 提取项目名 ----
for %%I in ("%TARGET_PROJECT%") do set "PROJECT_NAME=%%~nxI"

echo 安装目录: %SCRIPT_DIR%
echo 目标项目: %TARGET_PROJECT%
echo 项目标识: %PROJECT_NAME%
echo.

:: ---- 检查必要文件 ----
if not exist "%SCRIPT_DIR%\traffic_light.exe" if not exist "%SCRIPT_DIR%\traffic_light.py" (
    echo 错误: 找不到 traffic_light.exe 或 traffic_light.py
    echo 请确保在 SignalLight 目录下运行此脚本
    pause
    exit /b 1
)

if not exist "%SCRIPT_DIR%\.codebuddy-hooks.json" (
    echo 错误: 找不到 .codebuddy-hooks.json 模板文件
    pause
    exit /b 1
)

:: ---- 创建 .codebuddy 目录 ----
set "HOOKS_DIR=%TARGET_PROJECT%\.codebuddy"
if not exist "%HOOKS_DIR%" (
    mkdir "%HOOKS_DIR%"
    echo + 创建 %HOOKS_DIR%
)

:: ---- 生成 settings.local.json ----
set "OUTPUT_FILE=%HOOKS_DIR%\settings.local.json"

if exist "%OUTPUT_FILE%" (
    echo ! %OUTPUT_FILE% 已存在
    set /p CONFIRM="是否覆盖? [y/N]: "
    if /i not "!CONFIRM!"=="y" (
        echo 已跳过。如需重新安装请删除该文件后重试。
        pause
        exit /b 0
    )
    copy "%OUTPUT_FILE%" "%OUTPUT_FILE%.bak" >nul
    echo   已备份到 %OUTPUT_FILE%.bak
)

:: 使用 PowerShell 替换占位符（batch 不擅长文本处理）
:: TRAFFIC_LIGHT_DIR -> SignalLight 目录 (Windows 路径，双反斜杠用于 JSON)
:: <YOUR_PROJECT> -> 项目目录名
set "WIN_PATH=%SCRIPT_DIR:\=\\%"

powershell -NoProfile -Command ^
    "$template = Get-Content '%SCRIPT_DIR%\.codebuddy-hooks.json' -Raw -Encoding UTF8; ^
     $template = $template -replace 'TRAFFIC_LIGHT_DIR', '%SCRIPT_DIR%'; ^
     $template = $template -replace '<YOUR_PROJECT>', '%PROJECT_NAME%'; ^
     Set-Content -Path '%OUTPUT_FILE%' -Value $template -Encoding UTF8 -NoNewline"

if %ERRORLEVEL% neq 0 (
    echo 错误: 写入配置文件失败
    pause
    exit /b 1
)

echo + 写入 %OUTPUT_FILE%
echo.

:: ---- 检查 bash ----
where bash >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo OK bash 可用
) else (
    echo 注意: 未检测到 bash，CodeBuddy hooks 需要 Git Bash
    echo       请安装 Git for Windows: https://git-scm.com
)

echo.
echo ========================================
echo   安装完成！
echo ========================================
echo.
echo 下一步:
echo.
echo   1. 打开项目的 CodeBuddy 终端
echo   2. 或者重启 CodeBuddy，灯会自动出现
echo.
echo 如需为更多项目安装，重复运行:
echo   install.bat ^<项目路径^>
echo.
pause
