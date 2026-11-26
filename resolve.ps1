<#
Traffic Light - session/window resolver (single source of truth for hwnd)

Called by bind.sh at SessionStart and when a session's bind is missing or stale.
T02 scope, in order:
  1. identify this session's CodeBuddy process - service proxy port first, parent
     chain only as a fallback (pid + creation time, never guessed)
  2. derive the project label (main repo name; worktrees fall back to it)
  3. resolve that process's terminal window (attach-console -> GW_OWNER)
  4. write <session_id>.bind atomically (identity immutable, hwnd refreshable)
  5. degraded fallback: hwnd=0 + degraded=1 is still a valid bind

Not in this ticket (T04): claiming <hwnd>.win, spawning a drawer, scheduled task
lifecycle. The claim block below is the draft's, guarded so it only runs once
Start-Drawer exists.

Design rules (do not simplify away):
  - the proxy port owner is authoritative: the port is bound by this session's
    own CodeBuddy process, so pid reuse and transient child processes cannot
    confuse it. The chain is a fallback for missing port / missing listener /
    unknown owner only.
  - the process chain is walked from ONE CIM snapshot, not one query per level.
  - a parent cannot be older than its child: ascending past an inverted
    creation time would attribute the session to the wrong process.
  - attach-console happens ONLY here, never in the drawer: the drawer has no
    console and attaching would give it one.
  - a minimized window reports a 159x27 stub from GetWindowRect; sizes always
    come from GetWindowPlacement's restore rect.
  - every ps1 invocation from hooks must use -NoProfile -ExecutionPolicy Bypass.
  - -Snapshot drives the whole decision from a JSON file (tests, dry runs):
    no real process, window, scheduled task or port is touched.
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
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT {
        public int length; public int flags; public int showCmd;
        public POINT ptMin; public POINT ptMax; public RECT rcNormal;
    }
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
}
"@

# ---- windows ---------------------------------------------------------------

function Get-Win([IntPtr]$h) {
    if ($h -eq [IntPtr]::Zero) { return $null }
    $cls = New-Object System.Text.StringBuilder 256
    [TLResolve]::GetClassName($h, $cls, 256) | Out-Null
    # restore rect, never the stub rect of a minimized window
    $wp = New-Object 'TLResolve+WINDOWPLACEMENT'
    $wp.length = [System.Runtime.InteropServices.Marshal]::SizeOf($wp)
    $rect = New-Object 'TLResolve+RECT'
    if ([TLResolve]::GetWindowPlacement($h, [ref]$wp)) {
        $rect = $wp.rcNormal
    } else {
        [TLResolve]::GetWindowRect($h, [ref]$rect) | Out-Null
    }
    [pscustomobject]@{
        Hwnd      = $h
        Class     = $cls.ToString()
        Visible   = [TLResolve]::IsWindowVisible($h)
        Minimized = [TLResolve]::IsIconic($h)
        W         = ($rect.R - $rect.L)
        H         = ($rect.B - $rect.T)
    }
}

function Test-WinBindable([IntPtr]$h) {
    if ($h -eq [IntPtr]::Zero) { return $false }
    if (-not [TLResolve]::IsWindow($h)) { return $false }
    if (-not [TLResolve]::IsWindowVisible($h)) { return $false }
    $w = Get-Win $h
    if (-not $w) { return $false }
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
    if (-not $w) { return [IntPtr]::Zero }
    $pseudo = ($w.Class -match 'PseudoConsole') -or (($w.W * $w.H) -le 0)
    if ($pseudo) {
        # ConPTY hands back a hidden pseudo console; its owner is the real window
        $owner = [TLResolve]::GetWindow($h, 4)   # GW_OWNER
        if (Test-WinBindable $owner) { return $owner }
    }
    if (Test-WinBindable $h) { return $h }
    return [IntPtr]::Zero
}

# ---- process snapshot ------------------------------------------------------

function ConvertTo-FtString($v) {
    if ($null -eq $v) { return '' }
    if ($v -is [datetime]) {
        try { return [string]$v.ToFileTime() } catch { return '' }
    }
    $s = [string]$v
    if ($s -match '^\d+$') { return $s }
    try { return [string]([datetime]$v).ToFileTime() } catch { return '' }
}

