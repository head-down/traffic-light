<#
.SYNOPSIS
    Probe a terminal's real window (hwnd) - the go/no-go gate for one lamp per window.

.DESCRIPTION
    Run once inside EACH terminal you want to support:

        powershell -NoProfile -ExecutionPolicy Bypass -File probe.ps1

    Two runs in two terminals are expected to yield two DIFFERENT hwnd values.
    Same value means the terminals share one window (e.g. two Windows Terminal
    tabs), which aggregates into one lamp by design.

    The full report explains every step (self, parent chain, attach-console,
    top-level windows). A minimized window is measured by its restore rect, so
    it is never mistaken for a missing window.

    Note: this script deliberately prints through Say, never Write-Host.
    Attaching and detaching consoles invalidates the host's console buffer, and
    Write-Host crashes with a HostException after that.

.PARAMETER TargetPid
    Start the parent-chain walk at this pid instead of the current PowerShell
    process. Use it when probing a session from a plain shell.

.PARAMETER ScanAll
    List every CodeBuddy node process on the machine, resolve each one's hwnd,
    and report whether any two share a window. Prints no per-step detail.

.PARAMETER Verdict
    Print exactly one line, for acceptance records:

        hwnd=<decimal> class=<class> size=<w>x<h> verdict=go|no-go

    No window resolves -> hwnd=0 class=- size=0x0 verdict=no-go. Ignored
    combination: -Verdict wins over -ScanAll (ScanAll output is suppressed).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File probe.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File probe.ps1 -Verdict

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File probe.ps1 -ScanAll
#>
param([int]$TargetPid = 0, [switch]$ScanAll, [switch]$Verdict)

$ErrorActionPreference = 'SilentlyContinue'

# -Verdict is for acceptance records: one parseable line, nothing else.
if ($Verdict) { $ScanAll = $false }
$script:Quiet = [bool]$Verdict

function Say {
    param([string]$Text = '')
    if ($script:Quiet) { return }
    [Console]::Out.WriteLine($Text)
}

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class TLProbe {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT {
        public int length; public int flags; public int showCmd;
        public POINT ptMin; public POINT ptMax; public RECT rcNormal;
    }
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
}
"@

function Get-WindowInfo([IntPtr]$h) {
    if ($h -eq [IntPtr]::Zero) { return $null }
    $cls = New-Object System.Text.StringBuilder 256
    [TLProbe]::GetClassName($h, $cls, 256) | Out-Null
    $txt = New-Object System.Text.StringBuilder 256
    [TLProbe]::GetWindowTextW($h, $txt, 256) | Out-Null
    $rect = New-Object 'TLProbe+RECT'
    [TLProbe]::GetWindowRect($h, [ref]$rect) | Out-Null
    $minimized = [TLProbe]::IsIconic($h)
    if ($minimized) {
        # a minimized window reports a 159x27 stub rect; its restore rect is the real one
        $wp = New-Object 'TLProbe+WINDOWPLACEMENT'
        $wp.length = [System.Runtime.InteropServices.Marshal]::SizeOf($wp)
        if ([TLProbe]::GetWindowPlacement($h, [ref]$wp)) {
            $rect.L = $wp.rcNormal.L; $rect.T = $wp.rcNormal.T
            $rect.R = $wp.rcNormal.R; $rect.B = $wp.rcNormal.B
        }
    }
    [pscustomobject]@{
        Hwnd    = ('0x{0:X}' -f $h.ToInt64())
        HwndRaw = $h
        Class   = $cls.ToString()
        Visible = [TLProbe]::IsWindowVisible($h)
        W       = ($rect.R - $rect.L)
        H       = ($rect.B - $rect.T)
        Minimized = $minimized
        Title   = $txt.ToString()
    }
}

