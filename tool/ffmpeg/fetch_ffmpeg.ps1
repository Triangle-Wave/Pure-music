#Requires -Version 5.1
<#
.SYNOPSIS
    准备 BASS_FFMPEG 插件与 FFmpeg 共享库，供 TAK 原生解码使用。

.DESCRIPTION
    TAK 由 BASS 的 bass_ffmpeg.dll 插件解码，插件通过 FFmpeg 的共享库工作，
    不再使用 ffmpeg.exe 转码。脚本把运行时 DLL 收拢到 tool/ffmpeg/runtime，
    安装阶段由 CMake 复制到应用的 dll/BASS 目录。

    两种来源：
    - bundled：下载 BASS_FFMPEG 1.0.0 官方发布包，取其中的 x64 DLL。
      体积约 118 MiB，仅作为应急回退。
    - minimal：使用 tool/ffmpeg/build_minimal_ffmpeg.sh 在 CI 构建的裁剪版
      FFmpeg 共享库（约 25-40 MiB），插件仍来自官方发布包。

    所有下载与产物都按固定 SHA256 校验；校验失败或下载失败以非零退出码结束。

.PARAMETER Variant
    auto（默认）：已有 minimal 产物则复用，否则按 bundled 准备。
    bundled：强制使用官方发布包的完整 FFmpeg DLL。
    minimal：只接受已构建的裁剪版 FFmpeg DLL，缺失时报错并给出构建指引。

.PARAMETER Destination
    运行时 DLL 目录，默认 tool/ffmpeg/runtime。

.PARAMETER ZipPath
    已下载的 BASS_FFMPEG 发布包路径；提供时跳过下载，仍校验 SHA256。

.PARAMETER Proxy
    可选 HTTP 代理，例如 http://127.0.0.1:7890。

.PARAMETER Force
    忽略已有产物，重新准备。

.PARAMETER SkipSizeCheck
    准备阶段跳过体积上限检查。仅用于 CI 先取插件、随后用裁剪构建覆盖 FFmpeg DLL 的流程；
    最终校验（verify_bundle.ps1 默认行为）仍强制体积上限。
#>
[CmdletBinding()]
param(
    [ValidateSet("auto", "bundled", "minimal")]
    [string]$Variant = "auto",
    [string]$Destination = "",
    [string]$ZipPath = "",
    [string]$Proxy = "",
    [switch]$Force,
    [switch]$SkipSizeCheck
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$releaseTag = "1.0.0"
$releaseZipName = "bass_ffmpeg.zip"
$releaseZipUrl = "https://github.com/pudding-fox/BASS_FFMPEG/releases/download/$releaseTag/$releaseZipName"
$releaseZipSize = 75263893
$releaseZipSha256 = "550b8bd074689212b0272eef7252103fc5f767871e27d18a4fd93945c3c9532c"
$sourceRepo = "https://github.com/pudding-fox/BASS_FFMPEG"

$ffmpegGplUrl = "https://raw.githubusercontent.com/FFmpeg/FFmpeg/n8.1.2/COPYING.GPLv3"
$ffmpegGplSha256 = "8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903"

$pluginDll = "bass_ffmpeg.dll"
$ffmpegDlls = @("avcodec-62.dll", "avformat-62.dll", "avutil-60.dll", "swresample-6.dll")
$expectedDllSha256 = @{
    "bass_ffmpeg.dll"  = "df541ceb263920c3c52e09d8f1a66f2e73ac2a9d41f22cfc3e039813c0575bf5"
    "avcodec-62.dll"   = "86d3a1f2cf5412ef58404dbac891396db5c228174c88e821c10cced78a9ec416"
    "avformat-62.dll"  = "112fac8b2ca3a1d8220cc5f572e9852121c0415cf680e370d9372ac3a7b29bef"
    "avutil-60.dll"    = "554fc27672aee69cb698d4196319a75dafdc460d525ca366383a43853ef84a19"
    "swresample-6.dll" = "7d838d885f0a75abc4728f562da66cc45040b5f949dacddd11c88d01fda8c02b"
}

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $PSScriptRoot "runtime"
}
$markerPath = Join-Path $Destination "ffmpeg-version.txt"
$licensePath = Join-Path $Destination "LICENSE"
$readmePath = Join-Path $Destination "README-ffmpeg.txt"
$noticesPath = Join-Path $Destination "THIRD-PARTY-NOTICES.txt"
$cacheDir = Join-Path $PSScriptRoot ".cache"
$cacheZip = Join-Path $cacheDir ("bass_ffmpeg-{0}.zip" -f $releaseTag)

