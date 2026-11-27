<#
resolve-lib.ps1 - hwnd / bind / claim / GC 的决策实现

dot-source 之后调用，不注册计划任务、不拉起进程、不写 bind：

    . ./resolve-lib.ps1
    $snap = Get-Procs -Snapshot $jsonPath
    $d    = Get-ResolutionDecision -Snap $snap -StateDir $dir -SessionId 'sid' -Cwd 'D:/x' -Claim
    $plan = Get-GcPlan -Dir $dir -TaskNames $names -Snap $snap -ByPid $byPid

边界：本文件可以读系统（CIM / git / netstat / 窗口表 / 文件），但执行副作用
（注册或运行任务、写 bind、删绑定的生效动作）归 resolve.ps1。唯一允许的写是
抢窗的锚文件：CreateNew 的原子独占本身就是"谁赢得这盏灯"的判定，挪出去就
没有决策可判了。

状态全部显式传递：没有 $script: 可变全局。窗口表挂在调用方传入的 $Ctx 上，
所以同一个进程里可以反复跑决策，测试不需要再起子进程。
#>

$script:RESOLVE_LIB_ROOT = $PSScriptRoot

# FILETIME 的单位是 100ns。creation_ft 有两个来源：CIM/WMI（微秒精度）和
# GetProcessTimes（精确到 tick），同一个进程两边实测差 4~7 个 tick。精确相等
# 会把活进程判成"pid 已复用"，所以留 10us 的转换误差窗口。
$script:FT_TOLERANCE = 100
$script:TICK_GRACE_MS = 3000     # 锚比这新 = drawer 还活着
$script:ANCHOR_STALE_MS = 10000  # 锚比这旧 = 孤儿，删

$script:TerminalWindowClasses = @('CASCADIA_HOSTING_WINDOW_CLASS', 'ConsoleWindowClass')

if (-not ('TLResolve' -as [type])) {
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
    public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
}
"@
}

# ---- window table ----------------------------------------------------------

function New-ResolverContext {
    # 一次解析过程中共享的窗口表。注入快照只认快照里的窗口；真实模式第一次
    # 用到时枚举一次。可变的只有 $Ctx，不是 $script:。
    param($Snap)
    $ctx = [pscustomobject]@{
        Injected = [bool]$Snap.Injected
        Wins     = @{}
        WinMap   = $null
    }
    if ($Snap.Wins) { $ctx.Wins = $Snap.Wins }
    return $ctx
}