if ($ScanAll) {
    Say ''
    Say '=== SCAN ALL CODEBUDDY SESSIONS ==='
    $nodes = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object { $_.CommandLine -match 'node_modules' -and $_.CommandLine -match 'codebuddy' })
    if ($nodes.Count -eq 0) { Say 'no codebuddy node process found'; exit 0 }
    $rows = @()
    foreach ($n in $nodes) {
        $chain2 = @()
        $cur2 = [int]$n.ProcessId
        for ($i = 0; $i -lt 10 -and $cur2 -gt 0; $i++) {
            $p2 = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $cur2)
            if (-not $p2) { break }
            $chain2 += $p2
            $cur2 = [int]$p2.ParentProcessId
        }
        $h2 = [IntPtr]::Zero
        foreach ($p2 in $chain2) {
            [TLProbe]::FreeConsole() | Out-Null
            if (-not [TLProbe]::AttachConsole([uint32]$p2.ProcessId)) { continue }
            $c2 = [TLProbe]::GetConsoleWindow()
            [TLProbe]::FreeConsole() | Out-Null
            if ($c2 -eq [IntPtr]::Zero) { continue }
            $wi = Get-WindowInfo $c2
            $real = $c2
            if ($wi.Class -match 'PseudoConsole' -or ($wi.W * $wi.H) -le 0) {
                $o2 = [TLProbe]::GetWindow($c2, 4)
                if ($o2 -ne [IntPtr]::Zero) { $real = $o2 }
            }
            $rw = Get-WindowInfo $real
            if ($rw -and $rw.W -ge 50 -and $rw.H -ge 50) { $h2 = $real; break }
        }
        $cwd = ''
        $sj = Join-Path $env:USERPROFILE ('.codebuddy\sessions\' + $n.ProcessId + '.json')
        if (Test-Path -LiteralPath $sj) {
            try { $cwd = (Get-Content -LiteralPath $sj -Raw | ConvertFrom-Json).cwd } catch {}
        }
        $hw = if ($h2 -eq [IntPtr]::Zero) { '(none)' } else { ('0x{0:X}' -f $h2.ToInt64()) }
        $rows += [pscustomobject]@{ Pid = $n.ProcessId; Hwnd = $hw; Cwd = $cwd }
        Say ("pid={0,-7} hwnd={1,-10} cwd={2}" -f $n.ProcessId, $hw, $cwd)
    }
    Say ''
    $dupes = @($rows | Where-Object { $_.Hwnd -ne '(none)' } | Group-Object Hwnd | Where-Object { $_.Count -gt 1 })
    if ($dupes.Count -gt 0) {
        Say 'SHARED WINDOW: these sessions report the same hwnd (tabs of one window) -> aggregate with /N'
    } else {
        Say 'ALL DISTINCT: each session resolved its own window'
    }
    exit 0
}

Say ''
Say '=== 1. SELF ==='
Say ("powershell pid = {0}" -f $PID)
$selfConsole = [TLProbe]::GetConsoleWindow()
if ($selfConsole -ne [IntPtr]::Zero) {
    $w = Get-WindowInfo $selfConsole
    Say ("console hwnd = {0}  class={1}  visible={2}  size={3}x{4}" -f $w.Hwnd, $w.Class, $w.Visible, $w.W, $w.H)
    if ($w.Class -match 'PseudoConsole') {
        Say 'RED FLAG: PseudoConsoleWindow (ConPTY) -> must use GW_OWNER'
    }
} else {
    Say 'console hwnd = (none) -> no console attached (detached spawn, or pty)'
}

Say ''
Say '=== 2. CHAIN (leaf -> root) ==='
$start = if ($TargetPid -gt 0) { $TargetPid } else { $PID }
$chain = @()
$cur = [int]$start
for ($i = 0; $i -lt 12 -and $cur -gt 0; $i++) {
    $p = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $cur)
    if (-not $p) { break }
    $chain += [pscustomobject]@{
        Pid     = [int]$p.ProcessId
        PPid    = [int]$p.ParentProcessId
        Name    = $p.Name
        Started = $p.CreationDate
        Cmd     = (($p.CommandLine -replace '\s+', ' '))
    }
    $cur = [int]$p.ParentProcessId
}
foreach ($c in $chain) {
    $short = if ($c.Cmd.Length -gt 110) { $c.Cmd.Substring(0,110) } else { $c.Cmd }
    Say ("pid={0,-7} ppid={1,-7} {2,-22} {3:yyyy-MM-dd HH:mm:ss}" -f $c.Pid, $c.PPid, $c.Name, $c.Started)
    Say ("        cmd: {0}" -f $short)
}

Say ''
Say '=== 3A. ATTACH-CONSOLE (real console window per pid) ==='
$attachHits = @()
foreach ($c in $chain) {
    [TLProbe]::FreeConsole() | Out-Null
    $ok = [TLProbe]::AttachConsole([uint32]$c.Pid)
    if (-not $ok) {
        Say ("  [{0} {1}] attach failed (no console / access denied)" -f $c.Pid, $c.Name)
        continue
    }
    $h = [TLProbe]::GetConsoleWindow()
    [TLProbe]::FreeConsole() | Out-Null
    if ($h -eq [IntPtr]::Zero) {
        Say ("  [{0} {1}] attached but GetConsoleWindow() = 0" -f $c.Pid, $c.Name)
        continue
    }
    $w = Get-WindowInfo $h
    Say ("  [{0} {1}] console {2}  class={3,-24} visible={4,-5} size={5}x{6}" -f $c.Pid, $c.Name, $w.Hwnd, $w.Class, $w.Visible, $w.W, $w.H)
    $owner = [TLProbe]::GetWindow($h, 4)
    if ($owner -ne [IntPtr]::Zero) {
        $ow = Get-WindowInfo $owner
        Say ("      GW_OWNER -> {0} class={1} visible={2} size={3}x{4} title='{5}'" -f $ow.Hwnd, $ow.Class, $ow.Visible, $ow.W, $ow.H, $ow.Title)
    } else {
        Say '      GW_OWNER -> (none)'
    }
    $attachHits += [pscustomobject]@{ Pid = $c.Pid; Name = $c.Name; Hwnd = $w.Hwnd; Class = $w.Class; W = $w.W; H = $w.H; OwnerHwnd = $owner; Raw = $h }
}

