#Requires -Version 5.1
<#
.SYNOPSIS
    校验 BASS_FFMPEG 插件与 FFmpeg 运行时 DLL 的完整性。

.DESCRIPTION
    逐项检查：
    - 必需 DLL 齐全，且 x64 架构；
    - bass_ffmpeg.dll 导出 BASSplugin，导入 bass.dll 与四个 FFmpeg DLL；
    - 每个 DLL 的导入表都能在系统目录或同目录解析，缺失即报错；
    - 运行时 DLL 总体积不超过预算。
    任何一项失败都以非零退出码结束，错误信息包含具体文件与依赖名。

.PARAMETER BundleDir
    DLL 所在目录，默认 tool/ffmpeg/runtime。

.PARAMETER BassDir
    bass.dll 所在目录，默认仓库 BASS 目录，仅用于确认外部依赖存在。

.PARAMETER MaxSizeMiB
    FFmpeg 运行时 DLL（不含 bass.dll）的总体积上限，默认 80 MiB。

.PARAMETER SkipSizeCheck
    跳过体积上限检查，仅统计并输出。
#>
[CmdletBinding()]
param(
    [string]$BundleDir = (Join-Path $PSScriptRoot "runtime"),
    [string]$BassDir = (Join-Path $PSScriptRoot "..\..\BASS"),
    [double]$MaxSizeMiB = 80,
    [switch]$SkipSizeCheck
)

$ErrorActionPreference = "Stop"

$pluginDll = "bass_ffmpeg.dll"
$ffmpegDlls = @("avcodec-62.dll", "avformat-62.dll", "avutil-60.dll", "swresample-6.dll")
$requiredDlls = @($pluginDll) + $ffmpegDlls
$systemRoot = $env:SystemRoot
$system32 = Join-Path $systemRoot "System32"

function Read-PeInfo([string]$file) {
    $bytes = [System.IO.File]::ReadAllBytes($file)
    if ($bytes.Length -lt 0x40) { throw "文件过小，不是有效的 PE：$file" }
    $e_lfanew = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($e_lfanew -le 0 -or ($e_lfanew + 0x18) -ge $bytes.Length) { throw "PE 头偏移非法：$file" }
    if ([BitConverter]::ToUInt32($bytes, $e_lfanew) -ne 0x00004550) { throw "缺少 PE 签名：$file" }

    $coff = $e_lfanew + 4
    $machine = [BitConverter]::ToUInt16($bytes, $coff)
    $numSections = [BitConverter]::ToUInt16($bytes, $coff + 2)
    $sizeOpt = [BitConverter]::ToUInt16($bytes, $coff + 16)
    $opt = $coff + 20
    $magic = [BitConverter]::ToUInt16($bytes, $opt)
    $ddOffset = if ($magic -eq 0x20B) { $opt + 112 } else { $opt + 96 }
    $exportRva = [BitConverter]::ToUInt32($bytes, $ddOffset)
    $importRva = [BitConverter]::ToUInt32($bytes, $ddOffset + 8)

    $sections = @()
    $secStart = $opt + $sizeOpt
    for ($i = 0; $i -lt $numSections; $i++) {
        $s = $secStart + ($i * 40)
        $sections += [pscustomobject]@{
            VA = [BitConverter]::ToUInt32($bytes, $s + 12)
            VSize = [BitConverter]::ToUInt32($bytes, $s + 8)
            RawSize = [BitConverter]::ToUInt32($bytes, $s + 16)
            RawPtr = [BitConverter]::ToUInt32($bytes, $s + 20)
        }
    }

    function Get-Offset([uint32]$rva) {
        foreach ($s in $sections) {
            $span = [Math]::Max($s.VSize, $s.RawSize)
            if ($rva -ge $s.VA -and $rva -lt ($s.VA + $span)) {
                return [int]($s.RawPtr + ($rva - $s.VA))
            }
        }
        throw "RVA 0x{0:X} 未映射到任何节：{1}" -f $rva, $file
    }

    function Get-Ascii([uint32]$rva) {
        $o = Get-Offset $rva
        $end = $o
        while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
        [System.Text.Encoding]::ASCII.GetString($bytes, $o, $end - $o)
    }

    $exports = @()
    if ($exportRva -ne 0) {
        $eo = Get-Offset $exportRva
        $numNames = [BitConverter]::ToUInt32($bytes, $eo + 24)
        $addrNames = [BitConverter]::ToUInt32($bytes, $eo + 32)
        $nameBase = Get-Offset $addrNames
        for ($i = 0; $i -lt $numNames; $i++) {
            $nameRva = [BitConverter]::ToUInt32($bytes, $nameBase + ($i * 4))
            $exports += Get-Ascii $nameRva
        }
    }

    $imports = @()
    if ($importRva -ne 0) {
        $io = Get-Offset $importRva
        $idx = 0
        while ($true) {
            $d = $io + ($idx * 20)
            if (($d + 20) -gt $bytes.Length) { break }
            $nameRva = [BitConverter]::ToUInt32($bytes, $d + 12)
            if ($nameRva -eq 0) { break }
            $imports += Get-Ascii $nameRva
            $idx++
        }
    }

    [pscustomobject]@{
        Machine = $machine
        Is64Bit = ($magic -eq 0x20B)
        Exports = $exports
        Imports = $imports
    }
}

