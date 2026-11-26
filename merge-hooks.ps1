param(
    [string]$TemplatePath,
    [string]$OutputPath,
    [string]$SignalLightDir,
    [switch]$Global
)

# ============================================================
# SignalLight Hook 合并脚本
# 将模板 hooks 合并到已有的 settings，保留其他配置
#
# 模板只含 TRAFFIC_LIGHT_DIR 一个占位符；一窗一灯按会话 pid /
# 窗口 hwnd 做键，不再有项目名占位符，也没有项目级 hook。
#
# 全局安装:
#   powershell -NoProfile -ExecutionPolicy Bypass -File merge-hooks.ps1 `
#       -TemplatePath ".codebuddy-hooks.json" `
#       -SignalLightDir "D:\tools\SignalLight" `
#       -Global
#
# 项目级安装:
#   powershell -NoProfile -ExecutionPolicy Bypass -File merge-hooks.ps1 `
#       -TemplatePath ".codebuddy-hooks.json" `
#       -OutputPath "D:\project\.codebuddy\settings.local.json" `
#       -SignalLightDir "D:\tools\SignalLight"
# ============================================================

$ErrorActionPreference = "Stop"

# ---- 全局模式处理 ----
if ($Global) {
    if (-not $OutputPath) {
        $OutputPath = Join-Path $env:USERPROFILE ".codebuddy\settings.json"
    }
    Write-Output "[Global mode] output = $OutputPath"
}

# ---- 1. 读取模板 ----
if (-not (Test-Path $TemplatePath)) {
    Write-Error "模板文件不存在: $TemplatePath"
    exit 1
}

$templateRaw = Get-Content $TemplatePath -Raw -Encoding UTF8

