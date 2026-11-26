<#
Traffic Light - session/window resolver (single source of truth for hwnd)

Called by bind.sh at SessionStart and when a session's bind is missing.
It does four things, in this order:
  1. identify this session's CodeBuddy process (pid + creation time)
  2. resolve that process's terminal window (attach-console -> GW_OWNER)
  3. write <session_id>.bind  (identity immutable, hwnd refreshable)
  4. claim <hwnd>.win and spawn one drawer per window, then run GC

Design rules (do not simplify away):
  - attach-console happens ONLY here, never in the drawer: the drawer has no
    console and attaching would give it one.
  - the process chain is walked from ONE CIM snapshot, not one query per level.
  - every ps1 invocation from hooks must use -NoProfile -ExecutionPolicy Bypass.
  - degraded mode is never silent: hwnd=0 + degraded=1 is still a valid bind.
#>
param(
    [string]$SessionId = "",
    [string]$Cwd = "",
    [string]$Project = "",
    [string]$StateDir = "",
    [string]$Snapshot = "",
    [switch]$GcOnly,
    [switch]$DryRun
)

$ErrorActionPreference = 'SilentlyContinue'
$TICK_GRACE_MS = 3000     # anchor younger than this = drawer alive
$ANCHOR_STALE_MS = 10000  # anchor older than this = orphan, remove

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class TLResolve {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
}
"@

function Get-Win([IntPtr]$h) {
    if ($h -eq [IntPtr]::Zero) { return $null }
    $cls = New-Object System.Text.StringBuilder 256
    [TLResolve]::GetClassName($h, $cls, 256) | Out-Null
    $rect = New-Object 'TLResolve+RECT'
    [TLResolve]::GetWindowRect($h, [ref]$rect) | Out-Null
    [pscustomobject]@{
        Hwnd    = $h
        Class   = $cls.ToString()
        Visible = [TLResolve]::IsWindowVisible($h)
        W       = ($rect.R - $rect.L)
        H       = ($rect.B - $rect.T)
    }
}

function Test-WinBindable([IntPtr]$h) {
    $w = Get-Win $h
    if (-not $w) { return $false }
    if (-not [TLResolve]::IsWindow($h)) { return $false }
    if (-not $w.Visible) { return $false }
    if ($w.W -lt 50 -or $w.H -lt 50) { return $false }
    return $true
}

function Get-ConsoleHwnd([int]$procId) {
    [TLResolve]::FreeConsole() | Out-Null
    if (-not [TLResolve]::AttachConsole([uint32]$procId)) { return [IntPtr]::Zero }
    $h = [TLResolve]::GetConsoleWindow()
    [TLResolve]::FreeConsole() | Out-Null
    return $h
}

