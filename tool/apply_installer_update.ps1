#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallerPath,
    [Parameter(Mandatory = $true)]
    [int]$TargetProcessId,
    [string]$AppExe = "",
    [string]$LogPath = "",
    [int]$WaitSeconds = 120
)

# 安装版更新助手：等待当前程序退出后再启动安装程序，保留安装向导与用户交互。
# 日志与错误提示必须落盘，助手是脱离父进程运行的，失败时没有调用方可以收到异常。
$ErrorActionPreference = "Stop"

$script:logFile = $LogPath

function Write-Log([string]$message) {
    $line = "[{0}] {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $message
    if (-not $script:logFile) {
        return
    }
    try {
        $dir = Split-Path -Parent $script:logFile
        if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Add-Content -LiteralPath $script:logFile -Value $line -Encoding UTF8
    }
    catch {}
}

function Show-ErrorBox([string]$message) {
    try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show(
            $message,
            "Pure Music 更新",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
    catch {
        Write-Log "无法显示错误对话框：$($_.Exception.Message)"
    }
}

# 进程退出后 PID 可能被复用，路径对不上时按已退出处理，避免一直等到超时。
function Test-TargetProcessRunning {
    try {
        $process = Get-Process -Id $TargetProcessId -ErrorAction SilentlyContinue
    }
    catch {
        return $false
    }
    if ($null -eq $process) {
        return $false
    }
    if ($AppExe) {
        try {
            $runningPath = [System.IO.Path]::GetFullPath($process.Path)
            $expectedPath = [System.IO.Path]::GetFullPath($AppExe)
            if (-not $runningPath.Equals($expectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Log "PID $TargetProcessId 已被其它进程复用（$runningPath），按当前程序已退出处理。"
                return $false
            }
        }
        catch {
            # 读不到进程路径时按仍在运行处理，由等待超时兜底。
        }
    }
    return $true
}

function Restart-App {
    if (-not $AppExe -or -not (Test-Path -LiteralPath $AppExe -PathType Leaf)) {
        return
    }
    try {
        Start-Process -FilePath $AppExe -WorkingDirectory (Split-Path -Parent $AppExe) | Out-Null
        Write-Log "已重新启动 Pure Music：$AppExe"
    }
    catch {
        Write-Log "重新启动 Pure Music 失败：$($_.Exception.Message)"
    }
}

try {
    Write-Log "更新助手启动：安装包=$InstallerPath，等待进程 PID=$TargetProcessId。"

    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        throw "找不到安装包：$InstallerPath"
    }
    $installerLength = (Get-Item -LiteralPath $InstallerPath).Length
    if ($installerLength -le 0) {
        throw "安装包为空：$InstallerPath"
    }
    Write-Log "安装包大小：$installerLength 字节。"

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while (Test-TargetProcessRunning) {
        if ((Get-Date) -ge $deadline) {
            throw "Pure Music 没有在 $WaitSeconds 秒内退出（PID=$TargetProcessId），安装已取消。"
        }
        Start-Sleep -Milliseconds 250
    }
    Write-Log "当前程序已退出，启动安装程序。"

    $installer = Start-Process `
        -FilePath $InstallerPath `
        -WorkingDirectory (Split-Path -Parent $InstallerPath) `
        -PassThru
    if ($null -eq $installer) {
        throw "无法启动安装程序。"
    }
    Write-Log "安装程序已启动，PID=$($installer.Id)。等待用户完成安装向导。"
    # 只清理复制到系统临时目录的副本，避免误删仓库中的脚本源文件。
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($PSCommandPath -and
        ([System.IO.Path]::GetFullPath($PSCommandPath)).StartsWith(
            $tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        try {
            Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction Stop
        }
        catch {
            Write-Log "清理临时更新脚本失败：$($_.Exception.Message)"
        }
    }

    try {
        $installer.WaitForExit()
        $exitCode = $installer.ExitCode
    }
    catch {
        Write-Log "安装程序已启动，但无法等待其结束：$($_.Exception.Message)"
        exit 0
    }

    if ($exitCode -eq 0) {
        Write-Log "安装程序结束，退出码=0。安装完成时由安装向导启动新版。"
        exit 0
    }

    Write-Log "安装程序结束，退出码=$exitCode（用户取消或安装失败），重新启动当前版本。"
    Restart-App
    exit 0
}
catch {
    $message = $_.Exception.Message
    Write-Log "更新失败：$message"
    Show-ErrorBox("Pure Music 更新未能继续。`n`n$message`n`n日志：$LogPath")
    Restart-App
    exit 1
}