function Write-Stamp([string]$text) {
    Write-Host $text -ForegroundColor Cyan
}

function Write-Utf8NoBom([string]$path, [string]$content) {
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
}

function Get-RemoteFile([string]$url, [string]$outFile) {
    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            $requestArgs = @{
                Uri             = $url
                OutFile         = $outFile
                UseBasicParsing = $true
                TimeoutSec      = 600
            }
            if (-not [string]::IsNullOrWhiteSpace($Proxy)) { $requestArgs.Proxy = $Proxy }
            Invoke-WebRequest @requestArgs
            if (-not (Test-Path -LiteralPath $outFile -PathType Leaf)) {
                throw "下载没有产生文件"
            }
            return
        }
        catch {
            if ($i -eq $attempts) {
                throw "下载失败（$attempts 次尝试）：$url；$($_.Exception.Message)"
            }
            Write-Warning ("下载失败（第 {0}/{1} 次）：{2}" -f $i, $attempts, $_.Exception.Message)
            Start-Sleep -Seconds (3 * $i)
        }
    }
}

function Get-FileSha256([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "文件不存在：$path"
    }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-FileHash([string]$path, [string]$expected, [string]$label) {
    $actual = Get-FileSha256 $path
    if ($actual -ne $expected) {
        throw "$label SHA256 不匹配：期望 $expected，实际 $actual（$path）"
    }
    return $actual
}

function Test-RuntimeComplete {
    foreach ($name in @($pluginDll) + $ffmpegDlls) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $name) -PathType Leaf)) { return $false }
    }
    if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $noticesPath -PathType Leaf)) { return $false }
    return $true
}

function Get-RuntimeVariant {
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return "" }
    $marker = (Get-Content -LiteralPath $markerPath -Raw).Trim()
    if ($marker -match "variant=shared-minimal") { return "minimal" }
    if ($marker -match ("variant=bundled zip-sha256=" + $releaseZipSha256)) { return "bundled" }
    return ""
}

function Remove-LegacyTranscoder {
    $roots = @($Destination, $PSScriptRoot) | Select-Object -Unique
    foreach ($root in $roots) {
        foreach ($name in @("ffmpeg.exe", "ffprobe.exe", "ffplay.exe")) {
            $legacy = Join-Path $root $name
            if (Test-Path -LiteralPath $legacy -PathType Leaf) {
                Remove-Item -LiteralPath $legacy -Force
                Write-Host "已移除旧的转码器产物：$legacy" -ForegroundColor Yellow
            }
        }
    }
}

function Assert-LicenseText {
    if ((Test-Path -LiteralPath $licensePath -PathType Leaf) -and
        ((Get-FileSha256 $licensePath) -eq $ffmpegGplSha256)) {
        return
    }
    Write-Stamp "下载 FFmpeg GPLv3 许可全文"
    Get-RemoteFile $ffmpegGplUrl $licensePath
    Assert-FileHash $licensePath $ffmpegGplSha256 "FFmpeg GPLv3 许可" | Out-Null
}