function Resolve-RealWindow([IntPtr]$h) {
    if ($h -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
    $w = Get-Win $h
    $pseudo = ($w.Class -match 'PseudoConsole') -or (($w.W * $w.H) -le 0)
    if ($pseudo) {
        $owner = [TLResolve]::GetWindow($h, 4)   # GW_OWNER
        if ((Test-WinBindable $owner)) { return $owner }
    }
    if (Test-WinBindable $h) { return $h }
    return [IntPtr]::Zero
}

function Get-Procs {
    if ($Snapshot) {
        $j = Get-Content -LiteralPath $Snapshot -Raw | ConvertFrom-Json
        $list = @()
        foreach ($p in $j.procs) {
            $h = 0
            if ($p.hwnd) { $h = [long]$p.hwnd }
            $list += [pscustomobject]@{
                Pid = [int]$p.processId; PPid = [int]$p.parentProcessId; Name = [string]$p.name
                Ft = [string]$p.creationFt; Cmd = [string]$p.commandLine; Hwnd = $h
            }
        }
        return @{ Self = [int]$j.selfPid; List = $list }
    }
    $raw = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, CreationDate, CommandLine
    $list = @()
    foreach ($p in $raw) {
        $ft = ''
        try {
            if ($p.CreationDate -is [datetime]) { $ft = [string]$p.CreationDate.ToFileTime() }
            else { $ft = [string]([datetime]$p.CreationDate).ToFileTime() }
        } catch { $ft = '' }
        $list += [pscustomobject]@{
            Pid = [int]$p.ProcessId; PPid = [int]$p.ParentProcessId; Name = [string]$p.Name
            Ft = $ft; Cmd = [string]$p.CommandLine; Hwnd = 0
        }
    }
    return @{ Self = $PID; List = $list }
}

# ---- facts ----------------------------------------------------------------
$snap = Get-Procs
$byPid = @{}
foreach ($p in $snap.List) { $byPid[$p.Pid] = $p }

$chain = @()
$cur = [int]$snap.Self
$childFt = $null
for ($i = 0; $i -lt 12 -and $cur -gt 0; $i++) {
    if (-not $byPid.ContainsKey($cur)) { break }
    $p = $byPid[$cur]
    # a parent cannot have been created after its child
    if ($childFt -and $p.Ft -and $p.Ft.Length -eq $childFt.Length -and [decimal]$p.Ft -gt [decimal]$childFt) { break }
    $chain += $p
    $childFt = $p.Ft
    $cur = [int]$p.PPid
}

$cb = $null
foreach ($p in $chain) {
    if ($p.Name -match '^node\.exe$' -and $p.Cmd -match 'codebuddy' -and $p.Cmd -notmatch 'windows-child-process-containment|conpty|node-pty') {
        $cb = $p; break
    }
}

$cbPid = 0; $cbFt = ''
if ($cb) { $cbPid = $cb.Pid; $cbFt = $cb.Ft }

# hwnd: try the codebuddy process, then walk the rest of the chain upward
$win = [IntPtr]::Zero
$winPid = 0
if (-not $GcOnly) {
    $startIdx = 0
    if ($cb) {
        for ($i = 0; $i -lt $chain.Count; $i++) { if ($chain[$i].Pid -eq $cb.Pid) { $startIdx = $i; break } }
    }
    for ($i = $startIdx; $i -lt $chain.Count -and $win -eq [IntPtr]::Zero; $i++) {
        $p = $chain[$i]
        if ($p.Hwnd -ne 0) {
            $cand = Resolve-RealWindow ([IntPtr]$p.Hwnd)
            if ($cand -ne [IntPtr]::Zero) { $win = $cand; $winPid = $p.Pid }
            continue
        }
        $h = Get-ConsoleHwnd $p.Pid
        $cand = Resolve-RealWindow $h
        if ($cand -ne [IntPtr]::Zero) { $win = $cand; $winPid = $p.Pid }
    }
}

$hwndDec = 0
$ownerPid = 0
$ownerFt = ''
if ($win -ne [IntPtr]::Zero) {
    $hwndDec = [int64]$win
    $op = [uint32]0
    [TLResolve]::GetWindowThreadProcessId($win, [ref]$op) | Out-Null
    $ownerPid = [int]$op
    if ($byPid.ContainsKey($ownerPid)) { $ownerFt = $byPid[$ownerPid].Ft }
}

$now = [int][double]::Parse((Get-Date -UFormat %s))

# ---- GC -------------------------------------------------------------------
function Invoke-Gc([bool]$apply) {
    $actions = @()
    $tasks = @()
    try { $tasks = @(Get-ScheduledTask -TaskName 'traffic-light-*' -ErrorAction SilentlyContinue) } catch { $tasks = @() }
    foreach ($t in $tasks) {
        $name = $t.TaskName
        $keep = $false
        if ($name -match '^traffic-light-w(\d+)$') {
            $h = [int64]$Matches[1]
            $anchor = Join-Path $StateDir ("w$h.win")
            if (Test-Path -LiteralPath $anchor) {
                $age = ((Get-Date) - (Get-Item -LiteralPath $anchor).LastWriteTime).TotalMilliseconds
                if ($age -lt $ANCHOR_STALE_MS) { $keep = $true }
            }
        }
        if (-not $keep) {
            $actions += "task:$name"
            if ($apply) { try { Unregister-ScheduledTask -TaskName $name -Confirm:$false } catch {} }
        }
    }
    if (Test-Path -LiteralPath $StateDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $StateDir -File -ErrorAction SilentlyContinue)) {
            $n = $f.Name
            if ($n -match '\.(pid|cbpid)$') {
                $actions += "file:$n"
                if ($apply) { Remove-Item -LiteralPath $f.FullName -Force }
                continue
            }
            if ($n -match '^(.+)\.state$') {
                $key = $Matches[1]
                if ($key -match '^\d+$') { continue }
                $actions += "file:$n"
                if ($apply) { Remove-Item -LiteralPath $f.FullName -Force }
                continue
            }
            if ($n -match '\.bind$') {
                $pidLine = ''
                $ftLine = ''
                foreach ($line in (Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)) {
                    if ($line -match '^pid=(\d+)$') { $pidLine = $Matches[1] }
                    if ($line -match '^creation_ft=(\d+)$') { $ftLine = $Matches[1] }
                }
                $alive = $false
                if ($pidLine -and $pidLine -ne '0') {
                    $pr = Get-Process -Id ([int]$pidLine) -ErrorAction SilentlyContinue
                    if ($pr) {
                        $alive = $true
                        if ($ftLine) {
                            try { if ([string]$pr.StartTime.ToFileTime() -ne $ftLine) { $alive = $false } } catch { $alive = $false }
                        }
                    }
                }
                if (-not $alive) {
                    $actions += "file:$n"
                    if ($apply) { Remove-Item -LiteralPath $f.FullName -Force }
                }
                continue
            }
            if ($n -match '^w(\d+)\.win$') {
                $age = ((Get-Date) - $f.LastWriteTime).TotalMilliseconds
                if ($age -gt $ANCHOR_STALE_MS) {
                    $actions += "file:$n"
                    if ($apply) { Remove-Item -LiteralPath $f.FullName -Force }
                }
            }
        }
    }
    return $actions
}

