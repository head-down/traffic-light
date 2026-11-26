<#
.SYNOPSIS
    Read-only inventory of this machine's traffic-light state: scheduled tasks,
    anchors, binds and state files.

.DESCRIPTION
    Used by the manual acceptance checks A/B/D. Reads only: it never kills a
    process, writes a file, or registers/unregisters a scheduled task. The exit
    code is always 0 (an inventory is not an assertion); judge by the STATUS
    column.

    Each row: KIND NAME STATUS DETAIL
      KIND    task | anchor | bind | state
      STATUS  PASS | FAIL | EMPTY
      EMPTY   nothing of that kind exists (clean machine, or every lamp exited)
      FAIL    the object exists but is inconsistent (orphan task, stale anchor,
              dead bind, orphan state)

    Verdicts:
      task    traffic-light-w<digits> whose anchor refreshed within 3s -> PASS;
              any other name, or a missing/stale anchor -> FAIL
      anchor  w<hwnd>.win refreshed within 3s -> PASS (the anchor is the
              heartbeat, fresh means the drawer is alive)
      bind    pid alive and creation_ft matches -> PASS; gone or PID reused -> FAIL
      state   <pid>.state whose pid is alive and creation_ft matches -> PASS

.PARAMETER StateDir
    State directory. Defaults to <repo>/.traffic-light-states, derived from this
    script's location.

.PARAMETER TasksFile
    Test seam: read task names from JSON (an array, or { "tasks": [...] })
    instead of querying the real scheduler. Entries may be strings or objects
    with taskName. A missing file means "no tasks".

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests/manual/acceptance.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests/manual/acceptance.ps1 -StateDir D:/tmp/states
#>
[CmdletBinding()]
param(
    [string]$StateDir = '',
    [string]$TasksFile = ''
)

$ErrorActionPreference = 'SilentlyContinue'
$FRESH_MS = 3000   # anchor heartbeats every 1s; refreshed within 3s means alive

if (-not $StateDir) {
    # tests/manual/acceptance.ps1 -> two levels up is the repo root
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $StateDir = Join-Path $repoRoot '.traffic-light-states'
}

$script:Pass = 0
$script:Fail = 0

function Write-Row {
    param([string]$Kind, [string]$Name, [string]$Status, [string]$Detail)
    Write-Output ('{0,-6} {1,-44} {2,-5} {3}' -f $Kind, $Name, $Status, $Detail)
}

function Set-Row {
    param([string]$Kind, [string]$Name, [string]$Status, [string]$Detail)
    if ($Status -eq 'PASS') { $script:Pass++ }
    elseif ($Status -eq 'FAIL') { $script:Fail++ }
    Write-Row $Kind $Name $Status $Detail
}

function Read-Fields {
    param([string]$Path)
    $fields = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $fields }
    foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        if ($line -match '^([^=]+)=(.*)$') { $fields[$Matches[1]] = $Matches[2] }
    }
    return $fields
}

function ConvertTo-Int {
    param($Value)
    if ($null -eq $Value) { return 0 }
    $text = ([string]$Value).Trim()
    if ($text -match '^-?\d+$') { return [int]$text }
    return 0
}

function Get-FtOf {
    param($Process)
    if ($null -eq $Process) { return '' }
    try { return [string]$Process.StartTime.ToFileTime() } catch { return '' }
}

function Read-TaskNames {
    param([string]$Path)
    $names = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $names }
    try { $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $names }
    $items = $json
    if ($null -ne $json -and -not ($json -is [System.Array]) -and
        ($json.PSObject.Properties.Name -contains 'tasks')) { $items = $json.tasks }
    foreach ($item in @($items)) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) { $names += [string]$item; continue }
        foreach ($key in @('taskName', 'TaskName', 'name')) {
            if ($item.PSObject.Properties.Name -contains $key) { $names += [string]$item.$key; break }
        }
    }
    return $names
}

Write-Output ('{0,-6} {1,-44} {2,-5} {3}' -f 'KIND', 'NAME', 'STATUS', 'DETAIL')
Write-Output ('state dir: ' + $StateDir)

# ---- 1. scheduled tasks ----------------------------------------------------

$tasks = @()
if ($TasksFile) {
    $tasks = @(Read-TaskNames $TasksFile)
} else {
    try {
        $tasks = @(Get-ScheduledTask -TaskName 'traffic-light-*' -ErrorAction Stop |
            ForEach-Object { [string]$_.TaskName })
    } catch { $tasks = @() }
}

$taskCount = 0
if ($tasks.Count -eq 0) {
    Set-Row 'task' '(none)' 'EMPTY' 'no traffic-light-* scheduled task'
} else {
    foreach ($name in $tasks) {
        if (-not $name) { continue }
        $taskCount++
        if ($name -notmatch '^traffic-light-w(\d+)$') {
            Set-Row 'task' $name 'FAIL' 'legacy task (not traffic-light-w<digits>), GC should remove it'
            continue
        }
        $hwnd = $Matches[1]
        $anchor = Join-Path $StateDir ('w' + $hwnd + '.win')
        if (-not (Test-Path -LiteralPath $anchor)) {
            Set-Row 'task' $name 'FAIL' ('anchor w' + $hwnd + '.win missing -> orphan task')
            continue
        }
        $age = [int](((Get-Date) - (Get-Item -LiteralPath $anchor).LastWriteTime).TotalMilliseconds)
        if ($age -le $FRESH_MS) {
            Set-Row 'task' $name 'PASS' ('anchor fresh age=' + $age + 'ms')
        } else {
            Set-Row 'task' $name 'FAIL' ('anchor stale age=' + $age + 'ms -> drawer dead, waiting for GC')
        }
    }
}