function Test-SystemLibrary([string]$name) {
    if ($name -like "api-ms-win-*" -or $name -like "ext-ms-*") { return $true }
    return (Test-Path -LiteralPath (Join-Path $system32 $name) -PathType Leaf)
}

if (-not (Test-Path -LiteralPath $BundleDir -PathType Container)) {
    throw "运行时目录不存在：$BundleDir。先运行 tool/ffmpeg/fetch_ffmpeg.ps1 或 tool/ffmpeg/build_minimal_ffmpeg.sh。"
}

$missing = @()
foreach ($name in $requiredDlls) {
    if (-not (Test-Path -LiteralPath (Join-Path $BundleDir $name) -PathType Leaf)) { $missing += $name }
}
if ($missing.Count -gt 0) {
    throw "运行时目录缺少 DLL：$($missing -join ', ')（目录：$BundleDir）"
}

$bassDll = Join-Path $BassDir "bass.dll"
if (-not (Test-Path -LiteralPath $bassDll -PathType Leaf)) {
    throw "未找到 bass.dll：$bassDll"
}

$localNames = @{}
foreach ($name in $requiredDlls) { $localNames[$name.ToLowerInvariant()] = $true }

# MSYS2 运行时不得随包分发：裁剪构建要求 libwinpthread/libgcc/libstdc++ 全部静态链接。
$msys2Runtime = @(
    "libwinpthread-1.dll",
    "libgcc_s_seh-1.dll",
    "libgcc_s_dw2-1.dll",
    "libstdc++-6.dll"
)

$info = @{}
foreach ($name in $requiredDlls) {
    $path = Join-Path $BundleDir $name
    $pe = Read-PeInfo $path
    if ($pe.Machine -ne 0x8664 -or -not $pe.Is64Bit) {
        throw "$name 不是 x64 PE32+（machine=0x{0:X}，PE32+={1}）：$path" -f $pe.Machine, $pe.Is64Bit
    }
    $info[$name] = $pe
}

$pluginInfo = $info[$pluginDll]
if ($pluginInfo.Exports -notcontains "BASSplugin") {
    throw "$pluginDll 未导出 BASSplugin，不能作为 BASS 插件加载"
}
foreach ($expected in @("bass.dll") + $ffmpegDlls) {
    if ($pluginInfo.Imports -notcontains $expected) {
        throw "$pluginDll 缺少对 $expected 的导入，插件与运行时 DLL 不匹配"
    }
}

foreach ($name in $requiredDlls) {
    foreach ($dep in $info[$name].Imports) {
        $depKey = $dep.ToLowerInvariant()
        if ($localNames.ContainsKey($depKey)) { continue }
        if ($depKey -eq "bass.dll") { continue }
        if ($msys2Runtime -contains $depKey) {
            throw "$name 依赖 MSYS2 运行时 $dep；裁剪构建必须静态链接 libwinpthread/libgcc/libstdc++"
        }
        if (Test-SystemLibrary $dep) { continue }
        throw "$name 依赖 $dep，但该 DLL 不在 $BundleDir，也不在系统目录；请补齐运行时 DLL"
    }
}

$rows = @()
$totalBytes = [int64]0
foreach ($name in $ffmpegDlls) {
    $length = (Get-Item -LiteralPath (Join-Path $BundleDir $name)).Length
    $totalBytes += $length
    $rows += [pscustomobject]@{ Name = $name; MiB = [Math]::Round($length / 1MB, 2) }
}
$pluginBytes = (Get-Item -LiteralPath (Join-Path $BundleDir $pluginDll)).Length
$totalMiB = [Math]::Round($totalBytes / 1MB, 2)

Write-Host "BASS_FFMPEG 运行时校验通过：$BundleDir" -ForegroundColor Green
$rows | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ("插件 {0}：{1:N2} MiB" -f $pluginDll, ($pluginBytes / 1MB)) -ForegroundColor Gray
Write-Host ("FFmpeg DLL 合计：{0:N2} MiB（{1:N1} MB）" -f $totalMiB, ($totalBytes / 1MB)) -ForegroundColor Gray

if (-not $SkipSizeCheck -and $env:PURE_MUSIC_ALLOW_OVERSIZE_FFMPEG -ne "1" -and $totalMiB -gt $MaxSizeMiB) {
    throw ("FFmpeg 运行时 DLL 体积 {0:N2} MiB 超过上限 {1} MiB；bundled 完整包约 118 MiB，请改用 tool/ffmpeg/build_minimal_ffmpeg.sh 构建裁剪版，或显式设置 -MaxSizeMiB 放宽上限" -f $totalMiB, $MaxSizeMiB)
}
if (-not $SkipSizeCheck -and $totalMiB -gt $MaxSizeMiB) {
    Write-Warning ("FFmpeg 运行时 DLL 体积 {0:N2} MiB 超过预算 {1} MiB（已通过 PURE_MUSIC_ALLOW_OVERSIZE_FFMPEG=1 放行）" -f $totalMiB, $MaxSizeMiB)
}
