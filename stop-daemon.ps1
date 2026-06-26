param(
    [string]$Project
)

# 根据项目名查找并停止对应的红绿灯守护进程
# 独立 .ps1 文件避免 bash 转义 $_.Id / Get-CimInstance 的问题

Get-Process -Name python* -ErrorAction SilentlyContinue |
Where-Object {
    try {
        $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)").CommandLine
        $cmdline -match "traffic_light.*--project $Project"
    } catch {
        $false
    }
} |
Stop-Process -Force -ErrorAction SilentlyContinue

exit 0
