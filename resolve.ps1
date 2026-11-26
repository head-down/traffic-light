<#
Traffic Light - session/window resolver (single source of truth for hwnd)

Called by hooks/traffic-light.sh at SessionStart and when a session's bind is
missing, stale, or still degraded.
In order:
  1. identify this session's CodeBuddy process - service proxy port first, parent
     chain only as a fallback (pid + creation time, never guessed)
  2. derive the project label (main repo name; worktrees fall back to it)
  3. resolve that process's terminal window (attach-console -> GW_OWNER)
  4. write <session_id>.bind atomically (identity immutable, hwnd refreshable)
  5. claim w<hwnd>.win (hwnd=0 claims the machine-wide degraded lamp w0.win) and
     launch one drawer through a traffic-light-w<hwnd> scheduled task
  6. collect legacy tasks/files (GC), idempotent

-degraded is only a fallback: hwnd=0 + degraded=1 is still a valid bind.

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
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
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

# 终端窗口只能从桌面上找：AttachConsole 到 ConPTY 的控制台会让 Windows 新建
# 一个终端窗口（用户看到的就是「闪一下黑框」），所以这里完全不碰控制台 API。
$script:TerminalWindowClasses = @('CASCADIA_HOSTING_WINDOW_CLASS', 'ConsoleWindowClass')

function Test-TerminalWindow([IntPtr]$h) {
    if ($h -eq [IntPtr]::Zero) { return $false }
    $w = Get-Win $h
    if (-not $w) { return $false }
    return ($script:TerminalWindowClasses -contains $w.Class)
}

function Get-ForegroundTerminalWindow {
    # 开会话、提交提示词时终端都在前台；这是唯一不需要控制台 API 的精确来源
    $fg = [TLResolve]::GetForegroundWindow()
    if ((Test-TerminalWindow $fg) -and (Test-WinBindable $fg)) { return $fg }
    return [IntPtr]::Zero
}

