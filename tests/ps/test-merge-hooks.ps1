<#
Upgrade tests - merge-hooks.ps1 must replace every shipped v1.0.0 hook entry.

Run:
    powershell -NoProfile -ExecutionPolicy Bypass -File tests/ps/test-merge-hooks.ps1

Exit code 0 means every assertion passed. Only temp directories are written;
the user's real settings.json is never touched.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:Checks = 0
$script:Failures = New-Object System.Collections.ArrayList

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    $script:Checks++
    if ($Condition) {
        Write-Output ('  ok   ' + $Name)
    } else {
        [void]$script:Failures.Add($Name + $(if ($Detail) { ' (' + $Detail + ')' } else { '' }))
        Write-Output ('  FAIL ' + $Name + $(if ($Detail) { ' -> ' + $Detail } else { '' }))
    }
}

function Assert-Eq {
    param([string]$Name, $Actual, $Expected)
    Assert-True $Name ($Actual -eq $Expected) ('expected=' + $Expected + ' actual=' + $Actual)
}

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptRoot)
$Merge = Join-Path $RepoRoot 'merge-hooks.ps1'
$Template = Join-Path $RepoRoot '.codebuddy-hooks.json'
foreach ($p in @($Merge, $Template)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Output ('FATAL: missing ' + $p); exit 2 }
}

$TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('tl-merge-' + [guid]::NewGuid().ToString('N'))

function Invoke-Merge {
    param([string]$SettingsPath)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Merge `
        -TemplatePath $Template -OutputPath $SettingsPath -SignalLightDir 'D:\tools\traffic-light' 2>&1
    return @{ Exit = $LASTEXITCODE; Output = ($out -join "`n") }
}

function Get-Commands {
    param([string]$SettingsPath)
    $j = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $cmds = @()
    foreach ($ev in $j.hooks.PSObject.Properties) {
        foreach ($g in @($ev.Value)) {
            foreach ($h in @($g.hooks)) {
                if ($h.command) { $cmds += [pscustomobject]@{ Event = $ev.Name; Command = [string]$h.command } }
            }
        }
    }
    return $cmds
}

try {
    New-Item -ItemType Directory -Path $TmpRoot -Force | Out-Null
    $settings = Join-Path $TmpRoot 'settings.json'

    # v1.0.0 shipped this exact shape (see `git show v1.0.0:.codebuddy-hooks.json`),
    # plus a user hook and an unrelated user setting that must survive.
    $legacy = @'
{
  "env": { "KEEP_ME": "1" },
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "LC_ALL=C.UTF-8 bash --noprofile --norc D:/tools/traffic-light/bind.sh --project demo && LC_ALL=C.UTF-8 bash --noprofile --norc D:/tools/traffic-light/hooks/traffic-light.sh idle" } ] },
      { "hooks": [ { "type": "command", "command": "echo user-session-start" } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "LC_ALL=C.UTF-8 bash --noprofile --norc D:/tools/traffic-light/hooks/traffic-light.sh thinking" } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "LC_ALL=C.UTF-8 bash --noprofile --norc D:/tools/traffic-light/hooks/traffic-light.sh waiting" } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "LC_ALL=C.UTF-8 bash --noprofile --norc D:/tools/traffic-light/auto-stop.sh" } ] }
    ]
  }
}
'@
    [System.IO.File]::WriteAllText($settings, $legacy, (New-Object System.Text.UTF8Encoding($false)))

    $first = Invoke-Merge $settings
    Assert-Eq 'merge exits 0' $first.Exit 0
    $cmds = Get-Commands $settings

    $stale = @($cmds | Where-Object {
        $_.Command -match 'auto-(bind|stop)\.sh' -or
        $_.Command -match '\bbind\.sh\b' -or
        $_.Command -match 'traffic-light\.sh[\s"'']+(idle|thinking|running|waiting|success)([\s"'';]|$)'
    })
    Assert-Eq 'no v1.0.0 hook entry survives' $stale.Count 0
    Assert-True 'no legacy bind.sh in output' (-not ($cmds.Command -match 'bind\.sh'))
    Assert-True 'no auto-bind/auto-stop in output' (-not ($cmds.Command -match 'auto-(bind|stop)\.sh'))

    $events = @($cmds | ForEach-Object { $_.Event } | Sort-Object -Unique)
    foreach ($e in @('SessionStart', 'UserPromptSubmit', 'PostToolUse', 'Notification', 'Stop', 'SessionEnd')) {
        Assert-True ('has ' + $e) ($events -contains $e)
    }
    # 入口可能是 traffic_light.exe --hook、pythonw run-hidden.pyw 或（没有 pythonw 时）
    # 退回 bash，三者都必须以事件名结尾
    $launcher = '(run-hidden\.pyw"?|traffic_light\.exe"?\s+--hook|traffic-light\.sh)\s+'
    Assert-True 'session-start is wired' (@($cmds | Where-Object { $_.Command -match ($launcher + 'session-start$') }).Count -ge 1)
    Assert-True 'end event is kept' (@($cmds | Where-Object { $_.Command -match ($launcher + 'end$') }).Count -ge 1)
    Assert-True 'entries go through a windowless launcher' (@($cmds | Where-Object { $_.Command -match 'run-hidden\.pyw|--hook' }).Count -ge 1)
    Assert-True 'user hook survives' (@($cmds | Where-Object { $_.Command -match 'echo user-session-start' }).Count -eq 1)

    $j = Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Eq 'unrelated setting survives' $j.env.KEEP_ME '1'

    $before = Get-Content -LiteralPath $settings -Raw
    $second = Invoke-Merge $settings
    $after = Get-Content -LiteralPath $settings -Raw
    Assert-Eq 'second merge exits 0' $second.Exit 0
    Assert-Eq 'merge is idempotent' $after $before
} catch {
    Write-Output ('  FAIL unhandled exception: ' + $_.Exception.Message)
    [void]$script:Failures.Add('unhandled: ' + $_.Exception.Message)
} finally {
    Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($script:Failures.Count -gt 0) {
    Write-Output ('FAILED ' + $script:Failures.Count + ' of ' + $script:Checks + ' assertions')
    foreach ($f in $script:Failures) { Write-Output ('  - ' + $f) }
    exit 1
}
Write-Output ('PASS ' + $script:Checks + ' assertions')
exit 0
