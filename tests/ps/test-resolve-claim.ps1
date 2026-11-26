<#
T04 claim tests - anchor contention, drawer launch seam, GC rules.

Run:
    powershell -NoProfile -ExecutionPolicy Bypass -File tests/ps/test-resolve-claim.ps1

Exit code 0 means every assertion passed. Every case feeds a JSON process
snapshot (hwnd included) and a throw-away state directory: no real window,
process or scheduled task is created. Real scheduled tasks are only *read*
(Get-ScheduledTask) to prove -NoSpawn launches nothing.
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
$script:TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('tl-t04-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $script:TmpRoot -Force)

function Invoke-Resolver {
    param([string[]]$ArgList)
    $text = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $Resolver @ArgList 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Text     = (($text | ForEach-Object { [string]$_ }) -join ([char]10))
    }
}

function Invoke-ResolveAt {
    param([string]$Path, [string[]]$ArgList)
    $text = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $Path @ArgList 2>&1
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
    param([string]$Path, [int]$SelfPid, [int64]$Hwnd = 0)
    $o = [ordered]@{
        selfPid = $SelfPid
        procs   = @(
            @{ processId = $SelfPid; parentProcessId = 2000; name = 'powershell.exe'; creationFt = '1000'; commandLine = 'powershell.exe -File resolve.ps1'; hwnd = 0 }
            @{ processId = 2000; parentProcessId = 0; name = 'node.exe'; creationFt = '900'; commandLine = $CbCmd; hwnd = $Hwnd }
        )
    }
    ([pscustomobject]$o | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-DirState {
    param([string]$Dir)
    $items = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $items += ($f.Name + '|' + $f.Length + '|' + $f.LastWriteTimeUtc.Ticks)
    }
    return ($items -join ([char]10))
}

function Read-Ini {
    param([string]$Path)
    $h = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -match '^([^=]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] }
        }
    }
    return $h
}

function Get-NoSpawn {
    param([string]$Snapshot, [string]$StateDir, [string]$SessionId = 'sess-1')
    $r = Invoke-Resolver @('-Snapshot', $Snapshot, '-StateDir', $StateDir, '-Cwd', 'D:/work/proj', '-SessionId', $SessionId, '-NoSpawn')
    $j = $null
    try { $j = $r.Text | ConvertFrom-Json } catch { $j = $null }
    return [pscustomobject]@{ ExitCode = $r.ExitCode; Text = $r.Text; Json = $j }
}