function Get-Procs {
    if ($Snapshot) {
        $j = Get-Content -LiteralPath $Snapshot -Raw | ConvertFrom-Json
        $list = @()
        foreach ($p in @($j.procs)) {
            $hv = 0
            if ($p.hwnd) { $hv = [int64]$p.hwnd }
            $list += [pscustomobject]@{
                Pid  = [int]$p.processId
                PPid = [int]$p.parentProcessId
                Name = [string]$p.name
                Ft   = (ConvertTo-FtString $p.creationFt)
                Cmd  = [string]$p.commandLine
                Hwnd = $hv
            }
        }
        $listeners = @{}
        if ($j.listeners) {
            if ($j.listeners -is [System.Management.Automation.PSCustomObject]) {
                foreach ($pr in $j.listeners.PSObject.Properties) { $listeners[[string]$pr.Name] = [int]$pr.Value }
            } else {
                foreach ($l in @($j.listeners)) { $listeners[[string]$l.port] = [int]$l.pid }
            }
        }
        return @{
            Self = [int]$j.selfPid; List = $list
            Listeners = $listeners; ProxyUrl = [string]$j.proxyUrl; Injected = $true
        }
    }

    $raw = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, CreationDate, CommandLine
    $list = @()
    foreach ($p in $raw) {
        $list += [pscustomobject]@{
            Pid  = [int]$p.ProcessId
            PPid = [int]$p.ParentProcessId
            Name = [string]$p.Name
            Ft   = (ConvertTo-FtString $p.CreationDate)
            Cmd  = [string]$p.CommandLine
            Hwnd = 0
        }
    }
    return @{
        Self = $PID; List = $list
        Listeners = @{}; ProxyUrl = [string]$env:CODEBUDDY_SERVICE_PROXY_URL; Injected = $false
    }
}

function Get-PortOwner {
    param([int]$Port, $Snap)
    if ($Port -le 0) { return 0 }
    if ($Snap.Injected) {
        $k = [string]$Port
        if ($Snap.Listeners.ContainsKey($k)) { return [int]$Snap.Listeners[$k] }
        return 0
    }
    try {
        $conns = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop |
            Where-Object { $_.LocalAddress -eq '127.0.0.1' })
        if ($conns.Count -gt 0) { return [int]$conns[0].OwningProcess }
    } catch {}
    try {
        $rows = @(& netstat -ano 2>$null | Select-String -Pattern ('127\.0\.0\.1:' + $Port + '\s+.*LISTENING'))
        if ($rows.Count -gt 0) { return [int](($rows[0].Line -split '\s+')[-1]) }
    } catch {}
    return 0
}

# ---- labels ----------------------------------------------------------------

