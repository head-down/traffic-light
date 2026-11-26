@echo off
:: ============================================================
:: SignalLight 一键安装脚本 (Windows)
::
:: 全局安装:    install.bat --global
:: 项目级安装:  install.bat <项目路径>
::
:: 安装 = 把 hooks 合并进 settings + 跑一次 GC 清掉旧格式资产。
:: 一窗一灯按会话 pid / 窗口 hwnd 做键，不再有项目级键：
:: 重复安装只会更新 hooks，不会新增第二个任务或第二盏灯。
:: ============================================================
setlocal enabledelayedexpansion

echo ========================================
echo   SignalLight 一键安装程序
echo ========================================
echo.

:: ---- 获取脚本所在目录 ----
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

:: ---- 解析参数 ----
set "GLOBAL_MODE="
set "TARGET_PROJECT=%~1"

if /i "%TARGET_PROJECT%"=="--global" (
    set "GLOBAL_MODE=1"
    set "TARGET_PROJECT="
)

if not defined GLOBAL_MODE if "%TARGET_PROJECT%"=="" (
    echo 用法:
    echo   全局安装:   install.bat --global
    echo   项目级安装: install.bat ^<项目路径^>
    echo.
    echo 示例:
    echo   install.bat --global
    echo   install.bat D:\DevelopTools\my-project
    echo   install.bat .
    echo.
    set /p TARGET_PROJECT="请输入项目路径 (或输入 --global 全局安装): "
    if /i "!TARGET_PROJECT!"=="--global" (
        set "GLOBAL_MODE=1"
        set "TARGET_PROJECT="
    )
)

:: ---- 检查必要文件 ----
if not exist "%SCRIPT_DIR%\traffic_light.exe" if not exist "%SCRIPT_DIR%\traffic_light.py" (
    echo 错误: 找不到 traffic_light.exe 或 traffic_light.py
    echo 请确保在 SignalLight 目录下运行此脚本
    pause
    exit /b 1
)

set "TEMPLATE=%SCRIPT_DIR%\.codebuddy-hooks.json"
set "RESOLVE=%SCRIPT_DIR%\resolve.ps1"
echo 安装目录: %SCRIPT_DIR%

:: ---- 合并 hooks ----
if defined GLOBAL_MODE goto :global_install

pushd "%TARGET_PROJECT%" 2>nul || (
    echo 错误: 项目目录不存在
    pause
    exit /b 1
)
set "TARGET_PROJECT=%CD%"
popd

set "OUTPUT=%TARGET_PROJECT%\.codebuddy\settings.local.json"
echo 目标项目: %TARGET_PROJECT%
echo.
echo 正在合并 hooks 配置...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_DIR%\merge-hooks.ps1" -TemplatePath "%TEMPLATE%" -OutputPath "%OUTPUT%" -SignalLightDir "%SCRIPT_DIR%" > "%TEMP%\signal-light-install.tmp" 2>&1
set "MERGE_EXIT=%ERRORLEVEL%"
goto :check_result

:global_install
echo 安装模式: 全局 (所有 CodeBuddy 项目)
echo.
echo 正在合并 hooks 配置到全局 settings.json ...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_DIR%\merge-hooks.ps1" -TemplatePath "%TEMPLATE%" -SignalLightDir "%SCRIPT_DIR%" -Global > "%TEMP%\signal-light-install.tmp" 2>&1
set "MERGE_EXIT=%ERRORLEVEL%"

:check_result
if %MERGE_EXIT% neq 0 (
    echo 错误: hooks 合并失败
    type "%TEMP%\signal-light-install.tmp"
    del "%TEMP%\signal-light-install.tmp" 2>nul
    pause
    exit /b 1
)

:: 解析输出
findstr /c:"SIGNALLIGHT_ALREADY_INSTALLED" "%TEMP%\signal-light-install.tmp" >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo   OK SignalLight 已安装（hooks 已是最新）
) else (
    for /f "tokens=*" %%L in ('type "%TEMP%\signal-light-install.tmp" ^| findstr /r "^  "') do (
        call :print_line "%%L"
    )
)
del "%TEMP%\signal-light-install.tmp" 2>nul

:: ---- 一次性 GC：清掉旧格式任务 / 状态文件 / 孤儿锚，幂等 ----
echo.
echo 正在清理旧版本资产（计划任务 / .state / .pid / 孤儿锚）...
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%RESOLVE%" -GcOnly
if %ERRORLEVEL% neq 0 echo   GC 失败（不影响本次安装），下次 SessionStart 会重试

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
if defined GLOBAL_MODE (
    echo 所有 CodeBuddy 项目打开时，每个终端窗口自动出现自己的灯
    echo.
    echo 如需卸载:
    echo   编辑 %%USERPROFILE%%\.codebuddy\settings.json
    echo   删除 hooks 中的 SignalLight 相关配置
) else (
    echo 下一步:
    echo   打开该项目的 CodeBuddy 终端，灯自动出现
    echo.
    echo 如需全局安装（推荐）:
    echo   install.bat --global
)
echo.
pause
