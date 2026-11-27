<#
T02 resolver tests - self-contained, no Pester dependency.

Run:
    powershell -NoProfile -ExecutionPolicy Bypass -File tests/ps/test-resolve.ps1

Exit code 0 means every assertion passed. Only snapshots and temp directories are
fed in: no real process is inspected and no real window is touched.

Most cases call Get-ResolutionDecision / Get-GcPlan in-process (the lib is
dot-sourced below); cases that assert effects the shell owns - writing the bind,
applying GC, spawning - still go through the CLI, plus SM1 pins the CLI contract.
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
$ResolverLib = Join-Path $RepoRoot 'resolve-lib.ps1'
if (-not (Test-Path -LiteralPath $Resolver)) { Write-Output ('FATAL: resolver not found at ' + $Resolver); exit 2 }
if (-not (Test-Path -LiteralPath $ResolverLib)) { Write-Output ('FATAL: resolver lib not found at ' + $ResolverLib); exit 2 }
. $ResolverLib

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
    param([string]$Path, [int]$SelfPid, [string]$ProxyUrl = '', $Listeners = $null, [object[]]$Procs, [object[]]$Windows = $null)
    $o = [ordered]@{ selfPid = $SelfPid; procs = $Procs }
    if ($ProxyUrl) { $o.proxyUrl = $ProxyUrl }
    if ($Listeners) { $o.listeners = $Listeners }
    if ($Windows) { $o.windows = $Windows }
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
    # In-process decision, shaped exactly like the CLI's -DryRun JSON so the
    # assertions below read the same fields either way.
    param([string]$Snapshot, [string]$StateDir, [string]$Cwd = 'D:/work/proj', [string]$SessionId = 'sess-1')
    $snap = Get-Procs -Snapshot $Snapshot
    $d = Get-ResolutionDecision -Snap $snap -StateDir $StateDir -SessionId $SessionId -Cwd $Cwd
    $j = [pscustomobject]@{
        session_id  = $d.session_id
        pid         = $d.candidate_pid
        creation_ft = $d.candidate_ft
        hwnd        = $d.hwnd
        owner_pid   = $d.owner_pid
        owner_ft    = $d.owner_ft
        project     = $d.project
        cwd         = $d.cwd
        degraded    = $d.degraded
        bind_path   = $d.bind_path
        pid_source  = $d.pid_source
        hwnd_source = $d.hwnd_source
    }
    return [pscustomobject]@{ ExitCode = 0; Text = ''; Json = $j }
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

    $snapObj = Get-Procs -Snapshot $snap
    $byPid = @{}
    foreach ($p in $snapObj.List) { $byPid[$p.Pid] = $p }
    $acts = @(Get-GcPlan -Dir $state -TaskNames $null -Snap $snapObj -ByPid $byPid)
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
    $ageSec = [Math]::Abs([int64]$b['updated'] - [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    Assert-True 'updated is a real epoch, not local time dressed as UTC' ($ageSec -lt 300) ('age=' + $ageSec)

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

    # ---------------------------------------------------------------- D1 ----
    Write-Output 'D1  two sessions in two windows never share one hwnd'
    $d = New-Case 'd1'
    $windows = @(
        @{ hwnd = 7001; pid = 3100; 'class' = 'PseudoConsoleWindow'; owner = 7100 }
        @{ hwnd = 7100; pid = 9200; 'class' = 'CASCADIA_HOSTING_WINDOW_CLASS' }
        @{ hwnd = 7002; pid = 3200; 'class' = 'PseudoConsoleWindow'; owner = 7200 }
        @{ hwnd = 7200; pid = 9200; 'class' = 'CASCADIA_HOSTING_WINDOW_CLASS' }
        @{ hwnd = 7300; pid = 9200; 'class' = 'CASCADIA_HOSTING_WINDOW_CLASS' }
    )
    $snapA = Join-Path $d 'a.json'
    Write-Snapshot -Path $snapA -SelfPid 5000 -Windows $windows -Procs @(
        @{ processId = 5000; parentProcessId = 4000; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 4000; parentProcessId = 3100; name = 'bash.exe'; creationFt = '900'; commandLine = 'bash -c hook'; hwnd = 0 }
        @{ processId = 3100; parentProcessId = 9000; name = 'cmd.exe'; creationFt = '850'; commandLine = 'cmd.exe'; hwnd = 0 }
        @{ processId = 3000; parentProcessId = 3100; name = 'node.exe'; creationFt = '700'; commandLine = $CbCmd; hwnd = 0 }
        @{ processId = 9000; parentProcessId = 0; name = 'explorer.exe'; creationFt = '600'; commandLine = 'explorer.exe'; hwnd = 0 }
    )
    $rA = Get-DryRun -Snapshot $snapA -StateDir (Join-Path $d 'state-a') -SessionId 'pane-a'
    if ($rA.Json) {
        Assert-Eq 'pane A resolves its own window' $rA.Json.hwnd 7100
        Assert-Eq 'pane A window comes from the chain' $rA.Json.hwnd_source 'chain'
        Assert-Eq 'pane A is not degraded' $rA.Json.degraded 0
    }

    $snapB = Join-Path $d 'b.json'
    Write-Snapshot -Path $snapB -SelfPid 6000 -Windows $windows -Procs @(
        @{ processId = 6000; parentProcessId = 4500; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 4500; parentProcessId = 3200; name = 'bash.exe'; creationFt = '900'; commandLine = 'bash -c hook'; hwnd = 0 }
        @{ processId = 3200; parentProcessId = 9000; name = 'cmd.exe'; creationFt = '860'; commandLine = 'cmd.exe'; hwnd = 0 }
        @{ processId = 3500; parentProcessId = 3200; name = 'node.exe'; creationFt = '750'; commandLine = $CbCmd; hwnd = 0 }
        @{ processId = 9000; parentProcessId = 0; name = 'explorer.exe'; creationFt = '600'; commandLine = 'explorer.exe'; hwnd = 0 }
    )
    $rB = Get-DryRun -Snapshot $snapB -StateDir (Join-Path $d 'state-b') -SessionId 'pane-b'
    if ($rB.Json -and $rA.Json) {
        Assert-Eq 'pane B resolves its own window' $rB.Json.hwnd 7200
        Assert-True 'the two panes do not collapse onto one lamp' ($rA.Json.hwnd -ne $rB.Json.hwnd)
    }

    # ---------------------------------------------------------------- D2 ----
    Write-Output 'D2  two panes of one window aggregate onto that window'
    $d = New-Case 'd2'
    $ttys = @(
        @{ hwnd = 7003; pid = 3300; 'class' = 'PseudoConsoleWindow'; owner = 7300 }
        @{ hwnd = 7004; pid = 3400; 'class' = 'PseudoConsoleWindow'; owner = 7300 }
        @{ hwnd = 7300; pid = 9200; 'class' = 'CASCADIA_HOSTING_WINDOW_CLASS' }
    )
    $snapC = Join-Path $d 'c.json'
    Write-Snapshot -Path $snapC -SelfPid 5000 -Windows $ttys -Procs @(
        @{ processId = 5000; parentProcessId = 3300; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 3000; parentProcessId = 3300; name = 'node.exe'; creationFt = '700'; commandLine = $CbCmd; hwnd = 0 }
        @{ processId = 3300; parentProcessId = 9000; name = 'cmd.exe'; creationFt = '850'; commandLine = 'cmd.exe'; hwnd = 0 }
        @{ processId = 9000; parentProcessId = 0; name = 'explorer.exe'; creationFt = '600'; commandLine = 'explorer.exe'; hwnd = 0 }
    )
    $snapD = Join-Path $d 'd.json'
    Write-Snapshot -Path $snapD -SelfPid 6000 -Windows $ttys -Procs @(
        @{ processId = 6000; parentProcessId = 3400; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 3600; parentProcessId = 3400; name = 'node.exe'; creationFt = '760'; commandLine = $CbCmd; hwnd = 0 }
        @{ processId = 3400; parentProcessId = 9000; name = 'cmd.exe'; creationFt = '870'; commandLine = 'cmd.exe'; hwnd = 0 }
        @{ processId = 9000; parentProcessId = 0; name = 'explorer.exe'; creationFt = '600'; commandLine = 'explorer.exe'; hwnd = 0 }
    )
    $rC = Get-DryRun -Snapshot $snapC -StateDir (Join-Path $d 'state-c') -SessionId 'tab-1'
    $rD = Get-DryRun -Snapshot $snapD -StateDir (Join-Path $d 'state-d') -SessionId 'tab-2'
    if ($rC.Json -and $rD.Json) {
        Assert-Eq 'tab 1 lands on the shared window' $rC.Json.hwnd 7300
        Assert-Eq 'tab 2 lands on the shared window' $rD.Json.hwnd 7300
    }

    # ---------------------------------------------------------------- D3 ----
    Write-Output 'D3  an unresolved chain keeps the previous window instead of guessing'
    $d = New-Case 'd3'
    $state = Join-Path $d 'state'
    [void](New-Item -ItemType Directory -Path $state -Force)
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Windows @(
        @{ hwnd = 7400; pid = 9200; 'class' = 'CASCADIA_HOSTING_WINDOW_CLASS' }
        @{ hwnd = 7500; pid = 9200; 'class' = 'CASCADIA_HOSTING_WINDOW_CLASS' }
    ) -Procs @(
        @{ processId = 5000; parentProcessId = 4000; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 4000; parentProcessId = 2000; name = 'node.exe'; creationFt = '700'; commandLine = $CbCmd; hwnd = 0 }
    )
    Set-Content -LiteralPath (Join-Path $state 's9.bind') -Value @(
        'session_id=s9', 'pid=2000', 'creation_ft=700', 'hwnd=7400',
        'hwnd_owner_pid=0', 'hwnd_owner_ft=', 'project=proj', 'cwd=D:/proj', 'updated=1', 'degraded=0'
    ) -Encoding UTF8
    $r = Get-DryRun -Snapshot $snap -StateDir $state -SessionId 's9'
    if ($r.Json) {
        Assert-Eq 'the live window is kept' $r.Json.hwnd 7400
        Assert-Eq 'the source is the existing bind' $r.Json.hwnd_source 'bind'
        Assert-Eq 'the session does not degrade' $r.Json.degraded 0
    }
    Assert-True 'no bind file is created outside the dry run' (-not (Test-Path -LiteralPath (Join-Path $state 'probe-x.bind')))

    # ---------------------------------------------------------------- D4 ----
    Write-Output 'D4  a lone terminal window on the desktop is the last resort'
    $d = New-Case 'd4'
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Windows @(
        @{ hwnd = 7600; pid = 9200; 'class' = 'CASCADIA_HOSTING_WINDOW_CLASS' }
    ) -Procs @(
        @{ processId = 5000; parentProcessId = 4000; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 4000; parentProcessId = 0; name = 'explorer.exe'; creationFt = '600'; commandLine = 'explorer.exe'; hwnd = 0 }
    )
    $r = Get-DryRun -Snapshot $snap -StateDir (Join-Path $d 'state-one') -SessionId 'lone'
    if ($r.Json) {
        Assert-Eq 'the only terminal window is used' $r.Json.hwnd 7600
        Assert-Eq 'the source says sole' $r.Json.hwnd_source 'sole'
        Assert-Eq 'a found window is not degraded' $r.Json.degraded 0
    }

    # a second terminal window makes the desktop ambiguous: never guess
    $snap2 = Join-Path $d 'snap2.json'
    Write-Snapshot -Path $snap2 -SelfPid 5000 -Windows @(
        @{ hwnd = 7600; pid = 9200; 'class' = 'CASCADIA_HOSTING_WINDOW_CLASS' }
        @{ hwnd = 7700; pid = 9200; 'class' = 'CASCADIA_HOSTING_WINDOW_CLASS' }
    ) -Procs @(
        @{ processId = 5000; parentProcessId = 4000; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 4000; parentProcessId = 0; name = 'explorer.exe'; creationFt = '600'; commandLine = 'explorer.exe'; hwnd = 0 }
    )
    $r2 = Get-DryRun -Snapshot $snap2 -StateDir (Join-Path $d 'state-two') -SessionId 'lone'
    if ($r2.Json) {
        Assert-Eq 'two terminal windows: no window picked' $r2.Json.hwnd 0
        Assert-Eq 'two terminal windows: source is none' $r2.Json.hwnd_source 'none'
        Assert-Eq 'two terminal windows: degraded' $r2.Json.degraded 1
    }

    # ---------------------------------------------------------------- D4b ---
    Write-Output 'D4b  a console without an owner degrades instead of borrowing a window'
    $d = New-Case 'd4b'
    $snap = Join-Path $d 'snap.json'
    # IDEA / VSCode 的内嵌终端：ConPTY 窗口在链上，但 GW_OWNER 为空。
    # 桌面上那个 WT 窗口是别人的灯，不能借。
    Write-Snapshot -Path $snap -SelfPid 5000 -Windows @(
        @{ hwnd = 531140; pid = 5000; 'class' = 'PseudoConsoleWindow'; visible = $false; w = 0; h = 0; owner = 0 }
        @{ hwnd = 7600; pid = 9200; 'class' = 'CASCADIA_HOSTING_WINDOW_CLASS'; visible = $true; w = 1200; h = 700 }
    ) -Procs @(
        @{ processId = 5000; parentProcessId = 4000; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 4000; parentProcessId = 0; name = 'explorer.exe'; creationFt = '600'; commandLine = 'explorer.exe'; hwnd = 0 }
    )
    $r = Get-DryRun -Snapshot $snap -StateDir (Join-Path $d 'state') -SessionId 'idea'
    if ($r.Json) {
        Assert-Eq 'no foreign window is borrowed' $r.Json.hwnd 0
        Assert-Eq 'the source is none' $r.Json.hwnd_source 'none'
        Assert-Eq 'the lamp degrades' $r.Json.degraded 1
    }

    # ---------------------------------------------------------------- SM1 ----
    # The shell is the shipped seam the hook calls: one run, full output contract.
    Write-Output 'SM1  the shell keeps the dry-run JSON contract'
    $d = New-Case 'sm1'
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Procs @(
        @{ processId = 5000; parentProcessId = 2000; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe'; hwnd = 0 }
        @{ processId = 2000; parentProcessId = 0; name = 'node.exe'; creationFt = '900'; commandLine = $CbCmd; hwnd = 0 }
    )
    $r = Invoke-Resolver @('-Snapshot', $snap, '-StateDir', (Join-Path $d 'state'), '-SessionId', 'smoke', '-DryRun')
    Assert-Eq 'exit code' $r.ExitCode 0
    $j = $null
    try { $j = $r.Text | ConvertFrom-Json } catch { $j = $null }
    Assert-True 'output is JSON' ($null -ne $j) $r.Text
    if ($j) {
        foreach ($k in @('session_id', 'pid', 'creation_ft', 'hwnd', 'owner_pid', 'owner_ft', 'project', 'cwd', 'degraded', 'bind_path', 'pid_source', 'hwnd_source')) {
            Assert-True ('field ' + $k) ($j.PSObject.Properties.Name -contains $k)
        }
    }
    Assert-True 'dry run leaves no state dir behind' (-not (Test-Path -LiteralPath (Join-Path $d 'state')))
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