function Invoke-Tests {

    # ---------------------------------------------------------------- D1 ----
    Write-Output 'D1  one anchor, two claimants: exactly one owner'
    $d = New-Case 'd1'
    $state = Join-Path $d 'state'
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Hwnd 4242

    # the primitive the resolver relies on: CreateNew is atomic
    $prim = Join-Path $d 'primitive.win'
    $fh = [System.IO.File]::Open($prim, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $blocked = $false
    try {
        $fh2 = [System.IO.File]::Open($prim, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $fh2.Dispose()
    } catch { $blocked = $true }
    $fh.Dispose()
    Assert-True 'CreateNew refuses the second opener' $blocked

    $r1 = Get-NoSpawn -Snapshot $snap -StateDir $state -SessionId 's1'
    Assert-Eq 'first run exits 0' $r1.ExitCode 0
    Assert-True 'first run emits JSON' ($null -ne $r1.Json) $r1.Text
    if ($r1.Json) {
        Assert-Eq 'first run owns the window' $r1.Json.claim 'owner'
        Assert-True 'owner has a nonce' ([bool]($r1.Json.nonce -match '^[0-9a-f]{32}$')) $r1.Text
        Assert-Eq 'anchor is w<hwnd>.win' (Split-Path -Leaf $r1.Json.anchor) 'w4242.win'
        Assert-Eq 'task is traffic-light-w<hwnd>' $r1.Json.task 'traffic-light-w4242'
        Assert-True 'anchor exists' (Test-Path -LiteralPath (Join-Path $state 'w4242.win'))
        $a = Read-Ini (Join-Path $state 'w4242.win')
        Assert-Eq 'anchor carries the nonce' $a['nonce'] $r1.Json.nonce
        Assert-Eq 'anchor carries the hwnd' $a['hwnd'] '4242'
        Assert-Eq 'drawer_pid starts at 0' $a['drawer_pid'] '0'
        $b = Read-Ini (Join-Path $state 's1.bind')
        Assert-Eq 'bind is not degraded once a window is owned' $b['degraded'] '0'
        Assert-Eq 'bind carries the hwnd' $b['hwnd'] '4242'
    }

    $r2 = Get-NoSpawn -Snapshot $snap -StateDir $state -SessionId 's2'
    Assert-Eq 'second run exits 0' $r2.ExitCode 0
    if ($r2.Json -and $r1.Json) {
        Assert-Eq 'second run rides the lamp' $r2.Json.claim 'busy'
        Assert-Eq 'busy run reports no nonce' $r2.Json.nonce ''
        $a2 = Read-Ini (Join-Path $state 'w4242.win')
        Assert-Eq 'busy run does not replace the owner nonce' $a2['nonce'] $r1.Json.nonce
    }

    # ---------------------------------------------------------------- D2 ----
    Write-Output 'D2  a stale anchor is re-taken, not inherited'
    $d = New-Case 'd2'
    $state = Join-Path $d 'state'
    [void](New-Item -ItemType Directory -Path $state -Force)
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Hwnd 4242
    $anchor = Join-Path $state 'w4242.win'
    Set-Content -LiteralPath $anchor -Value @('nonce=deadbeef', 'drawer_pid=999', 'hwnd=4242', 'owner_pid=0', 'owner_ft=', 'started=1') -Encoding UTF8
    (Get-Item -LiteralPath $anchor).LastWriteTime = (Get-Date).AddSeconds(-30)

    $r = Get-NoSpawn -Snapshot $snap -StateDir $state -SessionId 's3'
    Assert-Eq 'stale claim run exits 0' $r.ExitCode 0
    if ($r.Json) {
        Assert-Eq 'stale anchor is re-taken' $r.Json.claim 'owner'
        Assert-True 'a fresh nonce replaces the dead one' ([bool]($r.Json.nonce -and $r.Json.nonce -ne 'deadbeef')) $r.Text
        $a = Read-Ini $anchor
        Assert-Eq 'anchor file holds the new nonce' $a['nonce'] $r.Json.nonce
    }

    # ---------------------------------------------------------------- D3 ----
    Write-Output 'D3  hwnd=0 degraded fallback claims the machine-wide lamp'
    $d = New-Case 'd3'
    $state = Join-Path $d 'state'
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Hwnd 0

    $r = Get-NoSpawn -Snapshot $snap -StateDir $state -SessionId 's4'
    Assert-Eq 'degraded claim run exits 0' $r.ExitCode 0
    if ($r.Json) {
        Assert-Eq 'degraded lamp is claimed' $r.Json.claim 'owner'
        Assert-Eq 'degraded anchor is w0.win' (Split-Path -Leaf $r.Json.anchor) 'w0.win'
        Assert-Eq 'degraded task is traffic-light-w0' $r.Json.task 'traffic-light-w0'
        Assert-Eq 'bind stays degraded' $r.Json.degraded 1
        Assert-Eq 'bind hwnd stays 0' $r.Json.hwnd 0
        Assert-True 'w0 anchor exists' (Test-Path -LiteralPath (Join-Path $state 'w0.win'))
    }

    $r2 = Get-NoSpawn -Snapshot $snap -StateDir $state -SessionId 's5'
    if ($r2.Json) { Assert-Eq 'second degraded session rides the same lamp' $r2.Json.claim 'busy' }

    # ---------------------------------------------------------------- D4 ----
    Write-Output 'D4  -NoSpawn never creates a real scheduled task'
    $d = New-Case 'd4'
    $state = Join-Path $d 'state'
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Hwnd 987654321
    $r = Get-NoSpawn -Snapshot $snap -StateDir $state -SessionId 's6'
    Assert-Eq 'no-spawn claim still owns' $r.Json.claim 'owner'
    $t = Get-ScheduledTask -TaskName 'traffic-light-w987654321' -ErrorAction SilentlyContinue
    Assert-True 'the task was not registered' ($null -eq $t)

    # ---------------------------------------------------------------- D5 ----
    Write-Output 'D5  a failed launch drops the anchor and degrades the bind'
    $d = New-Case 'd5'
    $state = Join-Path $d 'state'
    $tool = Join-Path $d 'tool'
    [void](New-Item -ItemType Directory -Path $tool -Force)
    # a resolver copy with no traffic_light.py/.exe beside it: Start-Drawer cannot
    # build a command, so the launch must fail before anything is registered
    Copy-Item -LiteralPath $Resolver -Destination (Join-Path $tool 'resolve.ps1')
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Hwnd 987654321
    $r = Invoke-ResolveAt -Path (Join-Path $tool 'resolve.ps1') -ArgList @('-Snapshot', $snap, '-StateDir', $state, '-Cwd', 'D:/work/proj', '-SessionId', 's8', '-NoSpawn')
    $j = $null
    try { $j = $r.Text | ConvertFrom-Json } catch { $j = $null }
    Assert-Eq 'failed launch still exits 0' $r.ExitCode 0
    Assert-True 'failed launch emits JSON' ($null -ne $j) $r.Text
    if ($j) {
        Assert-Eq 'claim reports the failure' $j.claim 'failed'
        Assert-Eq 'nothing was spawned' $j.spawned $false
        Assert-Eq 'hwnd falls back to 0' $j.hwnd 0
        Assert-Eq 'degraded is flagged' $j.degraded 1
        Assert-True 'the claimed anchor was dropped' (-not (Test-Path -LiteralPath (Join-Path $state 'w987654321.win')))
        Assert-True 'no recursive w0 claim' (-not (Test-Path -LiteralPath (Join-Path $state 'w0.win')))
        $b = Read-Ini (Join-Path $state 's8.bind')
        Assert-Eq 'bind hwnd is 0' $b['hwnd'] '0'
        Assert-Eq 'bind is degraded' $b['degraded'] '1'
        Assert-Eq 'identity survives the failure' $b['pid'] '2000'
    }

    # ---------------------------------------------------------------- E1 ----
    Write-Output 'E1  GC: fresh-anchored tasks survive, every legacy artefact goes'
    $d = New-Case 'e1'
    $state = Join-Path $d 'state'
    [void](New-Item -ItemType Directory -Path $state -Force)
    $snap = Join-Path $d 'snap.json'
    Write-Snapshot -Path $snap -SelfPid 5000 -Hwnd 0

    $fresh = Join-Path $state 'w111.win'
    Set-Content -LiteralPath $fresh -Value @('nonce=aaa', 'drawer_pid=1', 'hwnd=111') -Encoding UTF8
    $alsoFresh = Join-Path $state 'w555.win'
    Set-Content -LiteralPath $alsoFresh -Value @('nonce=e', 'drawer_pid=5', 'hwnd=555') -Encoding UTF8
    $stale = Join-Path $state 'w222.win'
    Set-Content -LiteralPath $stale -Value @('nonce=bbb', 'drawer_pid=2', 'hwnd=222') -Encoding UTF8
    (Get-Item -LiteralPath $stale).LastWriteTime = (Get-Date).AddSeconds(-60)
    $orphan = Join-Path $state 'w444.win'
    Set-Content -LiteralPath $orphan -Value @('nonce=ddd', 'drawer_pid=4', 'hwnd=444') -Encoding UTF8
    (Get-Item -LiteralPath $orphan).LastWriteTime = (Get-Date).AddSeconds(-60)

    Set-Content -LiteralPath (Join-Path $state '555.bind') -Value @('session_id=live', 'pid=2000', 'creation_ft=900', 'hwnd=111') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $state '666.bind') -Value @('session_id=dead', 'pid=3000', 'creation_ft=1', 'hwnd=111') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $state '777.bind') -Value @('session_id=reborn', 'pid=2000', 'creation_ft=111', 'hwnd=111') -Encoding UTF8

    Set-Content -LiteralPath (Join-Path $state '12345.state') -Value @('thinking', 'D:/work/proj', '900') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $state '5000.state') -Value @('thinking', 'D:/work/proj', '1000') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $state '2000.state') -Value @('running', 'D:/work/proj', '111') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $state 'legacy.state') -Value @('idle', 'D:/work/proj') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $state 'proj.pid') -Value '999' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $state 'proj.cbpid') -Value '999' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $state 'proj.hwnd') -Value '4242' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $state 'daemon.log') -Value 'not ours to judge' -Encoding UTF8

    $tasksFile = Join-Path $d 'tasks.json'
    @(
        'traffic-light-w111'
        'traffic-light-w222'
        'traffic-light-w333'
        'traffic-light-proj'
        @{ taskName = 'traffic-light-w555' }
    ) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tasksFile -Encoding UTF8

    $before = Get-DirState $state
    $r = Invoke-Resolver @('-Snapshot', $snap, '-StateDir', $state, '-GcOnly', '-DryRun', '-TasksFile', $tasksFile)
    $acts = @()
    try { $acts = @(($r.Text | ConvertFrom-Json).gc) } catch { $acts = @() }
    $joined = $acts -join ','
    Assert-Eq 'dry-run exit code' $r.ExitCode 0

    Assert-True 'task backed by a fresh anchor survives' (-not ($acts -contains 'task:traffic-light-w111')) $joined
    Assert-True 'task backed by a fresh anchor (object form) survives' (-not ($acts -contains 'task:traffic-light-w555')) $joined
    Assert-True 'task whose anchor is stale is collected' ($acts -contains 'task:traffic-light-w222') $joined
    Assert-True 'task without an anchor is collected' ($acts -contains 'task:traffic-light-w333') $joined
    Assert-True 'legacy project task is collected' ($acts -contains 'task:traffic-light-proj') $joined

    Assert-True '.pid is collected' ($acts -contains 'file:proj.pid') $joined
    Assert-True '.cbpid is collected' ($acts -contains 'file:proj.cbpid') $joined
    Assert-True '.hwnd is collected' ($acts -contains 'file:proj.hwnd') $joined
    Assert-True 'legacy .state key is collected' ($acts -contains 'file:legacy.state') $joined
    Assert-True 'bind with a dead pid is collected' ($acts -contains 'file:666.bind') $joined
    Assert-True 'bind with a reused pid is collected' ($acts -contains 'file:777.bind') $joined
    Assert-True 'stale anchor file is collected' ($acts -contains 'file:w222.win') $joined
    Assert-True 'orphan anchor without a task is collected' ($acts -contains 'file:w444.win') $joined

    Assert-True 'live bind is kept' (-not ($acts -contains 'file:555.bind')) $joined
    Assert-True 'state of a dead pid is collected' ($acts -contains 'file:12345.state') $joined
    Assert-True 'state of a reused pid is collected' ($acts -contains 'file:2000.state') $joined
    Assert-True 'live state with a matching creation_ft is kept' (-not ($acts -contains 'file:5000.state')) $joined
    Assert-True 'fresh anchor is kept' (-not ($acts -contains 'file:w111.win')) $joined
    Assert-True 'unrelated file is kept' (-not ($acts -contains 'file:daemon.log')) $joined

    Assert-Eq 'dry-run writes nothing' (Get-DirState $state) $before
    Assert-True 'dry-run keeps the collected files' (Test-Path -LiteralPath (Join-Path $state 'proj.pid'))

    $r = Invoke-Resolver @('-Snapshot', $snap, '-StateDir', $state, '-GcOnly', '-TasksFile', $tasksFile)
    Assert-Eq 'apply exit code' $r.ExitCode 0
    foreach ($gone in @('proj.pid', 'proj.cbpid', 'proj.hwnd', 'legacy.state', '12345.state', '2000.state', '666.bind', '777.bind', 'w222.win', 'w444.win')) {
        Assert-True ('apply removes ' + $gone) (-not (Test-Path -LiteralPath (Join-Path $state $gone)))
    }
    foreach ($kept in @('555.bind', '5000.state', 'w111.win', 'w555.win', 'daemon.log')) {
        Assert-True ('apply keeps ' + $kept) (Test-Path -LiteralPath (Join-Path $state $kept))
    }

    # second pass: the task list the scheduler would show after the first GC
    '["traffic-light-w111","traffic-light-w555"]' | Set-Content -LiteralPath $tasksFile -Encoding UTF8
    $r = Invoke-Resolver @('-Snapshot', $snap, '-StateDir', $state, '-GcOnly', '-DryRun', '-TasksFile', $tasksFile)
    $acts2 = @()
    try { $acts2 = @(($r.Text | ConvertFrom-Json).gc) } catch { $acts2 = @() }
    Assert-Eq 'GC is idempotent' ($acts2 -join ',') ''
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