function Get-Win {
    param($Ctx, $h)
    if (-not $h) { return $null }
    $h = [IntPtr]$h
    $key = $h.ToInt64().ToString()
    if ($Ctx.Wins.ContainsKey($key)) {
        $iw = $Ctx.Wins[$key]
        return [pscustomobject]@{
            Hwnd      = $h
            Class     = [string]$iw.Class
            Visible   = [bool]$iw.Visible
            Minimized = $false
            W         = [int]$iw.W
            H         = [int]$iw.H
        }
    }
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

function Test-WinBindable {
    param($Ctx, $h)
    if (-not $h) { return $false }
    $h = [IntPtr]$h
    if ($Ctx.Wins.ContainsKey($h.ToInt64().ToString())) {
        $w = Get-Win $Ctx $h
        return ([bool]$w.Visible -and $w.W -ge 50 -and $w.H -ge 50)
    }
    if (-not [TLResolve]::IsWindow($h)) { return $false }
    if (-not [TLResolve]::IsWindowVisible($h)) { return $false }
    $w = Get-Win $Ctx $h
    if (-not $w) { return $false }
    if ($w.W -lt 50 -or $w.H -lt 50) { return $false }
    return $true
}

# 终端窗口只能从桌面 API 上找：AttachConsole 到 ConPTY 的控制台会让 Windows 新建
# 一个终端窗口（用户看到的就是"闪一下黑框"），也不能读前台窗口（多终端时前台
# 永远是正在打字的那个，别的会话会被绑过去）。唯一可靠的是本会话自己的进程链：
# 窗格里跑的 shell 独占一个控制台窗口，它的 GW_OWNER 就是那块屏的终端窗口。

function Get-WindowsByPid {
    # 顶层窗口按宿主进程分组，一次枚举；注入快照直接给表，不碰真实桌面
    param($Ctx)
    if ($null -ne $Ctx.WinMap) { return $Ctx.WinMap }
    $Ctx.WinMap = @{}
    if ($Ctx.Injected) {
        # 注入快照只认快照里的窗口：假 pid 撞上真实进程也绝不去枚举桌面
        foreach ($key in @($Ctx.Wins.Keys)) {
            $iw = $Ctx.Wins[$key]
            $hostPid = [int]$iw.Pid
            if (-not $Ctx.WinMap.ContainsKey($hostPid)) {
                $Ctx.WinMap[$hostPid] = New-Object System.Collections.ArrayList
            }
            [void]$Ctx.WinMap[$hostPid].Add([IntPtr][int64]$iw.Hwnd)
        }
        return $Ctx.WinMap
    }
    # 回调在委托里执行，取不到本函数的局部变量：用 GetNewClosure 把同一个
    # Ctx 对象带进去（只改进它的属性，不重新绑定变量）。
    $ctxRef = $Ctx
    $cb = {
        param([IntPtr]$h, [IntPtr]$l)
        $op = [uint32]0
        [TLResolve]::GetWindowThreadProcessId($h, [ref]$op) | Out-Null
        $k = [int]$op
        if (-not $ctxRef.WinMap.ContainsKey($k)) {
            $ctxRef.WinMap[$k] = New-Object System.Collections.ArrayList
        }
        [void]$ctxRef.WinMap[$k].Add($h)
        return $true
    }.GetNewClosure()
    [TLResolve]::EnumWindows([TLResolve+EnumWindowsProc]$cb, [IntPtr]::Zero) | Out-Null
    return $Ctx.WinMap
}

function Get-OwnerWindow {
    param($Ctx, $h)
    if (-not $h) { return [IntPtr]::Zero }
    $h = [IntPtr]$h
    $key = $h.ToInt64().ToString()
    if ($Ctx.Wins.ContainsKey($key)) {
        return [IntPtr][int64]$Ctx.Wins[$key].Owner
    }
    return [TLResolve]::GetWindow($h, 4)   # GW_OWNER
}

function Get-ChainTerminalWindow {
    # 沿本会话的进程链由近到远找"自己的"控制台窗口：ConPTY 下是
    # PseudoConsoleWindow（owner = Windows Terminal 窗口），经典控制台是 conhost
    # 持有的可见 ConsoleWindowClass。别的终端不在本链上，因此不可能被认领。
    param($Ctx, [object[]]$Chain, $ByPid)
    $map = Get-WindowsByPid $Ctx
    foreach ($p in $Chain) {
        foreach ($h in @($map[[int]$p.Pid])) {
            if (-not $h) { continue }
            $w = Get-Win $Ctx $h
            if (-not $w) { continue }
            if ($w.Class -eq 'PseudoConsoleWindow') {
                $owner = Get-OwnerWindow $Ctx $h
                if (Test-WinBindable $Ctx $owner) { return $owner }
                continue
            }
            if ($w.Class -eq 'ConsoleWindowClass' -and (Test-WinBindable $Ctx $h)) { return $h }
        }
    }
    # 经典控制台：可见的控制台窗口归 shell 的 conhost 子进程；从链根往下找，
    # 免得把工具子进程临时开的控制台当成本会话的窗口
    for ($i = $Chain.Count - 1; $i -ge 0; $i--) {
        $p = $Chain[$i]
        foreach ($k in @($map.Keys)) {
            $kid = $ByPid[$k]
            if (-not $kid -or $kid.PPid -ne $p.Pid) { continue }
            if ($kid.Name -notmatch '^(conhost|OpenConsole).exe$') { continue }
            foreach ($h in @($map[$k])) {
                $w = Get-Win $Ctx $h
                if ($w -and $w.Class -eq 'ConsoleWindowClass' -and (Test-WinBindable $Ctx $h)) { return $h }
            }
        }
    }
    return [IntPtr]::Zero
}

function Test-ChainHasConsoleWindow {
    # 本会话链上是否见过自己的控制台窗口（不论 owner 能不能用）。见过就
    # 说明会话在某个终端宿主里；owner 认不出时该降级，而不是把桌面上唯一
    # 的终端窗口借过来——IDEA / VSCode 的内嵌终端就是 owner=0 的情形。
    param($Ctx, [object[]]$Chain, $ByPid)
    $map = Get-WindowsByPid $Ctx
    foreach ($p in $Chain) {
        foreach ($h in @($map[[int]$p.Pid])) {
            if (-not $h) { continue }
            $w = Get-Win $Ctx $h
            if (-not $w) { continue }
            if ($w.Class -eq 'PseudoConsoleWindow' -or $w.Class -eq 'ConsoleWindowClass') {
                return $true
            }
        }
    }
    for ($i = $Chain.Count - 1; $i -ge 0; $i--) {
        $p = $Chain[$i]
        foreach ($k in @($map.Keys)) {
            $kid = $ByPid[$k]
            if (-not $kid -or $kid.PPid -ne $p.Pid) { continue }
            if ($kid.Name -notmatch '^(conhost|OpenConsole)\.exe$') { continue }
            foreach ($h in @($map[$k])) {
                $w = Get-Win $Ctx $h
                if ($w -and $w.Class -eq 'ConsoleWindowClass') { return $true }
            }
        }
    }
    return $false
}

function Get-SoleTerminalWindow {
    # 最后一档兜底：桌面上只有一个终端窗口时不可能认错
    param($Ctx)
    $map = Get-WindowsByPid $Ctx
    $bindable = New-Object System.Collections.ArrayList
    foreach ($k in @($map.Keys)) {
        foreach ($h in @($map[$k])) {
            $w = Get-Win $Ctx $h
            if (-not $w) { continue }
            if ($script:TerminalWindowClasses -notcontains $w.Class) { continue }
            if (Test-WinBindable $Ctx $h) { [void]$bindable.Add($h) }
        }
    }
    if ($bindable.Count -eq 1) { return $bindable[0] }
    return [IntPtr]::Zero
}

function Resolve-RealWindow {
    param($Ctx, $h)
    if (-not $h) { return [IntPtr]::Zero }
    $h = [IntPtr]$h
    $w = Get-Win $Ctx $h
    if (-not $w) { return [IntPtr]::Zero }
    $pseudo = ($w.Class -match 'PseudoConsole') -or (($w.W * $w.H) -le 0)
    if ($pseudo) {
        # ConPTY hands back a hidden pseudo console; its owner is the real window
        $owner = Get-OwnerWindow $Ctx $h
        if (Test-WinBindable $Ctx $owner) { return $owner }
    }
    if (Test-WinBindable $Ctx $h) { return $h }
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
    # -Snapshot: 整个决策从 JSON 文件驱动，不碰真实进程与窗口。
    param([string]$Snapshot)
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
        $wins = @{}
        foreach ($w in @($j.windows)) {
            if ($null -eq $w -or -not $w.hwnd) { continue }
            $hv = [int64]$w.hwnd
            $wins[$hv.ToString()] = [pscustomobject]@{
                Hwnd    = $hv
                Pid     = [int]$w.pid
                Class   = [string]$w.Class
                Owner   = $(if ($w.owner) { [int64]$w.owner } else { 0 })
                Visible = $(if ($null -ne $w.visible) { [bool]$w.visible } else { $true })
                W       = $(if ($w.w) { [int]$w.w } else { 1200 })
                H       = $(if ($w.h) { [int]$w.h } else { 800 })
            }
        }
        return @{
            Self = [int]$j.selfPid; List = $list; Wins = $wins
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

# ---- bind / task files -----------------------------------------------------

function Read-BindFile {
    param([string]$Path)
    $h = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $h }
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        if ($line -match '^([^=]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] }
    }
    return $h
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

# ---- identity --------------------------------------------------------------

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

# ---- gc plan ---------------------------------------------------------------

function Get-GcPlan {
    # 只算"该删什么"，不删。返回 'task:<name>' / 'file:<name>' 列表。
    param([string]$Dir, $TaskNames, $Snap, $ByPid)
    $actions = @()

    # --- scheduled tasks
    # traffic-light-w<digits> survives only while its anchor exists and is
    # fresh (<10s); every other traffic-light-* name is a legacy task.
    if ($null -ne $TaskNames) {
        foreach ($name in @($TaskNames)) {
            if (-not $name) { continue }
            $keep = $false
            if ($name -match '^traffic-light-w(\d+)$') {
                $anchor = Join-Path $Dir ('w' + $Matches[1] + '.win')
                if (Test-Path -LiteralPath $anchor) {
                    $age = ((Get-Date) - (Get-Item -LiteralPath $anchor).LastWriteTime).TotalMilliseconds
                    if ($age -lt $script:ANCHOR_STALE_MS) { $keep = $true }
                }
            }
            if ($keep) { continue }
            $actions += ('task:' + $name)
        }
    }

    # --- files
    if (Test-Path -LiteralPath $Dir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue)) {
            $n = $f.Name
            if ($n -match '\.(pid|cbpid|hwnd)$') {
                $actions += ('file:' + $n)
                continue
            }
            if ($n -match '^(.+)\.state$') {
                $key = $Matches[1]
                if ($key -match '^\d+$') {
                    # identity-keyed state: dead pid or a reused pid is garbage
                    $ft = Get-StateCreationFt $f.FullName
                    if (-not (Test-ProcIdentity -PidText $key -FtText $ft -Snap $Snap -ByPid $ByPid)) {
                        $actions += ('file:' + $n)
                    }
                    continue
                }
                $actions += ('file:' + $n)
                continue
            }
            if ($n -match '\.bind$') {
                $b = Read-BindFile $f.FullName
                if (-not (Test-BindAlive -PidText ([string]$b['pid']) -FtText ([string]$b['creation_ft']) -HwndText ([string]$b['hwnd']) -DegradedText ([string]$b['degraded']) -Snap $Snap -ByPid $ByPid)) {
                    $actions += ('file:' + $n)
                }
                continue
            }
            if ($n -match '^w(\d+)\.win$') {
                $age = ((Get-Date) - $f.LastWriteTime).TotalMilliseconds
                if ($age -gt $script:ANCHOR_STALE_MS) {
                    $actions += ('file:' + $n)
                }
            }
        }
    }
    return $actions
}

# ---- decision --------------------------------------------------------------

function Get-BindLines {
    # $ProcId, not $Pid: $PID is a read-only automatic variable and parameter
    # binding to that name throws. hwnd_source is diagnostic only (chain / bind /
    # sole / none): it says how this lamp's window was found, never read back.
    param($Sid, $ProcId, $Ft, $Hwnd, $OPid, $OFt, $Proj, $Cwd, $Upd, $Deg, $Src)
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
        'hwnd_source=' + $Src
    )
}

