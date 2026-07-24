param(
    [string]$Project
)

# 根据项目名查找并停止对应的红绿灯守护进程
# 独立 .ps1 文件避免 bash 转义 $_.Id / Get-CimInstance 的问题

# 转义项目名中的正则元字符（如 . - _），避免 mine.v2 误匹配 mineXv2
$projectPattern = [regex]::Escape($Project)

Get-Process -Name python* -ErrorAction SilentlyContinue |
Where-Object {
    try {
        $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)").CommandLine
        $cmdline -match "traffic_light.*--project $projectPattern"
    } catch {
        $false
    }
} |
Stop-Process -Force -ErrorAction SilentlyContinue

exit 0
