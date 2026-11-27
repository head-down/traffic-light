<#
Traffic Light - session/window resolver (effect shell)

Decision logic lives in resolve-lib.ps1; this file only does what a decision
cannot: read the machine's process table, write the bind, register and run the
scheduled task, unregister tasks, delete files, and print the CLI result.

Called by hooks/traffic-light.sh at SessionStart and when a session's bind is
missing, stale, or still degraded.

Design rules (do not simplify away):
  - the proxy port owner is authoritative: the port is bound by this session's
    own CodeBuddy process, so pid reuse and transient child processes cannot
    confuse it. The chain is a fallback for missing port / missing listener /
    unknown owner only.
  - the process chain is walked from ONE CIM snapshot, not one query per level.
  - a parent cannot be older than its child: ascending past an inverted
    creation time would attribute the session to the wrong process.
  - the window comes from the chain, never from ambient focus: the pane's own
    console window (PseudoConsoleWindow under ConPTY, ConsoleWindowClass under
    conhost) belongs to a process on this chain, and its GW_OWNER is the real
    terminal window. The foreground window is never consulted - with several
    terminals it binds every session to whichever window happens to be focused.
  - attach-console is forbidden: attaching to a ConPTY console makes Windows
    spawn a new terminal window, and the chain already names the console.
  - a minimized window reports a 159x27 stub from GetWindowRect; sizes always
    come from GetWindowPlacement's restore rect.
  - every ps1 invocation from hooks must use -NoProfile -ExecutionPolicy Bypass.
  - -Snapshot drives the whole decision from a JSON file (tests, dry runs):
    no real process, window, scheduled task or port is touched.
  - -NoSpawn and -TasksFile are the other two test seams: claim and GC keep
    their real decisions, but no task is registered, no process starts and the
    task list comes from a file.
#>
param(
    [string]$SessionId = "",
    [string]$Cwd = "",
    [string]$StateDir = "",
    [string]$Snapshot = "",
    [string]$TasksFile = "",
    [switch]$GcOnly,
    [switch]$DryRun,
    [switch]$NoSpawn,
    [switch]$NoGc
)

$ErrorActionPreference = 'SilentlyContinue'
$libPath = Join-Path $PSScriptRoot 'resolve-lib.ps1'
if (-not (Test-Path -LiteralPath $libPath)) {
    # 发布包缺文件时宁可报错，也不要静默不写绑定（灯会全灭且无人知道）
    Write-Output '[SignalLight] resolve-lib.ps1 missing next to resolve.ps1'
    exit 2
}
. $libPath

# ---- effects ---------------------------------------------------------------

function Write-Atomic {
    param([string]$Path, [string[]]$Lines)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($tmp, (($Lines -join ([char]10)) + [string][char]10), $utf8)
        if (Test-Path -LiteralPath $Path) {
            try { [System.IO.File]::Replace($tmp, $Path, $null) }
            catch { Move-Item -LiteralPath $tmp -Destination $Path -Force }
        } else {
            try { [System.IO.File]::Move($tmp, $Path) }
            catch { Move-Item -LiteralPath $tmp -Destination $Path -Force }
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Find-Pythonw {
    $c = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if ($c) { return [string]$c.Source }
    return ''
}

function Start-Drawer {
    <#
      Register + run the scheduled task that hosts this anchor's drawer.
      Only hwnd and nonce travel on the command line (schtasks /TR caps at 261
      characters): the drawer derives its state dir from its own location.
      Returns $true only when the task was created and started; a false return
      means "do not write a fake success".
    #>
    param([int64]$Hwnd, [string]$Nonce, [switch]$Degraded)

    $exe = Join-Path $PSScriptRoot 'traffic_light.exe'
    if (Test-Path -LiteralPath $exe) {
        $cmd = '"' + $exe + '" --hwnd ' + $Hwnd + ' --nonce ' + $Nonce
    } else {
        $script = Join-Path $PSScriptRoot 'traffic_light.py'
        if (-not (Test-Path -LiteralPath $script)) { return $false }
        $pythonw = Find-Pythonw
        if (-not $pythonw) { return $false }
        $cmd = '"' + $pythonw + '" "' + $script + '" --hwnd ' + $Hwnd + ' --nonce ' + $Nonce
    }
    if ($Degraded) { $cmd += ' --degraded' }
    if ($cmd.Length -ge 261) { return $false }

    # test seam: decide success from the command alone, register nothing
    if ($NoSpawn) { return $true }

    $task = 'traffic-light-w' + $Hwnd
    & schtasks.exe /Create /TN $task /TR $cmd /SC ONCE /ST 23:59 /F 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }

    # a task created by schtasks inherits "only run on AC power", which silently
    # skips the drawer on battery; clear both flags (best effort, /Create is done)
    try {
        $t = Get-ScheduledTask -TaskName $task -ErrorAction Stop
        $t.Settings.DisallowStartIfOnBatteries = $false
        $t.Settings.StopIfGoingOnBatteries = $false
        Set-ScheduledTask -TaskName $task -Settings $t.Settings -ErrorAction Stop | Out-Null
    } catch {}

    & schtasks.exe /Run /TN $task 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    return $true
}

function Get-TaskNames {
    # $null means "do not touch the task list at all" (injected snapshot without
    # a -TasksFile): a fake snapshot must not unregister a real task.
    param($Snap, [string]$TasksFile)
    if ($TasksFile) { return @(Read-TaskList $TasksFile) }
    if ($Snap.Injected) { return $null }
    $names = @()
    try {
        $names = @(Get-ScheduledTask -TaskName 'traffic-light-*' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.TaskName })
    } catch { $names = @() }
    return $names
}