if ($GcOnly) {
    $acts = Invoke-Gc (-not $DryRun)
    if ($DryRun) { $acts | ConvertTo-Json -Compress } else { foreach ($a in $acts) { Write-Output "[SignalLight] gc $a" } }
    exit 0
}

# ---- write bind -----------------------------------------------------------
if (-not $StateDir) { $StateDir = Join-Path $PSScriptRoot '.traffic-light-states' }
if (-not $SessionId) { $SessionId = "manual-$PID" }
if (-not $Project) { $Project = 'unknown' }
$degraded = 0
if ($hwndDec -eq 0) { $degraded = 1 }

$bindPath = Join-Path $StateDir ("$SessionId.bind")
$claim = 'none'
$nonce = ''
$anchor = ''
$spawned = $false

if (-not $DryRun) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

    # /clear: drop binds of the same pid from previous sessions
    if ($cbPid -ne 0) {
        foreach ($f in @(Get-ChildItem -LiteralPath $StateDir -Filter '*.bind' -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -eq "$SessionId.bind") { continue }
            $otherPid = ''
            foreach ($line in (Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)) {
                if ($line -match '^pid=(\d+)$') { $otherPid = $Matches[1]; break }
            }
            if ($otherPid -eq [string]$cbPid) { Remove-Item -LiteralPath $f.FullName -Force }
        }
    }

    $lines = @(
        "session_id=$SessionId",
        "pid=$cbPid",
        "creation_ft=$cbFt",
        "hwnd=$hwndDec",
        "hwnd_owner_pid=$ownerPid",
        "hwnd_owner_ft=$ownerFt",
        "project=$Project",
        "cwd=$Cwd",
        "updated=$now",
        "degraded=$degraded"
    )
    $tmp = "$bindPath.tmp"
    [System.IO.File]::WriteAllLines($tmp, $lines, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $bindPath -Force

    # claim one drawer per window
    if ($hwndDec -ne 0) {
        $anchor = Join-Path $StateDir ("w$hwndDec.win")
        $isOwner = $false
        for ($try = 0; $try -lt 2 -and -not $isOwner; $try++) {
            try {
                $fs = [System.IO.File]::Open($anchor, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $nonce = [guid]::NewGuid().ToString('N')
                $sw = New-Object System.IO.StreamWriter($fs)
                $sw.WriteLine("nonce=$nonce")
                $sw.WriteLine("drawer_pid=0")
                $sw.WriteLine("hwnd=$hwndDec")
                $sw.WriteLine("owner_pid=$ownerPid")
                $sw.WriteLine("owner_ft=$ownerFt")
                $sw.WriteLine("started=$now")
                $sw.Flush(); $sw.Close(); $fs.Close()
                $isOwner = $true
            } catch {
                $age = 99999
                if (Test-Path -LiteralPath $anchor) { $age = ((Get-Date) - (Get-Item -LiteralPath $anchor).LastWriteTime).TotalMilliseconds }
                if ($age -lt $TICK_GRACE_MS) {
                    Start-Sleep -Milliseconds 500
                    $age2 = 99999
                    if (Test-Path -LiteralPath $anchor) { $age2 = ((Get-Date) - (Get-Item -LiteralPath $anchor).LastWriteTime).TotalMilliseconds }
                    if ($age2 -lt $TICK_GRACE_MS) { break }
                }
                if (Test-Path -LiteralPath $anchor) { Remove-Item -LiteralPath $anchor -Force }
            }
        }
        if ($isOwner) {
            $claim = 'owner'
            $spawned = Start-Drawer $hwndDec $anchor $nonce
        } else {
            $claim = 'busy'
        }
    }

    Invoke-Gc $true | Out-Null
}

if ($DryRun) {
    [pscustomobject]@{
        session_id = $SessionId
        pid        = $cbPid
        creation_ft= $cbFt
        hwnd       = $hwndDec
        owner_pid  = $ownerPid
        degraded   = $degraded
        claim      = $claim
    } | ConvertTo-Json -Compress
    exit 0
}

Write-Output ("[SignalLight] bind sid=$SessionId pid=$cbPid hwnd=$hwndDec degraded=$degraded claim=$claim drawer=$spawned")
exit 0