function Write-BundleDocs([string]$mode) {
    if ($mode -eq "minimal") {
        $buildLine = "来源：tool/ffmpeg/build_minimal_ffmpeg.sh 在 MSYS2 MINGW64 下构建的 FFmpeg 8.1.2 裁剪共享库。"
        $sizeLine = "只包含音频解封装与解码（含 TAK）、swresample 与 file 协议，不含视频、编码器、滤镜与网络组件。"
    }
    else {
        $buildLine = "来源：BASS_FFMPEG 官方发布包 $releaseTag（$releaseZipUrl）。"
        $sizeLine = "FFmpeg DLL 为官方发布包内的 x64 完整构建，运行时体积约 118 MiB。"
    }

    $readme = @(
        "BASS_FFMPEG 插件与 FFmpeg 运行时（TAK 原生解码）",
        "",
        "插件：bass_ffmpeg.dll $releaseTag",
        $buildLine,
        $sizeLine,
        "发布包 SHA256：$releaseZipSha256",
        "上游仓库：$sourceRepo",
        "FFmpeg 许可：GPLv3，全文见同目录 LICENSE。",
        "",
        "运行时文件：",
        ("  " + (($ffmpegDlls + $pluginDll) -join "`r`n  ")),
        "",
        "安装后位于应用目录的 dll/BASS/，与 bass.dll 同目录，便于 Windows 加载器解析依赖。"
    ) -join "`r`n"
    Write-Utf8NoBom $readmePath ($readme + "`r`n")

    $notices = @(
        "第三方组件说明",
        "",
        "1. BASS_FFMPEG $releaseTag",
        "   项目地址：$sourceRepo",
        "   用途：为 BASS 提供 FFmpeg 解码插件，本项目用它解码 TAK。",
        "   许可状态：上游仓库未提供 LICENSE 文件，也未在源码头部声明许可证。",
        "   再分发前需要向作者取得授权，或改用自行实现的插件。",
        "",
        "2. FFmpeg 8.x 共享库（avcodec-62 / avformat-62 / avutil-60 / swresample-6）",
        "   项目地址：https://ffmpeg.org/",
        "   许可：GPLv3，全文见同目录 LICENSE。",
        "",
        "3. BASS 音频引擎",
        "   项目地址：https://www.un4seen.com/",
        "   许可：非商业用途免费，商业用途需要 Un4seen 授权。"
    ) -join "`r`n"
    Write-Utf8NoBom $noticesPath ($notices + "`r`n")
}

function Export-BundledRuntime {
    if (-not [string]::IsNullOrWhiteSpace($ZipPath)) {
        if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
            throw "指定的 BASS_FFMPEG 发布包不存在：$ZipPath"
        }
        $zipToUse = (Resolve-Path -LiteralPath $ZipPath).Path
        Write-Stamp "使用本地发布包：$zipToUse"
    }
    elseif ((Test-Path -LiteralPath $cacheZip -PathType Leaf) -and
        ((Get-FileSha256 $cacheZip) -eq $releaseZipSha256)) {
        $zipToUse = $cacheZip
        Write-Stamp "复用缓存的发布包：$cacheZip"
    }
    else {
        Write-Stamp "下载 BASS_FFMPEG $releaseTag：$releaseZipUrl"
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        if (Test-Path -LiteralPath $cacheZip -PathType Leaf) {
            Remove-Item -LiteralPath $cacheZip -Force
        }
        Get-RemoteFile $releaseZipUrl $cacheZip
        $zipToUse = $cacheZip
    }

    $zipSize = (Get-Item -LiteralPath $zipToUse).Length
    if ($zipSize -ne $releaseZipSize) {
        throw "BASS_FFMPEG 发布包大小不匹配：期望 $releaseZipSize 字节，实际 $zipSize 字节（$zipToUse）"
    }
    Assert-FileHash $zipToUse $releaseZipSha256 "BASS_FFMPEG 发布包" | Out-Null

    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pure-music-bassffmpeg-{0}" -f [Guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        Expand-Archive -LiteralPath $zipToUse -DestinationPath $workDir -Force

        $x64Dir = Join-Path $workDir "bass_ffmpeg\x64"
        if (-not (Test-Path -LiteralPath $x64Dir -PathType Container)) {
            $found = Get-ChildItem -LiteralPath $workDir -Recurse -Directory -Filter "x64" -ErrorAction SilentlyContinue |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $pluginDll) -PathType Leaf } |
                Select-Object -First 1
            if (-not $found) { throw "发布包内未找到 x64/$pluginDll：$zipToUse" }
            $x64Dir = $found.FullName
        }

        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        foreach ($name in @($pluginDll) + $ffmpegDlls) {
            $source = Join-Path $x64Dir $name
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                throw "发布包内缺少 $name：$x64Dir"
            }
            Assert-FileHash $source $expectedDllSha256[$name] "$name" | Out-Null
            Copy-Item -LiteralPath $source -Destination (Join-Path $Destination $name) -Force
            Assert-FileHash (Join-Path $Destination $name) $expectedDllSha256[$name] "$name（复制后）" | Out-Null
        }

        Write-Utf8NoBom $markerPath (
            "bass_ffmpeg=$releaseTag variant=bundled zip-sha256=$releaseZipSha256`r`n"
        )
    }
    finally {
        if (Test-Path -LiteralPath $workDir) {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-MinimalRuntime {
    $missing = @()
    foreach ($name in @($pluginDll) + $ffmpegDlls) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $name) -PathType Leaf)) { $missing += $name }
    }
    if ($missing.Count -gt 0) {
        throw ("minimal 运行时尚未就绪，缺少：{0}。先执行 tool/ffmpeg/build_minimal_ffmpeg.sh（MSYS2 MINGW64），或改用 -Variant bundled。" -f ($missing -join ", "))
    }
    if ((Get-RuntimeVariant) -ne "minimal") {
        throw "运行时目录不是 minimal 构建产物（$Destination）。重新执行 build_minimal_ffmpeg.sh，或改用 -Variant bundled。"
    }
    foreach ($name in $ffmpegDlls) {
        if ((Get-Item -LiteralPath (Join-Path $Destination $name)).Length -le 0) {
            throw "$name 为空文件：$Destination"
        }
    }
}