function Get-SoleTerminalWindow {
    # 兜底：桌面上只有一个终端窗口时不可能认错
    $script:tlWindows = New-Object System.Collections.ArrayList
    $cb = [TLResolve+EnumWindowsProc]{
        param([IntPtr]$h, [IntPtr]$l)
        if (Test-TerminalWindow $h) { [void]$script:tlWindows.Add($h) }
        return $true
    }
    [TLResolve]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    $visible = @($script:tlWindows | Where-Object { Test-WinBindable $_ })
    if ($visible.Count -eq 1) { return $visible[0] }
    return [IntPtr]::Zero
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

# ---- drawer launch ---------------------------------------------------------

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
    if ($snap.Injected) {
        foreach ($ip in $tryPids) {
            if (-not $byPid.ContainsKey($ip)) { continue }
            # injected snapshots carry hwnd values directly; no real window exists
            if ($byPid[$ip].Hwnd -ne 0) { $win = [IntPtr]$byPid[$ip].Hwnd; break }
        }
    } else {
        # 终端窗口不会变：已有绑定且窗口仍有效就直接复用，避免焦点在别的终端时认错
        $prevBind = Join-Path $StateDir ($SessionId + '.bind')
        if (Test-Path -LiteralPath $prevBind) {
            $prevHwnd = [string](Read-BindFile $prevBind)['hwnd']
            if ($prevHwnd -match '^[1-9]\d*$' -and (Test-WinBindable ([IntPtr][int64]$prevHwnd))) {
                $win = [IntPtr][int64]$prevHwnd
            }
        }
        if ($win -eq [IntPtr]::Zero) {
            $win = Resolve-RealWindow (Get-ForegroundTerminalWindow)
            if ($win -eq [IntPtr]::Zero) { $win = Resolve-RealWindow (Get-SoleTerminalWindow) }
        }
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

# Get-Date -UFormat %s formats local time as if it were UTC (8h ahead here),
# which would freeze the 60s bind TTL. Use the real epoch instead.
$now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# ---- defaults --------------------------------------------------------------

$cwdNorm = $Cwd
if (-not $cwdNorm) { $cwdNorm = (Get-Location).Path }
if ($cwdNorm -match '^/([A-Za-z])/(.*)$') { $cwdNorm = $Matches[1].ToUpper() + ':/' + $Matches[2] }
if (-not $StateDir) { $StateDir = Join-Path $PSScriptRoot '.traffic-light-states' }
if (-not $SessionId) { $SessionId = "manual-$PID" }
# project is a label derived from cwd (never a key, never a parameter)
$Project = Get-ProjectLabel $cwdNorm

# Only a missing window degrades a session. An unresolved pid is "identity
# unknown", not "no window": the bind still belongs to the window it found.
$degraded = 0
if ($hwndDec -eq 0) { $degraded = 1 }
$bindPath = Join-Path $StateDir ($SessionId + '.bind')

# ---- GC --------------------------------------------------------------------

# FILETIME is in 100ns ticks. creation_ft reaches us from two sources: CIM/WMI
# (microsecond precision) and GetProcessTimes (exact), so the same process
# differs by a handful of ticks (measured 4-7). Exact equality calls every live
# session "reused pid" and lets GC delete it, so allow the 10us conversion error
# - still far smaller than any plausible pid reuse.
$FT_TOLERANCE = 100

function Test-FtMatch {
    param([string]$Expected, [string]$Actual)
    if (-not $Expected -or -not $Actual) { return $true }
    try {
        return ([Math]::Abs([int64]$Expected - [int64]$Actual) -le $script:FT_TOLERANCE)
    } catch {
        return $false
    }
}

function Test-ProcIdentity {
    # Is this pid alive and still the same process? An empty creation_ft means
    # "unknown", which only proves death when the pid itself is gone.
    param([string]$PidText, [string]$FtText, $Snap, $ByPid)
    if (-not $PidText -or $PidText -notmatch '^[1-9]\d*$') { return $false }
    $ip = [int]$PidText
    if ($Snap.Injected) {
        if (-not $ByPid.ContainsKey($ip)) { return $false }
        if ($FtText -and $ByPid[$ip].Ft -and -not (Test-FtMatch $FtText ([string]$ByPid[$ip].Ft))) { return $false }
        return $true
    }
    $proc = Get-Process -Id $ip -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    if ($FtText) {
        try { if (-not (Test-FtMatch $FtText ([string]$proc.StartTime.ToFileTime()))) { return $false } }
        catch { return $false }
    }
    return $true
}

function Test-BindAlive {
    param([string]$PidText, [string]$FtText, [string]$HwndText, [string]$DegradedText, $Snap, $ByPid)
    # An unknown identity cannot be proven dead: keep the bind while it still
    # names a window or the degraded lamp. No identity and no target = garbage.
    if (-not $PidText -or $PidText -notmatch '^\d+$' -or [int64]$PidText -le 0) {
        if ($HwndText -match '^\d+$' -and [int64]$HwndText -gt 0) { return $true }
        return ($DegradedText -eq '1')
    }
    return (Test-ProcIdentity -PidText $PidText -FtText $FtText -Snap $Snap -ByPid $ByPid)
}

function Get-StateCreationFt {
    # <pid>.state is three lines: state / cwd / creation_ft. Older two-line
    # files have no identity evidence, which is tolerated (identity unknown).
    param([string]$Path)
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($lines.Count -ge 3) { return ([string]$lines[2]).Trim() }
    return ''
}

function Read-TaskList {
    # -TasksFile lets tests drive the task rules without touching the real
    # scheduler. Accepts a bare array or { tasks: [...] }; entries may be names
    # or { taskName: ... } objects.
    param([string]$Path)
    $names = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $names }
    try { $j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $names }
    $items = $j
    if ($null -ne $j -and -not ($j -is [System.Array]) -and
        ($j.PSObject.Properties.Name -contains 'tasks')) { $items = $j.tasks }
    foreach ($it in @($items)) {
        if ($null -eq $it) { continue }
        if ($it -is [string]) { $names += [string]$it; continue }
        foreach ($k in @('taskName', 'TaskName', 'name')) {
            if ($it.PSObject.Properties.Name -contains $k) { $names += [string]$it.$k; break }
        }
    }
    return $names
}

function Invoke-Gc {
    param([bool]$Apply, $Snap, $ByPid, [string]$Dir)
    $actions = @()

    # --- scheduled tasks
    # traffic-light-w<digits> survives only while its anchor exists and is
    # fresh (<10s); every other traffic-light-* name is a legacy task.
    $taskNames = $null
    $canUnregister = $false
    if ($TasksFile) {
        $taskNames = @(Read-TaskList $TasksFile)
    } elseif (-not $Snap.Injected) {
        $taskNames = @()
        try {
            $taskNames = @(Get-ScheduledTask -TaskName 'traffic-light-*' -ErrorAction SilentlyContinue |
                ForEach-Object { $_.TaskName })
        } catch { $taskNames = @() }
        $canUnregister = -not $NoSpawn
    }
    if ($null -ne $taskNames) {
        foreach ($name in @($taskNames)) {
            if (-not $name) { continue }
            $keep = $false
            if ($name -match '^traffic-light-w(\d+)$') {
                $anchor = Join-Path $Dir ('w' + $Matches[1] + '.win')
                if (Test-Path -LiteralPath $anchor) {
                    $age = ((Get-Date) - (Get-Item -LiteralPath $anchor).LastWriteTime).TotalMilliseconds
                    if ($age -lt $ANCHOR_STALE_MS) { $keep = $true }
                }
            }
            if ($keep) { continue }
            $actions += ('task:' + $name)
            if ($Apply -and $canUnregister) {
                try { Unregister-ScheduledTask -TaskName $name -Confirm:$false } catch {}
            }
        }
    }

    # --- files
    if (Test-Path -LiteralPath $Dir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue)) {
            $n = $f.Name
            if ($n -match '\.(pid|cbpid|hwnd)$') {
                $actions += ('file:' + $n)
                if ($Apply) { Remove-Item -LiteralPath $f.FullName -Force }
                continue
            }
            if ($n -match '^(.+)\.state$') {
                $key = $Matches[1]
                if ($key -match '^\d+$') {
                    # identity-keyed state: dead pid or a reused pid is garbage
                    $ft = Get-StateCreationFt $f.FullName
                    if (-not (Test-ProcIdentity -PidText $key -FtText $ft -Snap $Snap -ByPid $ByPid)) {
                        $actions += ('file:' + $n)
                        if ($Apply) { Remove-Item -LiteralPath $f.FullName -Force }
                    }
                    continue
                }
                $actions += ('file:' + $n)
                if ($Apply) { Remove-Item -LiteralPath $f.FullName -Force }
                continue
            }
            if ($n -match '\.bind$') {
                $b = Read-BindFile $f.FullName
                if (-not (Test-BindAlive -PidText ([string]$b['pid']) -FtText ([string]$b['creation_ft']) -HwndText ([string]$b['hwnd']) -DegradedText ([string]$b['degraded']) -Snap $Snap -ByPid $ByPid)) {
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

function Get-BindLines {
    # $ProcId, not $Pid: $PID is a read-only automatic variable and parameter
    # binding to that name throws.
    param($Sid, $ProcId, $Ft, $Hwnd, $OPid, $OFt, $Proj, $Cwd, $Upd, $Deg)
    return @(
        'session_id=' + $Sid
        'pid=' + $ProcId
        'creation_ft=' + $Ft
        'hwnd=' + $Hwnd
        'hwnd_owner_pid=' + $OPid
        'hwnd_owner_ft=' + $OFt
        'project=' + $Proj
        'cwd=' + $Cwd
        'updated=' + $Upd
        'degraded=' + $Deg
    )
}

Write-Atomic -Path $bindPath -Lines (Get-BindLines $SessionId $effPid $effFt $hwndDec $ownerPid $ownerFt $Project $cwdNorm $now $degraded)

# ---- claim -----------------------------------------------------------------
#
# One hwnd == one lamp. The anchor is the mutex: CreateNew is atomic, so exactly
# one resolver wins. The loser rechecks that the anchor is still being
# heartbeated (<3s) - if so the session is already shown on that lamp and this
# run simply rides along; if not, the anchor is dead and gets re-taken once.
# hwnd=0 claims the machine-wide degraded lamp keyed w0 (same task naming, so
# GC recognises it).
#
# snapshots never touch real tasks or processes; -NoSpawn is the test seam that
# walks the whole path (Start-Drawer still picks and measures the command) but
# registers and launches nothing.

$claim = 'none'
$nonce = ''
$spawned = $false
$anchorPath = ''
$taskName = ''
$claimHwnd = [int64]$hwndDec
$canClaim = (-not $snap.Injected) -or $NoSpawn

if ($canClaim -and ($hwndDec -ne 0 -or $degraded -eq 1)) {
    $anchorPath = Join-Path $StateDir ('w' + $claimHwnd + '.win')
    $taskName = 'traffic-light-w' + $claimHwnd
    $isOwner = $false
    for ($try = 0; $try -lt 2 -and -not $isOwner; $try++) {
        try {
            $fs = [System.IO.File]::Open($anchorPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $nonce = [guid]::NewGuid().ToString('N')
            $sw = New-Object System.IO.StreamWriter($fs)
            $sw.WriteLine('nonce=' + $nonce)
            $sw.WriteLine('drawer_pid=0')
            $sw.WriteLine('hwnd=' + $claimHwnd)
            $sw.WriteLine('owner_pid=' + $ownerPid)
            $sw.WriteLine('owner_ft=' + $ownerFt)
            $sw.WriteLine('started=' + $now)
            $sw.Flush(); $sw.Close(); $fs.Close()
            $isOwner = $true
        } catch {
            $age = 999999
            if (Test-Path -LiteralPath $anchorPath) { $age = ((Get-Date) - (Get-Item -LiteralPath $anchorPath).LastWriteTime).TotalMilliseconds }
            if ($age -lt $TICK_GRACE_MS) {
                # held by a live drawer: prove it survives one beat, then ride it
                Start-Sleep -Milliseconds 500
                $age2 = 999999
                if (Test-Path -LiteralPath $anchorPath) { $age2 = ((Get-Date) - (Get-Item -LiteralPath $anchorPath).LastWriteTime).TotalMilliseconds }
                if ($age2 -lt $TICK_GRACE_MS) { break }
            }
            # one re-take of a dead (or vanished) anchor, then give up
            if ($try -ge 1) { break }
            if (Test-Path -LiteralPath $anchorPath) { Remove-Item -LiteralPath $anchorPath -Force -ErrorAction SilentlyContinue }
            $nonce = ''
        }
    }

    if ($isOwner) {
        $claim = 'owner'
        $spawned = Start-Drawer -Hwnd $claimHwnd -Nonce $nonce -Degraded:($claimHwnd -eq 0)
        if (-not $spawned) {
            # never write a fake success: drop our anchor (only if it is still
            # ours) and rewrite the bind as degraded so the next prompt retries.
            # No recursive w0 claim from here - that is the degraded lamp's own
            # claim path, not a fallback for a failed window lamp.
            $cur = Read-BindFile $anchorPath
            if (-not $cur.ContainsKey('nonce') -or [string]$cur['nonce'] -eq $nonce) {
                Remove-Item -LiteralPath $anchorPath -Force -ErrorAction SilentlyContinue
            }
            $claim = 'failed'
            $hwndDec = 0
            $degraded = 1
            $ownerPid = 0
            $ownerFt = ''
            Write-Atomic -Path $bindPath -Lines (Get-BindLines $SessionId $effPid $effFt 0 0 '' $Project $cwdNorm $now 1)
        }
    } else {
        $claim = 'busy'
        $nonce = ''
    }
}

# GC belongs to install and SessionStart only; prompt-triggered re-resolves
# pass -NoGc so they never sweep another session's state directory.
if (-not $NoGc) {
    Invoke-Gc -Apply $true -Snap $snap -ByPid $byPid -Dir $StateDir | Out-Null
}

if ($NoSpawn) {
    [pscustomobject]@{
        session_id  = $SessionId
        pid         = $effPid
        creation_ft = $effFt
        hwnd        = $hwndDec
        owner_pid   = $ownerPid
        owner_ft    = $ownerFt
        project     = $Project
        cwd         = $cwdNorm
        degraded    = $degraded
        bind_path   = $bindPath
        claim       = $claim
        nonce       = $nonce
        anchor      = $anchorPath
        task        = $taskName
        spawned     = $spawned
    } | ConvertTo-Json -Compress -Depth 4
    exit 0
}

Write-Output ('[SignalLight] bind sid=' + $SessionId + ' pid=' + $effPid + ' hwnd=' + $hwndDec + ' degraded=' + $degraded + ' project=' + $Project + ' claim=' + $claim + ' drawer=' + $spawned)
exit 0