Say ''
Say '=== 3B. TOP-LEVEL WINDOWS (visible, owned by chain pid) ==='
$script:winMap = @{}
$cb = [TLProbe+EnumProc]{
    param([IntPtr]$h, [IntPtr]$l)
    $wpid = [uint32]0
    [TLProbe]::GetWindowThreadProcessId($h, [ref]$wpid) | Out-Null
    $key = [int]$wpid
    if (-not $script:winMap.ContainsKey($key)) { $script:winMap[$key] = New-Object System.Collections.ArrayList }
    $script:winMap[$key].Add($h) | Out-Null
    return $true
}
[TLProbe]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null

$chainPids = @($chain | ForEach-Object { $_.Pid })
$kidPids  = @()
foreach ($c in $chain) {
    $kids = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $c.Pid) | Where-Object { $_.Name -match 'conhost|OpenConsole' })
    foreach ($k in $kids) { $kidPids += [pscustomobject]@{ Pid = [int]$k.ProcessId; Name = $k.Name } }
}

$upHits = @()
foreach ($p in ($chain + $kidPids)) {
    $hwnds = $script:winMap[$p.Pid]
    if (-not $hwnds) {
        if ($chainPids -contains $p.Pid) { Say ("  [{0} {1}] no top-level window" -f $p.Pid, $p.Name) }
        continue
    }
    foreach ($h in $hwnds) {
        $w = Get-WindowInfo $h
        if (-not $w.Visible) { continue }
        if ($w.W -lt 50 -or $w.H -lt 50) { continue }
        Say ("  [{0} {1}] {2} class={3,-28} size={4}x{5} title='{6}'" -f $p.Pid, $p.Name, $w.Hwnd, $w.Class, $w.W, $w.H, $w.Title)
        $upHits += [pscustomobject]@{ Pid = $p.Pid; Name = $p.Name; Hwnd = $w.Hwnd; Class = $w.Class; Area = ($w.W * $w.H); Raw = $h }
    }
}

Say ''
Say '=== 4. VERDICT ==='
$picked = $null
$pickedRaw = [IntPtr]::Zero
$how = ''
foreach ($hit in $attachHits) {
    if ($hit.Class -match 'PseudoConsole') {
        if ($hit.OwnerHwnd -eq [IntPtr]::Zero) { continue }
        $ow = Get-WindowInfo $hit.OwnerHwnd
        if ($ow -and $ow.W -ge 50 -and $ow.H -ge 50) {
            $picked = $ow.Hwnd
            $pickedRaw = $ow.HwndRaw
            $how = ("attach->owner  (pid {0} {1})" -f $hit.Pid, $hit.Name)
            break
        }
        continue
    }
    if ($hit.W -ge 50 -and $hit.H -ge 50) {
        $picked = $hit.Hwnd
        $pickedRaw = $hit.Raw
        $how = ("attach         (pid {0} {1})" -f $hit.Pid, $hit.Name)
        break
    }
}
if (-not $picked) {
    foreach ($c in $chain) {
        $pool = @($upHits | Where-Object { $_.Pid -eq $c.Pid -and $_.Class -notmatch 'PseudoConsole' })
        if ($pool.Count -gt 0) {
            $best = ($pool | Sort-Object Area -Descending | Select-Object -First 1)
            $picked = $best.Hwnd
            $pickedRaw = $best.Raw
            $how = ("upchain        (pid {0} {1})" -f $best.Pid, $best.Name)
            break
        }
    }
}

if ($Verdict) {
    if ($pickedRaw -ne [IntPtr]::Zero) {
        $vw = Get-WindowInfo $pickedRaw
        $word = if ($vw.W -ge 50 -and $vw.H -ge 50) { 'go' } else { 'no-go' }
        $line = 'hwnd=' + $pickedRaw.ToInt64() + ' class=' + $vw.Class + ' size=' + $vw.W + 'x' + $vw.H + ' verdict=' + $word
        [Console]::Out.WriteLine($line)
    } else {
        [Console]::Out.WriteLine('hwnd=0 class=- size=0x0 verdict=no-go')
    }
    exit 0
}

if ($picked) {
    Say ("BIND CANDIDATE hwnd = {0}   [{1}]" -f $picked, $how)
} else {
    Say 'NO CANDIDATE: nothing bindable found'
}

$cbs = @($chain | Where-Object { $_.Name -match '^node\.exe$' -and $_.Cmd -match 'node_modules' -and $_.Cmd -match 'codebuddy' })
Say ''
if ($cbs.Count -eq 0) {
    Say 'NOTE: no codebuddy node process in this chain (ran from a plain shell).'
    Say '      For the real test run it through a hook, or pass -TargetPid <node pid>.'
} else {
    Say ("codebuddy node pid = {0}  (started {1:yyyy-MM-dd HH:mm:ss})" -f $cbs[0].Pid, $cbs[0].Started)
}
Say 'PASTE THIS WHOLE OUTPUT BACK, ONE PER TERMINAL.'