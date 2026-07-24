@echo off
:: ============================================================
:: SignalLight 一键安装脚本 (Windows)
:: 用法: install.bat <你的CodeBuddy项目路径>
::
:: 示例:
::   install.bat D:\DevelopTools\my-project
::   install.bat .          (安装到当前目录)
::
:: 智能合并：已有 settings.local.json 时只追加 SignalLight hooks，
:: 保留用户已有的环境变量、权限、其他 hooks 等配置。
:: ============================================================
setlocal enabledelayedexpansion

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

pushd "%TARGET_PROJECT%" 2>nul || (
    echo 错误: 项目目录不存在
    pause
    exit /b 1
)
set "TARGET_PROJECT=%CD%"
popd

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

:: ---- 调用 merge-hooks.ps1 智能合并 ----
set "TEMPLATE=%SCRIPT_DIR%\.codebuddy-hooks.json"
set "OUTPUT=%TARGET_PROJECT%\.codebuddy\settings.local.json"

echo 正在合并 hooks 配置...
echo.

powershell -NoProfile -WindowStyle Hidden -File "%SCRIPT_DIR%\merge-hooks.ps1" ^
    -TemplatePath "%TEMPLATE%" ^
    -OutputPath "%OUTPUT%" ^
    -SignalLightDir "%SCRIPT_DIR%" ^
    -ProjectName "%PROJECT_NAME%" > "%TEMP%\signal-light-install.tmp" 2>&1
set "MERGE_EXIT=%ERRORLEVEL%"

if %MERGE_EXIT% neq 0 (
    echo 错误: hooks 合并失败
    type "%TEMP%\signal-light-install.tmp"
    pause
    exit /b 1
)

:: 解析输出
findstr /c:"SIGNALLIGHT_ALREADY_INSTALLED" "%TEMP%\signal-light-install.tmp" >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo   OK SignalLight 已安装（之前已配置，hooks 已更新）
) else (
    for /f "tokens=*" %%L in ('type "%TEMP%\signal-light-install.tmp" ^| findstr /r "^  "') do (
        call :print_line "%%L"
    )
)
del "%TEMP%\signal-light-install.tmp" 2>nul
goto :end

:print_line
set "line=%~1"
if "%line:~2,1%"=="+" echo   + %line:~4%
if "%line:~2,1%"=="~" echo   ~ %line:~4%
goto :eof

:end
echo.
echo ========================================
echo   安装完成！
echo ========================================
echo.
echo 下一步:
echo   打开项目的 CodeBuddy 终端，灯自动出现
echo.
echo 如需为更多项目安装:
echo   install.bat ^<项目路径^>
echo.
pause
