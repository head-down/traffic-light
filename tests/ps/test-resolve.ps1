<#
T02 resolver tests - self-contained, no Pester dependency.

Run:
    powershell -NoProfile -ExecutionPolicy Bypass -File tests/ps/test-resolve.ps1

Exit code 0 means every assertion passed. Only snapshots and temp directories are
fed in: no real process is inspected and no real window is touched.
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
$Resolver = Join-Path $RepoRoot 'resolve.ps1'
if (-not (Test-Path -LiteralPath $Resolver)) { Write-Output ('FATAL: resolver not found at ' + $Resolver); exit 2 }

$PwshExe = Join-Path $PSHOME (Split-Path -Leaf (Get-Process -Id $PID).Path)
$CbCmd = 'node.exe C:\Users\someone\AppData\Roaming\npm\node_modules\@tencent-ai\codebuddy-code\dist\index.js --serve'
$script:TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('tl-t02-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $script:TmpRoot -Force)

function Invoke-Resolver {
    param([string[]]$ArgList)
    $text = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $Resolver @ArgList 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Text     = (($text | ForEach-Object { [string]$_ }) -join ([char]10))
    }
}

function New-Case {
    param([string]$Name)
    $d = Join-Path $script:TmpRoot $Name
    [void](New-Item -ItemType Directory -Path $d -Force)
    return $d
}

function Write-Snapshot {
    param([string]$Path, [int]$SelfPid, [string]$ProxyUrl = '', $Listeners = $null, [object[]]$Procs)
    $o = [ordered]@{ selfPid = $SelfPid; procs = $Procs }
    if ($ProxyUrl) { $o.proxyUrl = $ProxyUrl }
    if ($Listeners) { $o.listeners = $Listeners }
    ([pscustomobject]$o | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-Bind {
    param([string]$Path)
    $h = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -match '^([^=]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] }
        }
    }
    return $h
}

function Get-DryRun {
    param([string]$Snapshot, [string]$StateDir, [string]$Cwd = 'D:/work/proj', [string]$SessionId = 'sess-1')
    $r = Invoke-Resolver @('-Snapshot', $Snapshot, '-StateDir', $StateDir, '-Cwd', $Cwd, '-SessionId', $SessionId, '-DryRun')
    $j = $null
    try { $j = $r.Text | ConvertFrom-Json } catch { $j = $null }
    return [pscustomobject]@{ ExitCode = $r.ExitCode; Text = $r.Text; Json = $j }
}