function Get-ResolutionDecision {
    <#
      给定"机器快照 + 状态目录"，算出这次会话该写哪条绑定、贴哪盏灯、抢不抢得到。
      不注册任务、不拉起 drawer、不写 bind：这些由 resolve.ps1 按返回的对象执行。
      -Claim 关闭时（-DryRun）只算事实，连锚都不碰。
    #>
    param(
        $Snap,
        [string]$StateDir = '',
        [string]$SessionId = '',
        [string]$Cwd = '',
        [switch]$Claim
    )

    $ctx = New-ResolverContext $Snap
    $byPid = @{}
    foreach ($p in $Snap.List) { $byPid[$p.Pid] = $p }

    $chain = @()
    $cur = [int]$Snap.Self
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
    $hwndSource = 'none'

    $port = 0
    if ($Snap.ProxyUrl -match '^https?://[^/]*?:(\d+)') { $port = [int]$Matches[1] }
    if ($port -gt 0) {
        $ownerPid = Get-PortOwner -Port $port -Snap $Snap
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
    # 第一档：本会话进程链上的控制台窗口。窗格里的 shell 独占自己的
    # PseudoConsoleWindow，因此多终端/多窗口下也不会认成别人的灯。
    $win = Resolve-RealWindow $ctx (Get-ChainTerminalWindow $ctx $chain $byPid)
    if ($win -ne [IntPtr]::Zero) { $hwndSource = 'chain' }
    # 第二档：链上找不到（被包装器重挂过）但原窗口还活着，沿用原绑定。
    # 绝不按前台焦点猜：多终端时前台是正在打字的那个，猜错就把灯挪走了。
    if ($win -eq [IntPtr]::Zero -and $StateDir -and $SessionId) {
        $prevBind = Join-Path $StateDir ($SessionId + '.bind')
        if (Test-Path -LiteralPath $prevBind) {
            $prevHwnd = [string](Read-BindFile $prevBind)['hwnd']
            if ($prevHwnd -match '^[1-9]\d*$' -and (Test-WinBindable $ctx ([IntPtr][int64]$prevHwnd))) {
                $win = [IntPtr][int64]$prevHwnd
                $hwndSource = 'bind'
            }
        }
    }
    # 老快照直接把 hwnd 写在进程上（没有窗口表）：沿用那个约定
    if ($win -eq [IntPtr]::Zero -and $Snap.Injected -and $ctx.Wins.Count -eq 0) {
        foreach ($ip in $tryPids) {
            if (-not $byPid.ContainsKey($ip)) { continue }
            if ($byPid[$ip].Hwnd -ne 0) {
                $win = [IntPtr]$byPid[$ip].Hwnd
                $hwndSource = 'injected'
                break
            }
        }
    }
    # 第三档：全桌面只有一个终端窗口。链上已经见过自己的控制台窗口时不能
    # 用这一档：那是 IDEA / VSCode 的内嵌终端，借过来会把两个会话挤进别人
    # 的灯（两个项目的会话合并成一盏 ·2）。
    if ($win -eq [IntPtr]::Zero -and
        -not (Test-ChainHasConsoleWindow $ctx $chain $byPid)) {
        $win = Resolve-RealWindow $ctx (Get-SoleTerminalWindow $ctx)
        if ($win -ne [IntPtr]::Zero) { $hwndSource = 'sole' }
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

    $cwdNorm = $Cwd
    if (-not $cwdNorm) { $cwdNorm = (Get-Location).Path }
    if ($cwdNorm -match '^/([A-Za-z])/(.*)$') { $cwdNorm = $Matches[1].ToUpper() + ':/' + $Matches[2] }
    if (-not $SessionId) { $SessionId = "manual-$PID" }
    if (-not $StateDir) { $StateDir = Join-Path $script:RESOLVE_LIB_ROOT '.traffic-light-states' }
    # project is a label derived from cwd (never a key, never a parameter)
    $project = Get-ProjectLabel $cwdNorm

    # Only a missing window degrades a session. An unresolved pid is "identity
    # unknown", not "no window": the bind still belongs to the window it found.
    $degraded = 0
    if ($hwndDec -eq 0) { $degraded = 1 }
    $bindPath = Join-Path $StateDir ($SessionId + '.bind')

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

    $claimState = 'none'
    $nonce = ''
    $anchorPath = ''
    $taskName = ''

    # ---- claim
    #
    # One hwnd == one lamp. The anchor is the mutex: CreateNew is atomic, so
    # exactly one resolver wins. The loser rechecks that the anchor is being
    # heartbeated (<3s) - if so the session is already shown on that lamp and
    # this run simply rides along; if not, the anchor is dead and gets re-taken
    # once. hwnd=0 claims the machine-wide degraded lamp keyed w0 (same task
    # naming, so GC recognises it).
    if ($Claim -and ($hwndDec -ne 0 -or $degraded -eq 1)) {
        # 锚的父目录必须先存在：CreateNew 不会替你建目录，失败会误判成 busy。
        if (-not (Test-Path -LiteralPath $StateDir)) {
            New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        }
        $claimHwnd = [int64]$hwndDec
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
                if ($age -lt $script:TICK_GRACE_MS) {
                    # held by a live drawer: prove it survives one beat, then ride it
                    Start-Sleep -Milliseconds 500
                    $age2 = 999999
                    if (Test-Path -LiteralPath $anchorPath) { $age2 = ((Get-Date) - (Get-Item -LiteralPath $anchorPath).LastWriteTime).TotalMilliseconds }
                    if ($age2 -lt $script:TICK_GRACE_MS) { break }
                }
                # one re-take of a dead (or vanished) anchor, then give up
                if ($try -ge 1) { break }
                if (Test-Path -LiteralPath $anchorPath) { Remove-Item -LiteralPath $anchorPath -Force -ErrorAction SilentlyContinue }
                $nonce = ''
            }
        }

        if ($isOwner) { $claimState = 'owner' }
        else { $claimState = 'busy'; $nonce = '' }
    }

    $bindLines = Get-BindLines $SessionId $effPid $effFt $hwndDec $ownerPid $ownerFt $project $cwdNorm $now $degraded $hwndSource

    return [pscustomobject]@{
        session_id    = $SessionId
        pid           = $effPid
        creation_ft   = $effFt
        candidate_pid = $cbPid
        candidate_ft  = $cbFt
        hwnd        = $hwndDec
        owner_pid   = $ownerPid
        owner_ft    = $ownerFt
        project     = $project
        cwd         = $cwdNorm
        degraded    = $degraded
        bind_path   = $bindPath
        bind_lines  = $bindLines
        claim       = $claimState
        nonce       = $nonce
        anchor      = $anchorPath
        task        = $taskName
        pid_source  = $pidSource
        hwnd_source = $hwndSource
        now         = $now
    }
}