function Get-ProjectLabel {
    param([string]$Path)
    if (-not $Path) { return 'unknown' }
    $p = $Path
    if ($p -match '^/([A-Za-z])/(.*)$') { $p = $Matches[1].ToUpper() + ':/' + $Matches[2] }
    $common = ''
    try {
        $out = @(& git -C $p rev-parse --path-format=absolute --git-common-dir 2>$null)
        if ($out.Count -gt 0 -and $LASTEXITCODE -eq 0) { $common = ([string]$out[0]).Trim() }
    } catch {}
    if (-not $common) {
        try {
            $out = @(& git -C $p rev-parse --git-common-dir 2>$null)
            if ($out.Count -gt 0 -and $LASTEXITCODE -eq 0) {
                $rel = ([string]$out[0]).Trim()
                if ($rel) {
                    if ([System.IO.Path]::IsPathRooted($rel)) { $common = $rel }
                    else { $common = Join-Path $p $rel }
                }
            }
        } catch {}
    }
    if ($common) {
        try {
            $full = [System.IO.Path]::GetFullPath($common)
            $root = Split-Path -Parent $full
            if ($root) { return (Split-Path -Leaf $root) }
        } catch {}
    }
    $leaf = Split-Path -Leaf ($p.TrimEnd('\', '/'))
    if ($leaf) { return $leaf }
    return 'unknown'
}

# ---- bind files ------------------------------------------------------------

function Read-BindFile {
    param([string]$Path)
    $h = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $h }
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        if ($line -match '^([^=]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] }
    }
    return $h
}

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

# ---- facts -----------------------------------------------------------------

$snap = Get-Procs
$byPid = @{}
foreach ($p in $snap.List) { $byPid[$p.Pid] = $p }

$chain = @()
$cur = [int]$snap.Self
$childFt = ''
for ($i = 0; $i -lt 16 -and $cur -gt 0; $i++) {
    if (-not $byPid.ContainsKey($cur)) { break }
    $p = $byPid[$cur]
    # a parent cannot have been created after its child: stop, never guess
    if ($childFt -and $p.Ft -match '^\d+$') {
        if ([decimal]$p.Ft -gt [decimal]$childFt) { break }
    }
    $chain += $p
    if ($p.Ft -match '^\d+$') { $childFt = $p.Ft }
    $cur = [int]$p.PPid
}

$cbPid = 0
$cbFt = ''
$pidSource = 'none'
$win = [IntPtr]::Zero

if (-not $GcOnly) {
    $port = 0
    if ($snap.ProxyUrl -match '^https?://[^/]*?:(\d+)') { $port = [int]$Matches[1] }
    if ($port -gt 0) {
        $ownerPid = Get-PortOwner -Port $port -Snap $snap
        if ($ownerPid -gt 0 -and $byPid.ContainsKey($ownerPid)) {
            $cbPid = $ownerPid
            $cbFt = [string]$byPid[$ownerPid].Ft
            $pidSource = 'port'
        }
    }
    if ($cbPid -eq 0) {
        foreach ($p in $chain) {
            if ($p.Name -match '^node\.exe$' -and $p.Cmd -match 'codebuddy' -and
                $p.Cmd -notmatch 'windows-child-process-containment|conpty|node-pty|containment') {
                $cbPid = $p.Pid
                $cbFt = [string]$p.Ft
                $pidSource = 'chain'
                break
            }
        }
    }

    $tryPids = @()
    if ($cbPid -gt 0) { $tryPids += $cbPid }
    foreach ($p in $chain) { if ($tryPids -notcontains $p.Pid) { $tryPids += $p.Pid } }
    foreach ($ip in $tryPids) {
        if (-not $byPid.ContainsKey($ip)) { continue }
        $p = $byPid[$ip]
        if ($snap.Injected) {
            # injected snapshots carry hwnd values directly; no real window exists
            if ($p.Hwnd -ne 0) { $win = [IntPtr]$p.Hwnd; break }
            continue
        }
        $cand = Resolve-RealWindow (Get-ConsoleHwnd $ip)
        if ($cand -ne [IntPtr]::Zero) { $win = $cand; break }
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
    if ($ownerPid -gt 0 -and $byPid.ContainsKey($ownerPid)) { $ownerFt = [string]$byPid[$ownerPid].Ft }
}

$now = [int][double]::Parse((Get-Date -UFormat %s))

# ---- defaults --------------------------------------------------------------

$cwdNorm = $Cwd
if (-not $cwdNorm) { $cwdNorm = (Get-Location).Path }
if ($cwdNorm -match '^/([A-Za-z])/(.*)$') { $cwdNorm = $Matches[1].ToUpper() + ':/' + $Matches[2] }
if (-not $StateDir) { $StateDir = Join-Path $PSScriptRoot '.traffic-light-states' }
if (-not $SessionId) { $SessionId = "manual-$PID" }
if (-not $Project) { $Project = Get-ProjectLabel $cwdNorm }

$degraded = 0
if ($hwndDec -eq 0 -or $cbPid -eq 0) { $degraded = 1 }
$bindPath = Join-Path $StateDir ($SessionId + '.bind')

# ---- GC --------------------------------------------------------------------

function Test-BindAlive {
    param([string]$PidText, [string]$FtText, $Snap, $ByPid)
    if (-not $PidText -or $PidText -eq '0') { return $false }
    if ($PidText -notmatch '^\d+$') { return $false }
    $ip = [int]$PidText
    if ($Snap.Injected) {
        if (-not $ByPid.ContainsKey($ip)) { return $false }
        if ($FtText -and $ByPid[$ip].Ft -and ([string]$ByPid[$ip].Ft -ne $FtText)) { return $false }
        return $true
    }
    $proc = Get-Process -Id $ip -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    if ($FtText) {
        try { if ([string]$proc.StartTime.ToFileTime() -ne $FtText) { return $false } }
        catch { return $false }
    }
    return $true
}

function Invoke-Gc {
    param([bool]$Apply, $Snap, $ByPid, [string]$Dir)
    $actions = @()

    if (-not $Snap.Injected) {
        $tasks = @()
        try { $tasks = @(Get-ScheduledTask -TaskName 'traffic-light-*' -ErrorAction SilentlyContinue) } catch { $tasks = @() }
        foreach ($t in $tasks) {
            $name = $t.TaskName
            $keep = $false
            if ($name -match '^traffic-light-w(\d+)$') {
                $anchor = Join-Path $Dir ('w' + $Matches[1] + '.win')
                if (Test-Path -LiteralPath $anchor) {
                    $age = ((Get-Date) - (Get-Item -LiteralPath $anchor).LastWriteTime).TotalMilliseconds
                    if ($age -lt $ANCHOR_STALE_MS) { $keep = $true }
                }
            }
            if (-not $keep) {
                $actions += ('task:' + $name)
                if ($Apply) { try { Unregister-ScheduledTask -TaskName $name -Confirm:$false } catch {} }
            }
        }
    }

    if (Test-Path -LiteralPath $Dir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue)) {
            $n = $f.Name
            if ($n -match '\.(pid|cbpid)$') {
                $actions += ('file:' + $n)
                if ($Apply) { Remove-Item -LiteralPath $f.FullName -Force }
                continue
            }
            if ($n -match '^(.+)\.state$') {
                $key = $Matches[1]
                if ($key -match '^\d+$') { continue }
                $actions += ('file:' + $n)
                if ($Apply) { Remove-Item -LiteralPath $f.FullName -Force }
                continue
            }
            if ($n -match '\.bind$') {
                $b = Read-BindFile $f.FullName
                if (-not (Test-BindAlive -PidText ([string]$b['pid']) -FtText ([string]$b['creation_ft']) -Snap $Snap -ByPid $ByPid)) {
                    $actions += ('file:' + $n)
                    if ($Apply) { Remove-Item -LiteralPath $f.FullName -Force }
                }
                continue
            }
            if ($n -match '^w(\d+)\.win$') {
                $age = ((Get-Date) - $f.LastWriteTime).TotalMilliseconds
                if ($age -gt $ANCHOR_STALE_MS) {
                    $actions += ('file:' + $n)
                    if ($Apply) { Remove-Item -LiteralPath $f.FullName -Force }
                }
            }
        }
    }
    return $actions
}