function Invoke-GcPlan {
    param($Actions, [string]$Dir, [switch]$Unregister)
    foreach ($a in @($Actions)) {
        if (-not $a) { continue }
        if ($a -like 'task:*') {
            if ($Unregister) {
                try { Unregister-ScheduledTask -TaskName $a.Substring(5) -Confirm:$false } catch {}
            }
            continue
        }
        if ($a -like 'file:*') {
            Remove-Item -LiteralPath (Join-Path $Dir $a.Substring(5)) -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-GcResult {
    # 读任务表、算计划、按需执行；-GcOnly 与 SessionStart 共用。
    param($Snap, $ByPid, [string]$Dir, [string]$TasksFile, [switch]$Apply, [switch]$NoSpawn)
    $names = Get-TaskNames -Snap $Snap -TasksFile $TasksFile
    $canUnregister = ($null -ne $names) -and (-not $TasksFile) -and (-not $NoSpawn)
    $plan = @(Get-GcPlan -Dir $Dir -TaskNames $names -Snap $Snap -ByPid $ByPid)
    if ($Apply) { Invoke-GcPlan -Actions $plan -Dir $Dir -Unregister:$canUnregister }
    return $plan
}

# ---- facts -----------------------------------------------------------------

$snap = Get-Procs -Snapshot $Snapshot
$byPid = @{}
foreach ($p in $snap.List) { $byPid[$p.Pid] = $p }

if (-not $StateDir) { $StateDir = Join-Path $PSScriptRoot '.traffic-light-states' }
if (-not $SessionId) { $SessionId = "manual-$PID" }

if ($GcOnly) {
    $plan = @(Get-GcResult -Snap $snap -ByPid $byPid -Dir $StateDir -TasksFile $TasksFile -Apply:(-not $DryRun) -NoSpawn:$NoSpawn)
    if ($DryRun) {
        [pscustomobject]@{ gc = @($plan) } | ConvertTo-Json -Compress -Depth 4
    } else {
        foreach ($a in $plan) { Write-Output ('[SignalLight] gc ' + $a) }
    }
    exit 0
}

if ($DryRun) {
    $d = Get-ResolutionDecision -Snap $snap -StateDir $StateDir -SessionId $SessionId -Cwd $Cwd
    [pscustomobject]@{
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
    } | ConvertTo-Json -Compress -Depth 4
    exit 0
}

# ---- bind ------------------------------------------------------------------

# snapshots never touch real tasks or processes; -NoSpawn is the test seam that
# walks the whole path (Start-Drawer still picks and measures the command) but
# registers and launches nothing.
$canClaim = (-not $snap.Injected) -or $NoSpawn
$d = Get-ResolutionDecision -Snap $snap -StateDir $StateDir -SessionId $SessionId -Cwd $Cwd -Claim:$canClaim

$claim = $d.claim
$spawned = $false
$hwndOut = $d.hwnd
$degradedOut = $d.degraded

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

# /clear: a new session_id for the same pid replaces the old bind, O(1) cleanup
if ($d.pid -ne 0) {
    foreach ($f in @(Get-ChildItem -LiteralPath $StateDir -Filter '*.bind' -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -eq ($SessionId + '.bind')) { continue }
        $b = Read-BindFile $f.FullName
        if ([string]$b['pid'] -eq [string]$d.pid) { Remove-Item -LiteralPath $f.FullName -Force }
    }
}

Write-Atomic -Path $d.bind_path -Lines $d.bind_lines

if ($claim -eq 'owner') {
    $spawned = Start-Drawer -Hwnd $d.hwnd -Nonce $d.nonce -Degraded:($d.hwnd -eq 0)
    if (-not $spawned) {
        # never write a fake success: drop our anchor (only if it is still ours)
        # and rewrite the bind as degraded so the next prompt retries. No
        # recursive w0 claim from here - that is the degraded lamp's own claim
        # path, not a fallback for a failed window lamp.
        $cur = Read-BindFile $d.anchor
        if (-not $cur.ContainsKey('nonce') -or [string]$cur['nonce'] -eq $d.nonce) {
            Remove-Item -LiteralPath $d.anchor -Force -ErrorAction SilentlyContinue
        }
        $claim = 'failed'
        $hwndOut = 0
        $degradedOut = 1
        Write-Atomic -Path $d.bind_path -Lines (Get-BindLines $d.session_id $d.pid $d.creation_ft 0 0 '' $d.project $d.cwd $d.now 1 'none')
    }
}

# GC belongs to install and SessionStart only; prompt-triggered re-resolves
# pass -NoGc so they never sweep another session's state directory.
if (-not $NoGc) {
    Get-GcResult -Snap $snap -ByPid $byPid -Dir $StateDir -TasksFile $TasksFile -Apply -NoSpawn:$NoSpawn | Out-Null
}

if ($NoSpawn) {
    [pscustomobject]@{
        session_id  = $d.session_id
        pid         = $d.pid
        creation_ft = $d.creation_ft
        hwnd        = $hwndOut
        owner_pid   = $d.owner_pid
        owner_ft    = $d.owner_ft
        project     = $d.project
        cwd         = $d.cwd
        degraded    = $degradedOut
        bind_path   = $d.bind_path
        claim       = $claim
        nonce       = $d.nonce
        anchor      = $d.anchor
        task        = $d.task
        spawned     = $spawned
        hwnd_source = $d.hwnd_source
    } | ConvertTo-Json -Compress -Depth 4
    exit 0
}

Write-Output ('[SignalLight] bind sid=' + $d.session_id + ' pid=' + $d.pid + ' hwnd=' + $hwndOut + ' hwnd_src=' + $d.hwnd_source + ' degraded=' + $degradedOut + ' project=' + $d.project + ' claim=' + $claim + ' drawer=' + $spawned)
exit 0