# 将 Windows 路径转为 Git Bash 兼容的 Unix 格式
# D:\DevelopTools\mine\traffic-light → /d/DevelopTools/mine/traffic-light
# 必须用正斜杠，否则 bash 会把 \D \m \t 等当转义字符
# TrimEnd 处理末尾反斜杠（D:\tools\SignalLight\ → /d/tools/SignalLight），避免双斜杠
$SignalLightDir = $SignalLightDir.TrimEnd('\')
$unixDir = "/" + ($SignalLightDir[0].ToString().ToLower()) + ($SignalLightDir.Substring(2) -replace '\\', '/')
$templateRaw = $templateRaw -replace [regex]::Escape("TRAFFIC_LIGHT_DIR"), $unixDir

$template = $templateRaw | ConvertFrom-Json

# ---- 1b. 无窗口启动器 ------------------------------------------------------
# CodeBuddy 从不带控制台的进程里拉起 hook；直接调 bash 会弹一个黑框。优先用
# 同目录的交通灯 EXE（--hook 模式），其次 pythonw + hooks/run-hidden.pyw，
# 两者都是 GUI 子系统，里面的 bash 用 CREATE_NO_WINDOW 起。
$winDir = $SignalLightDir -replace '\\', '/'
if (Test-Path -LiteralPath (Join-Path $SignalLightDir 'traffic_light.exe')) {
    $launcher = '"' + $winDir + '/traffic_light.exe" --hook'
} else {
    $pythonw = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
    if ($pythonw) {
        $launcher = '"' + ($pythonw -replace '\\', '/') + '" "' + $winDir + '/hooks/run-hidden.pyw"'
    } else {
        Write-Output '[warn] 找不到 pythonw 也没有 traffic_light.exe：hook 退回 bash，每次事件可能闪一下控制台'
        $launcher = 'LC_ALL=C.UTF-8 bash --noprofile --norc ' + $unixDir + '/hooks/traffic-light.sh'
    }
}
foreach ($hookEvent in $template.hooks.PSObject.Properties) {
    foreach ($group in @($hookEvent.Value)) {
        foreach ($h in @($group.hooks)) {
            if ($h.command -and $h.command -like 'TRAFFIC_LIGHT_LAUNCH*') {
                $h.command = $h.command -replace '^TRAFFIC_LIGHT_LAUNCH', $launcher
            }
        }
    }
}

# ---- 2. 读取已有配置 ----
$isNew = $false
if (Test-Path $OutputPath) {
    $existing = Get-Content $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # ConvertFrom-Json 可能返回 PSCustomObject 或 null
    if ($null -eq $existing) {
        $existing = [PSCustomObject]@{}
        $isNew = $true
    }
} else {
    $existing = [PSCustomObject]@{}
    $isNew = $true
}

# ---- 3. 检查是否有 SignalLight hooks 已存在 ----
# 旧版本入口（auto-bind/auto-stop/bind.sh/旧状态名）已随升级删除，留着只会在
# 每次事件报错；本版入口有两种形态，都靠 GUI 子系统宿主避免弹黑框：
#   pythonw <dir>/hooks/run-hidden.pyw <事件名>
#   <dir>/traffic_light.exe --hook <事件名>
# 命令形态会随版本变化，所以按「属于交通灯」判定，不按具体命令。
$SIGNALLIGHT_ENTRY_PATTERN = 'auto-(bind|stop)\.sh|\bbind\.sh\b|traffic-light\.sh|run-hidden\.pyw|traffic_light\.exe"?\s+--hook'

$alreadyInstalled = $false
if (-not $isNew -and (Get-Member -InputObject $existing -Name "hooks" -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
    # 以 SessionStart 中的 traffic-light.sh 为标志
    $existingHooks = $existing.hooks
    if ($existingHooks.SessionStart) {
        foreach ($hookGroup in @($existingHooks.SessionStart)) {
            if ($hookGroup.hooks) {
                foreach ($h in $hookGroup.hooks) {
                    if ($h.command -match $SIGNALLIGHT_ENTRY_PATTERN) {
                        $alreadyInstalled = $true
                        break
                    }
                }
            }
        }
    }
}

# ---- 去重辅助 ----
function Test-CommandExists {
    param($ExistingHookGroups, $NewCommand)
    foreach ($group in @($ExistingHookGroups)) {
        if ($group.hooks) {
            foreach ($h in $group.hooks) {
                if ($h.command -and $h.command -match [regex]::Escape($NewCommand)) {
                    return $true
                }
            }
        }
    }
    return $false
}

# 属于交通灯的 hook 都靠同一组特征识别，重装时整组替换。
$LEGACY_HOOK_PATTERN = $SIGNALLIGHT_ENTRY_PATTERN

function Remove-LegacyHooks {
    param($ExistingHookGroups)
    $kept = @()
    foreach ($group in @($ExistingHookGroups)) {
        $legacy = $false
        if ($group.hooks) {
            foreach ($h in $group.hooks) {
                if ($h.command -and $h.command -match $LEGACY_HOOK_PATTERN) {
                    $legacy = $true
                    break
                }
            }
        }
        if (-not $legacy) { $kept += $group }
    }
    return $kept
}

# ---- 4. 合并 hooks ----
$skipped = @()
$updated = @()
$added = @()

# 确保 hooks 属性存在
if (-not (Get-Member -InputObject $existing -Name "hooks" -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
    $existing | Add-Member -MemberType NoteProperty -Name "hooks" -Value ([PSCustomObject]@{})
}

foreach ($hookEvent in $template.hooks.PSObject.Properties) {
    $eventName = $hookEvent.Name
    $newHookGroups = @($hookEvent.Value)

    # CodeBuddy 的 hooks 结构: { "<eventName>": [ { "matcher": "...", "hooks": [...] }, ... ] }
    # 追加 SignalLight 的 hook group，保留用户已有的同事件 hooks
    try {
        if ($existing.hooks.$eventName) {
            $existingArray = @(Remove-LegacyHooks @($existing.hooks.$eventName))
            $newToAdd = @()

            foreach ($newGroup in $newHookGroups) {
                $allCommandsExist = $true
                if ($newGroup.hooks) {
                    foreach ($h in $newGroup.hooks) {
                        if ($h.command -and -not (Test-CommandExists $existingArray $h.command)) {
                            $allCommandsExist = $false
                        }
                    }
                }
                if (-not $allCommandsExist) {
                    $newToAdd += $newGroup
                }
            }

            if ($newToAdd.Count -gt 0) {
                $existing.hooks.$eventName = $existingArray + $newToAdd
                $updated += $eventName
            } else {
                $existing.hooks.$eventName = $existingArray
                $skipped += $eventName
            }
        } else {
            $existing.hooks | Add-Member -MemberType NoteProperty -Name $eventName -Value $newHookGroups
            $added += $eventName
        }
    } catch {
        Write-Error "合并 $eventName 失败: $_"
        exit 1
    }
}

# ---- 5. 写入结果 ----
$outputDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$json = $existing | ConvertTo-Json -Depth 8
Set-Content -Path $OutputPath -Value $json -Encoding UTF8 -NoNewline

# ---- 6. 输出安装报告 ----
if ($alreadyInstalled) {
    Write-Output "SIGNALLIGHT_ALREADY_INSTALLED"
} else {
    Write-Output "SIGNALLIGHT_INSTALLED"
    foreach ($name in $added) { Write-Output "  + $name" }
    foreach ($name in $updated) { Write-Output "  ~ $name" }
    foreach ($name in $skipped) { Write-Output "  - $name (已存在，跳过)" }
}