if ($GcOnly) {
    $acts = Invoke-Gc -Apply (-not $DryRun) -Snap $snap -ByPid $byPid -Dir $StateDir
    if ($DryRun) {
        [pscustomobject]@{ gc = @($acts) } | ConvertTo-Json -Compress -Depth 4
    } else {
        foreach ($a in $acts) { Write-Output ('[SignalLight] gc ' + $a) }
    }
    exit 0
}

if ($DryRun) {
    [pscustomobject]@{
        session_id  = $SessionId
        pid         = $cbPid
        creation_ft = $cbFt
        hwnd        = $hwndDec
        owner_pid   = $ownerPid
        owner_ft    = $ownerFt
        project     = $Project
        cwd         = $cwdNorm
        degraded    = $degraded
        bind_path   = $bindPath
        pid_source  = $pidSource
    } | ConvertTo-Json -Compress -Depth 4
    exit 0
}

# ---- write bind ------------------------------------------------------------

# identity is immutable once written: a later glitch (port gone, chain picking a
# neighbouring session) must not rewrite a good pid / creation_ft. Only a bind
# without a usable identity (pid=0) may be upgraded.
$effPid = $cbPid
$effFt = $cbFt
$existing = Read-BindFile $bindPath
if ($existing.Count -gt 0) {
    $ep = [string]$existing['pid']
    $ef = [string]$existing['creation_ft']
    if ($ep -match '^[1-9]\d*$' -and $ef) {
        $effPid = [int]$ep
        $effFt = $ef
    }
}

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

# /clear: a new session_id for the same pid replaces the old bind, O(1) cleanup
if ($effPid -ne 0) {
    foreach ($f in @(Get-ChildItem -LiteralPath $StateDir -Filter '*.bind' -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -eq ($SessionId + '.bind')) { continue }
        $b = Read-BindFile $f.FullName
        if ([string]$b['pid'] -eq [string]$effPid) { Remove-Item -LiteralPath $f.FullName -Force }
    }
}

$lines = @(
    'session_id=' + $SessionId
    'pid=' + $effPid
    'creation_ft=' + $effFt
    'hwnd=' + $hwndDec
    'hwnd_owner_pid=' + $ownerPid
    'hwnd_owner_ft=' + $ownerFt
    'project=' + $Project
    'cwd=' + $cwdNorm
    'updated=' + $now
    'degraded=' + $degraded
)
Write-Atomic -Path $bindPath -Lines $lines

# ---- claim (T04) -----------------------------------------------------------

$claim = 'none'
$nonce = ''
$spawned = $false
if (-not $snap.Injected -and $hwndDec -ne 0 -and (Get-Command Start-Drawer -ErrorAction SilentlyContinue)) {
    $anchor = Join-Path $StateDir ('w' + $hwndDec + '.win')
    $isOwner = $false
    for ($try = 0; $try -lt 2 -and -not $isOwner; $try++) {
        try {
            $fs = [System.IO.File]::Open($anchor, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $nonce = [guid]::NewGuid().ToString('N')
            $sw = New-Object System.IO.StreamWriter($fs)
            $sw.WriteLine('nonce=' + $nonce)
            $sw.WriteLine('drawer_pid=0')
            $sw.WriteLine('hwnd=' + $hwndDec)
            $sw.WriteLine('owner_pid=' + $ownerPid)
            $sw.WriteLine('owner_ft=' + $ownerFt)
            $sw.WriteLine('started=' + $now)
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

Invoke-Gc -Apply $true -Snap $snap -ByPid $byPid -Dir $StateDir | Out-Null

Write-Output ('[SignalLight] bind sid=' + $SessionId + ' pid=' + $effPid + ' hwnd=' + $hwndDec + ' degraded=' + $degraded + ' project=' + $Project + ' claim=' + $claim + ' drawer=' + $spawned)
exit 0