function Invoke-Tests {

    # ---------------------------------------------------------------- A1 ----
    Write-Output 'A1  proxy port owner wins over the parent chain'
    $d = New-Case 'a1'
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -ProxyUrl 'http://127.0.0.1:54894/internal/hooks/session-start' -Listeners @{ '54894' = 6000 } -Procs @(
        @{ processId = 5000; parentProcessId = 4000; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe -File resolve.ps1'; hwnd = 0 }
        @{ processId = 4000; parentProcessId = 2000; name = 'bash.exe'; creationFt = '900'; commandLine = '/usr/bin/bash D:/tl/resolve.ps1'; hwnd = 0 }
        @{ processId = 2000; parentProcessId = 3000; name = 'node.exe'; creationFt = '700'; commandLine = $CbCmd; hwnd = 0 }
        @{ processId = 3000; parentProcessId = 0; name = 'WindowsTerminal.exe'; creationFt = '600'; commandLine = 'WindowsTerminal.exe'; hwnd = 0 }
        @{ processId = 6000; parentProcessId = 0; name = 'node.exe'; creationFt = '800'; commandLine = $CbCmd + ' --second-session'; hwnd = 0 }
    )
    $r = Get-DryRun -Snapshot $snap -StateDir (Join-Path $d 'state')
    Assert-Eq 'exit code' $r.ExitCode 0
    Assert-True 'dry-run emits JSON' ($null -ne $r.Json) $r.Text
    if ($r.Json) {
        Assert-Eq 'pid is the port owner, not the chain node' $r.Json.pid 6000
        Assert-Eq 'creation_ft follows that pid' $r.Json.creation_ft '800'
    }

    # ---------------------------------------------------------------- A2 ----
    Write-Output 'A2  missing proxy port falls back to the parent chain'
    $d = New-Case 'a2'
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Procs @(
        @{ processId = 5000; parentProcessId = 4000; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe -File resolve.ps1'; hwnd = 0 }
        @{ processId = 4000; parentProcessId = 2000; name = 'bash.exe'; creationFt = '900'; commandLine = '/usr/bin/bash D:/tl/resolve.ps1'; hwnd = 0 }
        @{ processId = 2000; parentProcessId = 3000; name = 'node.exe'; creationFt = '700'; commandLine = $CbCmd; hwnd = 0 }
        @{ processId = 3000; parentProcessId = 0; name = 'WindowsTerminal.exe'; creationFt = '600'; commandLine = 'WindowsTerminal.exe'; hwnd = 0 }
    )
    $r = Get-DryRun -Snapshot $snap -StateDir (Join-Path $d 'state')
    Assert-Eq 'exit code' $r.ExitCode 0
    if ($r.Json) {
        Assert-Eq 'pid comes from the chain' $r.Json.pid 2000
        Assert-Eq 'creation_ft comes from the chain' $r.Json.creation_ft '700'
    }

    # ---------------------------------------------------------------- A3 ----
    Write-Output 'A3  a parent created after its child is not accepted'
    $d = New-Case 'a3'
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 100 -Procs @(
        @{ processId = 100; parentProcessId = 200; name = 'powershell.exe'; creationFt = '5000'; commandLine = 'powershell.exe -File resolve.ps1'; hwnd = 0 }
        @{ processId = 200; parentProcessId = 300; name = 'node.exe'; creationFt = '6000'; commandLine = $CbCmd; hwnd = 0 }
        @{ processId = 300; parentProcessId = 0; name = 'WindowsTerminal.exe'; creationFt = '4000'; commandLine = 'WindowsTerminal.exe'; hwnd = 0 }
    )
    $r = Get-DryRun -Snapshot $snap -StateDir (Join-Path $d 'state')
    Assert-Eq 'exit code' $r.ExitCode 0
    if ($r.Json) {
        Assert-Eq 'no identity is invented' $r.Json.pid 0
        Assert-Eq 'degraded because nothing resolved' $r.Json.degraded 1
    }

    # ---------------------------------------------------------------- A4 ----
    Write-Output 'A4  GC collects binds whose creation_ft does not match (PID reuse)'
    $d = New-Case 'a4'
    $state = Join-Path $d 'state'
    [void](New-Item -ItemType Directory -Path $state -Force)
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Procs @(
        @{ processId = 5000; parentProcessId = 0; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 2000; parentProcessId = 5000; name = 'node.exe'; creationFt = '111'; commandLine = $CbCmd; hwnd = 0 }
    )
    Set-Content -LiteralPath (Join-Path $state 'same.bind') -Value @('session_id=same', 'pid=2000', 'creation_ft=111', 'hwnd=0') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $state 'reborn.bind') -Value @('session_id=reborn', 'pid=2000', 'creation_ft=222', 'hwnd=0') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $state '2000.state') -Value @('thinking', 'D:/work/proj') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $state 'legacy.state') -Value @('idle', 'D:/work/proj') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $state 'proj.pid') -Value '999' -Encoding UTF8

    $r = Invoke-Resolver @('-Snapshot', $snap, '-StateDir', $state, '-GcOnly', '-DryRun')
    Assert-Eq 'exit code' $r.ExitCode 0
    $acts = @()
    try { $acts = @(($r.Text | ConvertFrom-Json).gc) } catch { $acts = @() }
    $joined = $acts -join ','
    Assert-True 'pid-reused bind is collected' ($acts -contains 'file:reborn.bind') $joined
    Assert-True 'matching bind is kept' (-not ($acts -contains 'file:same.bind')) $joined
    Assert-True 'legacy .pid is collected' ($acts -contains 'file:proj.pid') $joined
    Assert-True 'legacy state key is collected' ($acts -contains 'file:legacy.state') $joined
    Assert-True 'numeric state key is kept' (-not ($acts -contains 'file:2000.state')) $joined

    $r2 = Invoke-Resolver @('-Snapshot', $snap, '-StateDir', $state, '-GcOnly')
    Assert-Eq 'apply exit code' $r2.ExitCode 0
    Assert-True 'reborn.bind is gone after apply' (-not (Test-Path -LiteralPath (Join-Path $state 'reborn.bind')))
    Assert-True 'same.bind survives apply' (Test-Path -LiteralPath (Join-Path $state 'same.bind'))

    # ---------------------------------------------------------------- B1 ----
    Write-Output 'B1  a worktree cwd labels the main repository, not the worktree'
    $d = New-Case 'b1'
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Procs @(
        @{ processId = 5000; parentProcessId = 2000; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 2000; parentProcessId = 0; name = 'node.exe'; creationFt = '900'; commandLine = $CbCmd; hwnd = 0 }
    )
    $gitOk = $true
    & git --version 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $gitOk = $false }
    Assert-True 'git is available for the worktree case' $gitOk
    if ($gitOk) {
        $repo = Join-Path $d 'main-repo'
        $wt = Join-Path $d 'wt-feature'
        & git init -q $repo 2>&1 | Out-Null
        & git -C $repo -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init 2>&1 | Out-Null
        & git -C $repo worktree add -q $wt -b feature 2>&1 | Out-Null
        Assert-True 'temp worktree exists' (Test-Path -LiteralPath (Join-Path $wt '.git'))

        $r = Get-DryRun -Snapshot $snap -StateDir (Join-Path $d 'state') -Cwd $wt
        Assert-Eq 'exit code' $r.ExitCode 0
        if ($r.Json) {
            Assert-Eq 'project is the main repo name' $r.Json.project 'main-repo'
            Assert-Eq 'cwd is the real worktree path' $r.Json.cwd $wt
        }

        $plain = Join-Path $d 'no-git-here'
        [void](New-Item -ItemType Directory -Path $plain -Force)
        $r = Get-DryRun -Snapshot $snap -StateDir (Join-Path $d 'state') -Cwd $plain
        if ($r.Json) { Assert-Eq 'non-git cwd falls back to its basename' $r.Json.project 'no-git-here' }
    }

    # ---------------------------------------------------------------- B2 ----
    Write-Output 'B2  dry-run exposes the full bind contract'
    $d = New-Case 'b2'
    $state = Join-Path $d 'state'
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Procs @(
        @{ processId = 5000; parentProcessId = 2000; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 2000; parentProcessId = 0; name = 'node.exe'; creationFt = '900'; commandLine = $CbCmd; hwnd = 0 }
    )
    $r = Get-DryRun -Snapshot $snap -StateDir $state -SessionId 'abc-123'
    if ($r.Json) {
        Assert-Eq 'bind_path points at <session_id>.bind' $r.Json.bind_path (Join-Path $state 'abc-123.bind')
        Assert-Eq 'owner fields are present' ([bool]($r.Json.PSObject.Properties.Name -contains 'owner_ft')) $true
        Assert-Eq 'dry-run does not create the state dir' (Test-Path -LiteralPath $state) $false
    }

    # ---------------------------------------------------------------- C1 ----
    Write-Output 'C1  no window still writes a degraded bind'
    $d = New-Case 'c1'
    $state = Join-Path $d 'state'
    $cwd = Join-Path $d 'session-dir'
    [void](New-Item -ItemType Directory -Path $cwd -Force)
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Procs @(
        @{ processId = 5000; parentProcessId = 2000; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 2000; parentProcessId = 0; name = 'node.exe'; creationFt = '900'; commandLine = $CbCmd; hwnd = 0 }
    )
    $r = Invoke-Resolver @('-Snapshot', $snap, '-StateDir', $state, '-SessionId', 's1', '-Cwd', $cwd)
    Assert-Eq 'exit code' $r.ExitCode 0
    $b = Read-Bind (Join-Path $state 's1.bind')
    Assert-Eq 'bind is written' ([bool]($b.Count -gt 0)) $true $r.Text
    Assert-Eq 'pid is kept even without a window' $b['pid'] '2000'
    Assert-Eq 'creation_ft is written' $b['creation_ft'] '900'
    Assert-Eq 'hwnd is 0' $b['hwnd'] '0'
    Assert-Eq 'degraded is flagged' $b['degraded'] '1'
    Assert-Eq 'cwd is recorded separately from project' $b['cwd'] $cwd
    Assert-Eq 'project is the cwd basename' $b['project'] 'session-dir'
    $tmps = @(Get-ChildItem -LiteralPath $state -Filter '*.tmp' -File -ErrorAction SilentlyContinue)
    Assert-Eq 'no .tmp residue after the atomic replace' $tmps.Count 0

    # ---------------------------------------------------------------- C2 ----
    Write-Output 'C2  identity fields survive a refresh, only hwnd moves'
    $d = New-Case 'c2'
    $state = Join-Path $d 'state'
    [void](New-Item -ItemType Directory -Path $state -Force)
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Procs @(
        @{ processId = 5000; parentProcessId = 2000; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 2000; parentProcessId = 0; name = 'node.exe'; creationFt = '900'; commandLine = $CbCmd; hwnd = 777 }
    )
    Set-Content -LiteralPath (Join-Path $state 's2.bind') -Value @(
        'session_id=s2', 'pid=2000', 'creation_ft=900', 'hwnd=0',
        'hwnd_owner_pid=0', 'hwnd_owner_ft=', 'project=stale', 'cwd=D:/stale', 'updated=1', 'degraded=1'
    ) -Encoding UTF8

    $r = Invoke-Resolver @('-Snapshot', $snap, '-StateDir', $state, '-SessionId', 's2', '-Cwd', (Join-Path $d 'fresh'))
    Assert-Eq 'exit code' $r.ExitCode 0
    $b = Read-Bind (Join-Path $state 's2.bind')
    Assert-Eq 'hwnd is refreshed' $b['hwnd'] '777'
    Assert-Eq 'degraded clears once a window is known' $b['degraded'] '0'
    Assert-Eq 'pid is untouched' $b['pid'] '2000'
    Assert-Eq 'creation_ft is untouched' $b['creation_ft'] '900'
    Assert-Eq 'project is refreshed' $b['project'] 'fresh'
    Assert-Eq 'updated is refreshed' ([bool]($b['updated'] -ne '1')) $true

    # a different resolved pid must not hijack an established identity
    $snap2 = Join-Path $d 'snap2.json'
    Write-Snapshot -Path $snap2 -SelfPid 5000 -ProxyUrl 'http://127.0.0.1:54163/internal/hooks/x' -Listeners @{ '54163' = 4000 } -Procs @(
        @{ processId = 5000; parentProcessId = 2000; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 2000; parentProcessId = 0; name = 'node.exe'; creationFt = '900'; commandLine = $CbCmd; hwnd = 0 }
        @{ processId = 4000; parentProcessId = 0; name = 'node.exe'; creationFt = '800'; commandLine = $CbCmd; hwnd = 888 }
    )
    $r = Invoke-Resolver @('-Snapshot', $snap2, '-StateDir', $state, '-SessionId', 's2', '-Cwd', (Join-Path $d 'fresh'))
    $b = Read-Bind (Join-Path $state 's2.bind')
    Assert-Eq 'a neighbouring process cannot replace the identity' $b['pid'] '2000'
    Assert-Eq 'its creation_ft is kept too' $b['creation_ft'] '900'
    Assert-Eq 'but the window follows the new resolution' $b['hwnd'] '888'

    # ---------------------------------------------------------------- F1 ----
    Write-Output 'F1  a resolved window stays a window even when the pid is unknown'
    $d = New-Case 'f1'
    $state = Join-Path $d 'state'
    $cwd = Join-Path $d 'win-dir'
    [void](New-Item -ItemType Directory -Path $cwd -Force)
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Procs @(
        @{ processId = 5000; parentProcessId = 4000; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 4000; parentProcessId = 0; name = 'WindowsTerminal.exe'; creationFt = '900'; commandLine = 'WindowsTerminal.exe'; hwnd = 424242 }
    )
    $r = Invoke-Resolver @('-Snapshot', $snap, '-StateDir', $state, '-SessionId', 'f1', '-Cwd', $cwd)
    Assert-Eq 'exit code' $r.ExitCode 0
    $b = Read-Bind (Join-Path $state 'f1.bind')
    Assert-Eq 'bind survives its own GC' ([bool]($b.Count -gt 0)) $true $r.Text
    Assert-Eq 'identity stays unknown' $b['pid'] '0'
    Assert-Eq 'hwnd is kept' $b['hwnd'] '424242'
    Assert-Eq 'degraded is not flagged without a pid' $b['degraded'] '0'
}

try {
    Invoke-Tests
} catch {
    Write-Output ('  FAIL unhandled exception: ' + $_.Exception.Message)
    [void]$script:Failures.Add('unhandled: ' + $_.Exception.Message)
} finally {
    Remove-Item -LiteralPath $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($script:Failures.Count -gt 0) {
    Write-Output ('FAILED ' + $script:Failures.Count + ' of ' + $script:Checks + ' assertions')
    foreach ($f in $script:Failures) { Write-Output ('  - ' + $f) }
    exit 1
}
Write-Output ('PASS ' + $script:Checks + ' assertions')
exit 0
