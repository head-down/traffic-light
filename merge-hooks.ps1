param(
    [string]$TemplatePath,
    [string]$OutputPath,
    [string]$SignalLightDir,
    [string]$ProjectName,
    [switch]$Global
)

# ============================================================
# SignalLight Hook 合并脚本
# 将模板 hooks 合并到已有的 settings，保留其他配置
#
# 项目级安装（默认）:
#   powershell -NoProfile -File merge-hooks.ps1 `
#       -TemplatePath ".codebuddy-hooks.json" `
#       -OutputPath "D:\project\.codebuddy\settings.local.json" `
#       -SignalLightDir "D:\tools\SignalLight" `
#       -ProjectName "my-project"
#
# 全局安装:
#   powershell -NoProfile -File merge-hooks.ps1 `
#       -TemplatePath ".codebuddy-hooks.json" `
#       -SignalLightDir "D:\tools\SignalLight" `
#       -Global
# ============================================================

$ErrorActionPreference = "Stop"

# ---- 全局模式处理 ----
if ($Global) {
    # 全局安装输出到 ~/.codebuddy/settings.json
    if (-not $OutputPath) {
        $OutputPath = Join-Path $env:USERPROFILE ".codebuddy\settings.json"
    }
    # 全局模式下不传 ProjectName（auto-bind.sh 会从环境变量自动检测）
    $ProjectName = ""
    Write-Output "[Global mode] output = $OutputPath"
}

# ---- 1. 读取模板 ----
if (-not (Test-Path $TemplatePath)) {
    Write-Error "模板文件不存在: $TemplatePath"
    exit 1
}

$templateRaw = Get-Content $TemplatePath -Raw -Encoding UTF8
# Windows 路径中的 \ 需要在 JSON 中转义为 \\
$escapedDir = $SignalLightDir -replace '\\', '\\'
$templateRaw = $templateRaw -replace [regex]::Escape("TRAFFIC_LIGHT_DIR"), $escapedDir

if ($Global) {
    # 全局模式：用 auto-bind.sh（自动检测项目名）替换 bind.sh --project <YOUR_PROJECT>
    $templateRaw = $templateRaw -replace [regex]::Escape("bind.sh --project <YOUR_PROJECT>"), "auto-bind.sh"
} else {
    $templateRaw = $templateRaw -replace [regex]::Escape("<YOUR_PROJECT>"), $ProjectName
}
$template = $templateRaw | ConvertFrom-Json

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
$alreadyInstalled = $false
if (-not $isNew -and (Get-Member -InputObject $existing -Name "hooks" -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
    # 检查是否已经有 SignalLight 的 hook（以 SessionStart 中的 bind.sh 为标志）
    $existingHooks = $existing.hooks
    if ($existingHooks.SessionStart) {
        foreach ($hookGroup in $existingHooks.SessionStart) {
            if ($hookGroup.hooks) {
                foreach ($h in $hookGroup.hooks) {
                    if ($h.command -match "bind\.sh.*--project") {
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
    foreach ($group in $ExistingHookGroups) {
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
    $newHookGroups = $hookEvent.Value

    # CodeBuddy 的 hooks 结构: { "<eventName>": [ { "matcher": "...", "hooks": [...] }, ... ] }
    # 追加 SignalLight 的 hook group，保留用户已有的同事件 hooks
    try {
        $existingHooks = $existing.hooks
        if ($existingHooks.$eventName) {
            # 已存在：检查命令去重，只追加新命令
            $existingArray = @($existingHooks.$eventName)
            $newToAdd = @()

            foreach ($newGroup in @($newHookGroups)) {
                # 检查整个 hook group 的 command 是否已存在
                $allCommandsExist = $true
                if ($newGroup.hooks) {
                    foreach ($h in $newGroup.hooks) {
                        if ($h.command) {
                            # 用核心可执行文件名去重（如 "auto-bind.sh"、"auto-stop.sh"、"traffic-light.sh"）
                            $cmdKey = if ($h.command -match '([\w.\-]+\.sh)') { $Matches[1] } else { $h.command }
                            if (-not (Test-CommandExists $existingArray $cmdKey)) {
                                $allCommandsExist = $false
                            }
                        }
                    }
                }
                if (-not $allCommandsExist) {
                    $newToAdd += $newGroup
                }
            }

            if ($newToAdd.Count -gt 0) {
                $existingHooks.$eventName = $existingArray + $newToAdd
                $updated += $eventName
            } else {
                $skipped += $eventName
            }
        } else {
            # 不存在：新建
            $existingHooks | Add-Member -MemberType NoteProperty -Name $eventName -Value $newHookGroups
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

$json = $existing | ConvertTo-Json -Depth 6
Set-Content -Path $OutputPath -Value $json -Encoding UTF8 -NoNewline

# ---- 6. 输出安装报告 ----
$total = ($skipped + $updated + $added).Count
if ($alreadyInstalled) {
    Write-Output "SIGNALLIGHT_ALREADY_INSTALLED"
} else {
    Write-Output "SIGNALLIGHT_INSTALLED"
    foreach ($name in $added) { Write-Output "  + $name" }
    foreach ($name in $updated) { Write-Output "  ~ $name" }
    foreach ($name in $skipped) { Write-Output "  - $name (已存在，跳过)" }
}