if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
}

$currentVariant = Get-RuntimeVariant

if ($Force) {
    foreach ($name in @($pluginDll) + $ffmpegDlls) {
        $path = Join-Path $Destination $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) { Remove-Item -LiteralPath $markerPath -Force }
    $currentVariant = ""
}

switch ($Variant) {
    "minimal" {
        Assert-MinimalRuntime
        Write-BundleDocs "minimal"
        Assert-LicenseText
        Write-Stamp "minimal 运行时已就绪：$Destination"
    }
    "bundled" {
        $needExport = $true
        $missing = @()
        foreach ($name in @($pluginDll) + $ffmpegDlls) {
            if (-not (Test-Path -LiteralPath (Join-Path $Destination $name) -PathType Leaf)) { $missing += $name }
        }
        if ($currentVariant -eq "bundled" -and $missing.Count -eq 0 -and (Test-RuntimeComplete)) {
            $needExport = $false
            Write-Stamp "bundled 运行时已就绪，跳过下载：$Destination"
        }
        if ($needExport) {
            Export-BundledRuntime
            Write-BundleDocs "bundled"
            Assert-LicenseText
        }
    }
    default {
        if ($currentVariant -eq "minimal" -and (Test-RuntimeComplete)) {
            Write-Stamp "检测到 minimal 运行时，直接复用：$Destination"
        }
        elseif ($currentVariant -eq "bundled" -and (Test-RuntimeComplete)) {
            Write-Stamp "检测到 bundled 运行时，直接复用：$Destination"
        }
        else {
            Export-BundledRuntime
            Write-BundleDocs "bundled"
            Assert-LicenseText
        }
    }
}

Remove-LegacyTranscoder

if (-not (Test-RuntimeComplete)) {
    throw "运行时文件不完整：$Destination"
}

$verifier = Join-Path $PSScriptRoot "verify_bundle.ps1"
if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) {
    throw "校验脚本缺失：$verifier"
}
$verifyArgs = @{ BundleDir = $Destination }
if ($SkipSizeCheck) { $verifyArgs["SkipSizeCheck"] = $true }
& $verifier @verifyArgs