# ---- 2. anchors ------------------------------------------------------------

$anchors = @()
if (Test-Path -LiteralPath $StateDir) {
    $anchors = @(Get-ChildItem -LiteralPath $StateDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^w\d+\.win$' })
}

$anchorCount = 0
if ($anchors.Count -eq 0) {
    Set-Row 'anchor' '(none)' 'EMPTY' 'no w<hwnd>.win anchor'
} else {
    foreach ($item in $anchors) {
        $anchorCount++
        $nameHwnd = 0
        if ($item.Name -match '^w(\d+)\.win$') { $nameHwnd = [int64]$Matches[1] }
        $fields = Read-Fields $item.FullName
        $age = [int](((Get-Date) - $item.LastWriteTime).TotalMilliseconds)
        $drawerPid = ConvertTo-Int $fields['drawer_pid']
        $nonce = [string]$fields['nonce']
        $shortNonce = if ($nonce.Length -gt 8) { $nonce.Substring(0, 8) } else { $nonce }
        $detail = 'hwnd=' + $nameHwnd + ' age=' + $age + 'ms drawer=' + $drawerPid + ' nonce=' + $shortNonce
        if ($fields.Count -eq 0) {
            Set-Row 'anchor' $item.Name 'FAIL' 'anchor unreadable (empty file)'
            continue
        }
        if ((ConvertTo-Int $fields['hwnd']) -ne $nameHwnd) {
            Set-Row 'anchor' $item.Name 'FAIL' ('anchor hwnd=' + $fields['hwnd'] + ' does not match filename')
            continue
        }
        if ($age -le $FRESH_MS) {
            Set-Row 'anchor' $item.Name 'PASS' $detail
        } else {
            Set-Row 'anchor' $item.Name 'FAIL' ($detail + ' -> heartbeat stopped')
        }
    }
}

# ---- 3. binds --------------------------------------------------------------

$binds = @()
if (Test-Path -LiteralPath $StateDir) {
    $binds = @(Get-ChildItem -LiteralPath $StateDir -Filter '*.bind' -File -ErrorAction SilentlyContinue)
}

$bindCount = 0
if ($binds.Count -eq 0) {
    Set-Row 'bind' '(none)' 'EMPTY' 'no <session_id>.bind binding'
} else {
    foreach ($item in $binds) {
        $bindCount++
        $fields = Read-Fields $item.FullName
        $procId = ConvertTo-Int $fields['pid']
        $hwnd = if ($fields['hwnd']) { [string]$fields['hwnd'] } else { '0' }
        $project = [string]$fields['project']
        $degraded = [string]$fields['degraded']
        if ($procId -le 0) {
            # identity unknown is valid when the bind still names a lamp
            $hasTarget = ($hwnd -match '^\d+$' -and [int64]$hwnd -gt 0) -or $degraded -eq '1'
            $detail = 'pid unknown hwnd=' + $hwnd + ' project=' + $project + ' degraded=' + $degraded
            if ($hasTarget) { Set-Row 'bind' $item.Name 'PASS' $detail }
            else { Set-Row 'bind' $item.Name 'FAIL' 'pid missing and no hwnd/degraded target (corrupt bind)' }
            continue
        }
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $proc) {
            Set-Row 'bind' $item.Name 'FAIL' ('pid=' + $procId + ' gone -> dead bind (waiting for GC)')
            continue
        }
        $expectedFt = [string]$fields['creation_ft']
        $actualFt = Get-FtOf $proc
        if ($expectedFt -and $actualFt -and $expectedFt -ne $actualFt) {
            Set-Row 'bind' $item.Name 'FAIL' ('pid=' + $procId + ' creation_ft mismatch -> PID reused')
            continue
        }
        $detail = 'pid=' + $procId + ' hwnd=' + $hwnd + ' project=' + $project + ' degraded=' + $degraded
        if ($degraded -eq '1') { $detail += ' (degraded lamp)' }
        Set-Row 'bind' $item.Name 'PASS' $detail
    }
}

# ---- 4. states -------------------------------------------------------------

$states = @()
if (Test-Path -LiteralPath $StateDir) {
    $states = @(Get-ChildItem -LiteralPath $StateDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.state$' })
}

$stateCount = 0
if ($states.Count -eq 0) {
    Set-Row 'state' '(none)' 'EMPTY' 'no <pid>.state state file'
} else {
    foreach ($item in $states) {
        $stateCount++
        $procId = ConvertTo-Int $item.BaseName
        $lines = @(Get-Content -LiteralPath $item.FullName -ErrorAction SilentlyContinue)
        $state = if ($lines.Count -gt 0) { ([string]$lines[0]).Trim() } else { '' }
        $ft = if ($lines.Count -gt 2) { ([string]$lines[2]).Trim() } else { '' }
        $ageSec = [int](((Get-Date) - $item.LastWriteTime).TotalSeconds)
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $proc) {
            Set-Row 'state' $item.Name 'FAIL' ('pid=' + $procId + ' gone -> orphan state')
            continue
        }
        $actualFt = Get-FtOf $proc
        if ($ft -and $actualFt -and $ft -ne $actualFt) {
            Set-Row 'state' $item.Name 'FAIL' ('pid=' + $procId + ' creation_ft mismatch -> PID reused')
            continue
        }
        Set-Row 'state' $item.Name 'PASS' ('state=' + $state + ' age=' + $ageSec + 's')
    }
}

Write-Output ('summary task=' + $taskCount + ' anchor=' + $anchorCount + ' bind=' + $bindCount +
    ' state=' + $stateCount + ' pass=' + $script:Pass + ' fail=' + $script:Fail)
exit 0
