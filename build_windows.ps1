#Requires -Version 5.1

<#
发布流程分两阶段，先验证完整编译与打包，再打 tag：

  1. 预演：在 CI 构建当前分支并完成便携版、安装版与 Inno 打包，不创建 Release。
       gh workflow run build-windows.yml --ref <branch> -f dry_run=true
     版本号取自 pubspec.yaml，安装器、便携版 zip 与校验和见 Actions artifact
     pure-music-windows-x64-release-dryrun。

  2. 正式发版：预演通过并人工验证安装器与 zip 后，打 tag 并推送。
       git tag vX.Y.Z
       git push origin vX.Y.Z
     tag 版本必须与 pubspec.yaml 一致，否则 release job 的版本校验失败。

  本地等价命令：
       .\build_windows.ps1 -Version X.Y.Z -Mode 4 -NonInteractive
       .\build_windows.ps1 -Version X.Y.Z -Mode 5 -NonInteractive
#>

[CmdletBinding()]
param(
    [string]$Version = "",
    [ValidateSet(0, 1, 2, 3, 4, 5)]
    [int]$Mode = 0,
    [switch]$NonInteractive,
    [switch]$Clean
)

try { chcp 65001 | Out-Null } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ErrorActionPreference = "Stop"

$finalOutputDir = Join-Path $PSScriptRoot "output"
$script:stagingContainer = $null

try {
    $psv = $PSVersionTable.PSVersion
    $enc = [Console]::OutputEncoding.WebName
    Write-Host ("Env: PowerShell {0}, ConsoleEncoding {1}" -f $psv, $enc) -ForegroundColor Gray
} catch {}

function Get-AppSettingsVersion() {
    $pubspec = Join-Path $PSScriptRoot "pubspec.yaml"
    if (Test-Path $pubspec) {
        $content = Get-Content -Path $pubspec -Raw -ErrorAction SilentlyContinue
        if ($content) {
            $m = [regex]::Match($content, '(?m)^\s*version\s*:\s*([^\r\n]+)\s*$')
            if ($m.Success) { return $m.Groups[1].Value.Trim() }
        }
    }
    return ""
}

function ConvertTo-NormalizedVersion([string]$version) {
    $cleanVersion = $version.Trim()
    $cleanVersion = $cleanVersion -replace '^[vV]', ''

    $parts = $cleanVersion -split '\.'
    if ($parts.Count -lt 1 -or $parts.Count -gt 3) {
        throw "Invalid version format: '$version'. Expected X.Y.Z format (e.g., 1.2.3)"
    }

    foreach ($part in $parts) {
        if ($part -notmatch '^\d+$') {
            throw "Version contains non-numeric characters: '$version'. Each segment must be a pure number (e.g., 1.2.3)"
        }
    }

    while ($parts.Count -lt 3) { $parts += "0" }
    $normalized = ($parts -join '.')

    if ($normalized -ne $version) {
        Write-Host "Version auto-normalized: '$version' -> '$normalized'" -ForegroundColor Yellow
    }
    return $normalized
}

function Test-Version([string]$version) {
    $normalized = ConvertTo-NormalizedVersion $version
    $parts = $normalized -split '\.'
    if ([int]$parts[0] -gt 999 -or [int]$parts[1] -gt 999 -or [int]$parts[2] -gt 999) {
        throw "Version segments cannot exceed 999: '$version'"
    }
    Write-Host "Version validation passed: $normalized" -ForegroundColor Green
    return $normalized
}

function Read-Input([string]$prompt) {
    if ($NonInteractive) { return "" }
    $v = Read-Host $prompt
    if ($null -eq $v) { return "" }
    return $v
}

function Wait-ForExitPrompt() {
    if (-not $NonInteractive) {
        Read-Host "Press Enter to exit..." | Out-Null
    }
}

function Invoke-Step([string]$name, [scriptblock]$action) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host ("`n>>> {0}" -f $name) -ForegroundColor Cyan
    & $action
    $sw.Stop()
    Write-Host ("<<< {0} done in {1:n1}s" -f $name, $sw.Elapsed.TotalSeconds) -ForegroundColor Gray
}

function Invoke-RoboCopy([string]$src, [string]$dest) {
    if (-not (Test-Path $src)) { throw "Source not found: $src" }
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
    robocopy $src $dest /E /COPY:DAT /DCOPY:DAT /XJ /NFL /NDL /NJH /NJS /NP /R:2 /W:1 | Out-Null
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed (code=$LASTEXITCODE) src=$src dest=$dest"
    }
    # 成功复制会留下 1-7 的退出码，重置以免后续调用方误判失败。
    $global:LASTEXITCODE = 0
}

function Write-Utf8NoBom([string]$path, [string]$content) {
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
}

function Get-InnoSetupCompilerPath() {
    foreach ($candidate in @(
        "D:\App\Inno Setup 7\ISCC.exe",
        "C:\Program Files\Inno Setup 7\ISCC.exe",
        "C:\Program Files (x86)\Inno Setup 7\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe",
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Get-BandizipCliPath() {
    foreach ($candidate in @(
        "D:\App\Bandizip\bz.exe",
        "C:\Program Files\Bandizip\bz.exe",
        "C:\Program Files (x86)\Bandizip\bz.exe"
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command "bz.exe" -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

$script:BassFfmpegRuntimeDlls = @(
    "bass_ffmpeg.dll",
    "avcodec-62.dll",
    "avformat-62.dll",
    "avutil-60.dll",
    "swresample-6.dll"
)

function Get-BassFfmpegRuntimeDir() {
    $runtimeDir = Join-Path $PSScriptRoot "tool\ffmpeg\runtime"
    if (-not [string]::IsNullOrWhiteSpace($env:PURE_MUSIC_FFMPEG_DIR)) {
        $runtimeDir = $env:PURE_MUSIC_FFMPEG_DIR
    }

    $missing = @($script:BassFfmpegRuntimeDlls | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $runtimeDir $_) -PathType Leaf)
    })
    if ($missing.Count -gt 0) {
        $fetcher = Join-Path $PSScriptRoot "tool\ffmpeg\fetch_ffmpeg.ps1"
        if (-not (Test-Path -LiteralPath $fetcher -PathType Leaf)) {
            throw "BASS_FFMPEG runtime missing ($($missing -join ', ')) and fetch script not found: $fetcher"
        }
        Write-Host ("BASS_FFMPEG runtime missing ({0}); preparing it." -f ($missing -join ', ')) -ForegroundColor Yellow
        & $fetcher
    }

    $stillMissing = @($script:BassFfmpegRuntimeDlls | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $runtimeDir $_) -PathType Leaf)
    })
    if ($stillMissing.Count -gt 0) {
        throw "BASS_FFMPEG runtime is incomplete after preparation: $($stillMissing -join ', ') in $runtimeDir"
    }

    $verifier = Join-Path $PSScriptRoot "tool\ffmpeg\verify_bundle.ps1"
    if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) {
        throw "BASS_FFMPEG verifier not found: $verifier"
    }
    & $verifier -BundleDir $runtimeDir
    return $runtimeDir
}

function Test-BassFfmpegSizeBudget([string]$bassDir) {
    $ffmpegBytes = 0
    foreach ($name in $script:BassFfmpegRuntimeDlls | Where-Object { $_ -ne "bass_ffmpeg.dll" }) {
        $path = Join-Path $bassDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "BASS_FFMPEG runtime is missing $name in $bassDir"
        }
        $ffmpegBytes += (Get-Item -LiteralPath $path).Length
    }
    $ffmpegMiB = $ffmpegBytes / 1MB
    Write-Host ("Bundled FFmpeg DLLs: {0:N2} MiB" -f $ffmpegMiB) -ForegroundColor Gray
    if ($ffmpegMiB -gt 80 -and $env:PURE_MUSIC_ALLOW_OVERSIZE_FFMPEG -ne "1") {
        throw ("FFmpeg DLLs exceed the 80 MiB budget ({0:N2} MiB). Use the trimmed shared build from tool/ffmpeg/build_minimal_ffmpeg.sh." -f $ffmpegMiB)
    }
    if ($ffmpegMiB -gt 80) {
        Write-Warning ("FFmpeg DLLs exceed the 80 MiB budget ({0:N2} MiB) but PURE_MUSIC_ALLOW_OVERSIZE_FFMPEG=1 is set." -f $ffmpegMiB)
    }
}

function Copy-BassFfmpegRuntime([string]$sourceDir, [string]$appDir) {
    $bassDestDir = Join-Path $appDir "dll\BASS"
    New-Item -ItemType Directory -Force -Path $bassDestDir | Out-Null
    foreach ($name in $script:BassFfmpegRuntimeDlls) {
        $source = Join-Path $sourceDir $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "BASS_FFMPEG runtime is missing $name in $sourceDir"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $bassDestDir $name) -Force
    }

    $docDestDir = Join-Path $appDir "ffmpeg"
    New-Item -ItemType Directory -Force -Path $docDestDir | Out-Null
    foreach ($name in @("LICENSE", "README-ffmpeg.txt", "THIRD-PARTY-NOTICES.txt")) {
        $source = Join-Path $sourceDir $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "BASS_FFMPEG runtime is missing $name in $sourceDir"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $docDestDir $name) -Force
    }

    Test-BassFfmpegSizeBudget $bassDestDir
}

function Set-CompileParallelism() {
    $logical = [Environment]::ProcessorCount
    if ($logical -lt 1) { $logical = 4 }
    # Cap parallel jobs so 16GB machines do not thrash.
    $jobCount = [Math]::Max(2, [Math]::Min(6, $logical - 4))
    $env:CARGO_BUILD_JOBS = "$jobCount"
    $env:CMAKE_BUILD_PARALLEL_LEVEL = "$jobCount"
    Write-Host ("Compile parallelism: jobs={0} (logical={1})" -f $jobCount, $logical) -ForegroundColor Gray
}

function Optimize-FlutterIconFonts([string]$appDir) {
    $assetsDir = Join-Path $appDir "data\flutter_assets"
    $manifestPath = Join-Path $assetsDir "FontManifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return }

    $removedBytes = [int64]0
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $kept = @()
    foreach ($entry in @($manifest)) {
        if ($entry.family -match "MaterialSymbols(Rounded|Sharp)$") {
            foreach ($font in @($entry.fonts)) {
                $rel = [string]$font.asset
                if ([string]::IsNullOrWhiteSpace($rel)) { continue }
                $filePath = Join-Path $assetsDir ($rel -replace "/", "\")
                if (Test-Path -LiteralPath $filePath -PathType Leaf) {
                    $removedBytes += (Get-Item -LiteralPath $filePath).Length
                    Remove-Item -LiteralPath $filePath -Force
                }
            }
            continue
        }
        $kept += $entry
    }
    if ($kept.Count -eq 0) { return }
    $parts = @()
    foreach ($entry in $kept) {
        $fontParts = @()
        foreach ($font in @($entry.fonts)) {
            $asset = ([string]$font.asset).Replace("\", "\\").Replace('"', '\"')
            $fontParts += ('{{"asset":"{0}"}}' -f $asset)
        }
        $family = ([string]$entry.family).Replace("\", "\\").Replace('"', '\"')
        $parts += ('{{"family":"{0}","fonts":[{1}]}}' -f $family, ($fontParts -join ","))
    }
    Write-Utf8NoBom $manifestPath ("[{0}]" -f ($parts -join ","))
    if ($removedBytes -gt 0) {
        Write-Host ("Removed unused icon fonts: {0:N1} MB" -f ($removedBytes / 1MB)) -ForegroundColor Gray
    }
}

function Assert-PathWithin([string]$path, [string]$parent) {
    $fullPath = [System.IO.Path]::GetFullPath($path).TrimEnd('\')
    $fullParent = [System.IO.Path]::GetFullPath($parent).TrimEnd('\') + '\'
    if (-not ($fullPath + '\').StartsWith($fullParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the expected directory: $fullPath"
    }
}

function Update-PubspecVersion([string]$version) {
    $pubspecPath = Join-Path $PSScriptRoot "pubspec.yaml"
    if (-not (Test-Path $pubspecPath)) { throw "pubspec.yaml not found." }

    $content = Get-Content -Path $pubspecPath -Raw -Encoding UTF8
    $pattern = [regex]::new('(?m)^version\s*:\s*[^\r\n]+$')
    if (-not $pattern.IsMatch($content)) {
        throw "Version field not found in pubspec.yaml."
    }
    $content = $pattern.Replace($content, "version: $version", 1)
    [System.IO.File]::WriteAllText($pubspecPath, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Synced pubspec.yaml: version=$version" -ForegroundColor Gray
}

function Update-RunnerRcVersion([string]$version) {
    $runnerRcPath = Join-Path $PSScriptRoot "windows\runner\Runner.rc"
    if (-not (Test-Path $runnerRcPath)) {
        Write-Warning "Runner.rc not found at $runnerRcPath, skipping version sync."
        return
    }

    $parts = $version -split '\.'
    $major = $parts[0]
    $minor = $parts[1]
    $patch = $parts[2]
    $build = "0"

    $content = Get-Content -Path $runnerRcPath -Raw -Encoding UTF8
    $content = $content -replace '(?m)^#define\s+VERSION_AS_NUMBER\s+[\d,]+$', "#define VERSION_AS_NUMBER $major,$minor,$patch,$build"
    $content = $content -replace '(?m)^#define\s+PRODUCT_VERSION\s+"[^"]*"', "#define PRODUCT_VERSION `"$major.$minor.$patch`""
    $content = $content -replace '(?m)^#define\s+FILE_VERSION_STR\s+"[^"]*"', "#define FILE_VERSION_STR `"$major.$minor.$patch.$build`""

    Set-Content -Path $runnerRcPath -Value $content -Encoding UTF8 -NoNewline
    Write-Host "Synced Runner.rc: ProductVersion=$major.$minor.$patch, FileVersion=$major.$minor.$patch.$build" -ForegroundColor Gray
}

function New-StagingContainer() {
    if (-not (Test-Path -LiteralPath $finalOutputDir)) {
        New-Item -ItemType Directory -Force -Path $finalOutputDir | Out-Null
    }
    $script:stagingContainer = Join-Path $finalOutputDir (".staging-{0}" -f [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $script:stagingContainer | Out-Null
    return $script:stagingContainer
}

function Remove-StagingContainer() {
    if ($script:stagingContainer -and (Test-Path -LiteralPath $script:stagingContainer)) {
        Assert-PathWithin $script:stagingContainer $finalOutputDir
        Remove-Item -LiteralPath $script:stagingContainer -Recurse -Force -ErrorAction SilentlyContinue
        $script:stagingContainer = $null
    }
}

function Update-BuildVersionFiles([string]$version) {
    Update-PubspecVersion $version
    Update-RunnerRcVersion $version
}

function Assert-FlutterAvailable() {
    if (Get-Command "flutter" -ErrorAction SilentlyContinue) { return }
    throw "flutter command not found in PATH. Compile modes 1/2/3 require Flutter; package-only modes 4/5 reuse an existing build and do not."
}

function Invoke-Build([string]$version, [bool]$isPortable) {
    Assert-FlutterAvailable

    Invoke-Step "pub get" {
        $needPubGet = $true
        $packageConfig = Join-Path $PSScriptRoot ".dart_tool\package_config.json"
        if ((Test-Path (Join-Path $PSScriptRoot "pubspec.lock")) -and (Test-Path $packageConfig)) {
            $yamlTime = (Get-Item (Join-Path $PSScriptRoot "pubspec.yaml")).LastWriteTime
            $lockTime = (Get-Item (Join-Path $PSScriptRoot "pubspec.lock")).LastWriteTime
            if ($yamlTime -le $lockTime) { $needPubGet = $false }
        }
        if ($needPubGet) {
            Push-Location $PSScriptRoot
            try {
                flutter pub get --offline
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Offline dependency resolution failed; retrying online."
                    flutter pub get
                    if ($LASTEXITCODE -ne 0) { throw "Failed to resolve Flutter dependencies." }
                }
            }
            finally { Pop-Location }
        }
        else {
            Write-Host "Dependencies up to date; skipping pub get." -ForegroundColor Gray
        }
    }

    $appIconSource = Join-Path $PSScriptRoot "app_icon.ico"
    $appIconResourceDest = Join-Path $PSScriptRoot "windows\runner\resources\app_icon.ico"
    if (Test-Path $appIconSource) {
        Write-Host "Updating application icon..." -ForegroundColor Cyan
        Copy-Item -Path $appIconSource -Destination $appIconResourceDest -Force
    }
    else {
        Write-Warning "app_icon.ico not found in project root."
    }

    Invoke-Step "sync version files" {
        Update-BuildVersionFiles $version
    }

    Set-CompileParallelism

    # CMake 的 install 阶段会把 BASS_FFMPEG 运行时复制进产物。
    Invoke-Step "prepare BASS_FFMPEG runtime" {
        Get-BassFfmpegRuntimeDir | Out-Null
    }

    Invoke-Step "flutter build windows" {
        if ($Clean) {
            Write-Host "Clean build requested; removing previous Windows build cache." -ForegroundColor Yellow
            $pluginSymlinkDir = Join-Path $PSScriptRoot "windows\flutter\ephemeral\.plugin_symlinks"
            if (Test-Path $pluginSymlinkDir) {
                Assert-PathWithin $pluginSymlinkDir $PSScriptRoot
                Remove-Item -LiteralPath $pluginSymlinkDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            $buildDir = Join-Path $PSScriptRoot "build\windows"
            if (Test-Path $buildDir) {
                Assert-PathWithin $buildDir $PSScriptRoot
                Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            Write-Host "Incremental build (pass -Clean to wipe build\windows)." -ForegroundColor Gray
        }

        $flutterArgs = @(
            "build",
            "windows",
            "--release",
            "--no-pub",
            "--tree-shake-icons",
            "--dart-define=APP_VERSION=$version",
            "--dart-define=PORTABLE_BUILD=$($isPortable.ToString().ToLowerInvariant())"
        )
        Push-Location $PSScriptRoot
        try {
            flutter @flutterArgs
            if ($LASTEXITCODE -ne 0) { throw "Flutter Windows build failed with exit code $LASTEXITCODE." }
        }
        finally { Pop-Location }
    }
}

function New-AppPackage([string]$artifactRoot, [string]$version, [bool]$isPortable) {
    $buildDir = Join-Path $PSScriptRoot "build\windows\x64\runner\Release"
    if (-not (Test-Path -LiteralPath (Join-Path $buildDir "pure_music.exe") -PathType Leaf)) {
        throw "Build output is incomplete: $buildDir"
    }

    $finalAppDir = $artifactRoot
    $finalDllDir = Join-Path $finalAppDir "dll"
    New-Item -ItemType Directory -Force -Path $finalDllDir | Out-Null

    Invoke-Step "copy build artifacts" {
        Invoke-RoboCopy $buildDir $finalAppDir
    }

    Write-Host "Normalizing plugin DLL locations..." -ForegroundColor Cyan
    Get-ChildItem -Path $finalAppDir -Recurse -File -Filter "*_plugin.dll" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Directory.FullName -eq (Get-Item $finalAppDir).FullName) { return }
        Move-Item -Path $_.FullName -Destination (Join-Path $finalAppDir $_.Name) -Force
    }
    foreach ($pattern in @("msvcp*.dll", "vcruntime*.dll")) {
        Get-ChildItem -Path $finalAppDir -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Directory.FullName -eq (Get-Item $finalAppDir).FullName) { return }
            Move-Item -Path $_.FullName -Destination (Join-Path $finalAppDir $_.Name) -Force
        }
    }

    Write-Host "Organizing DLLs into: $finalDllDir" -ForegroundColor Cyan
    function Test-DllInRoot([string]$name) {
        if ($name -eq "flutter_windows.dll") { return $true }
        if ($name -like "*_plugin.dll") { return $true }
        if ($name -like "msvcp*.dll") { return $true }
        if ($name -like "vcruntime*.dll") { return $true }
        return $false
    }
    Get-ChildItem -Path $finalAppDir -File -Filter "*.dll" | ForEach-Object {
        if (Test-DllInRoot $_.Name) { return }
        Move-Item -Path $_.FullName -Destination (Join-Path $finalDllDir $_.Name) -Force
    }

    Get-ChildItem -Path $finalAppDir -Recurse -File -Include "*.pdb","*.ilk","*.exp","*.lib","native_assets.json" -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
    }

    Invoke-Step "copy BASS DLLs" {
        $bassSrcDir = Join-Path $PSScriptRoot "BASS"
        $bassDestDir = Join-Path $finalDllDir "BASS"
        if (-not (Test-Path $bassSrcDir)) {
            throw "BASS directory not found in project root: $bassSrcDir"
        }
        New-Item -ItemType Directory -Force -Path $bassDestDir | Out-Null
        foreach ($dll in @("bass.dll", "basswasapi.dll", "bass_fx.dll", "bassmix.dll")) {
            $src = Join-Path $bassSrcDir $dll
            if (-not (Test-Path $src)) { throw "$dll not found in source BASS folder: $bassSrcDir" }
            Copy-Item -Path $src -Destination (Join-Path $bassDestDir $dll) -Force
        }
        Invoke-RoboCopy $bassSrcDir $bassDestDir
        foreach ($dll in @("bass.dll", "basswasapi.dll", "bass_fx.dll", "bassmix.dll")) {
            if (-not (Test-Path "$bassDestDir\$dll")) { throw "Missing BASS DLL: $dll" }
        }
    }

    Invoke-Step "copy desktop_lyric" {
        $desktopLyricSrc = Join-Path $PSScriptRoot "desktop_lyric"
        $desktopLyricDest = Join-Path $finalAppDir "desktop_lyric"
        if (-not (Test-Path $desktopLyricSrc)) {
            throw "desktop_lyric directory not found in project root: $desktopLyricSrc"
        }
        Invoke-RoboCopy $desktopLyricSrc $desktopLyricDest
    }

    # TAK 原生解码依赖随包携带的 BASS_FFMPEG 插件与 FFmpeg 共享库。
    # 编译产物已由 CMake install 放入 dll/BASS 与 ffmpeg；打包作业没有准备目录时直接复用。
    Invoke-Step "verify BASS_FFMPEG runtime" {
        $missing = @()
        foreach ($name in $script:BassFfmpegRuntimeDlls) {
            if (-not (Test-Path -LiteralPath (Join-Path $finalAppDir "dll\BASS\$name") -PathType Leaf)) {
                $missing += "dll\BASS\$name"
            }
        }
        foreach ($name in @("LICENSE", "README-ffmpeg.txt", "THIRD-PARTY-NOTICES.txt")) {
            if (-not (Test-Path -LiteralPath (Join-Path $finalAppDir "ffmpeg\$name") -PathType Leaf)) {
                $missing += "ffmpeg\$name"
            }
        }
        if ($missing.Count -gt 0) {
            Write-Host ("Build output lacks BASS_FFMPEG files ({0}); copying from the prepared runtime." -f ($missing -join ', ')) -ForegroundColor Yellow
            $ffmpegSrc = Get-BassFfmpegRuntimeDir
            Copy-BassFfmpegRuntime $ffmpegSrc $finalAppDir
        }
        else {
            Test-BassFfmpegSizeBudget (Join-Path $finalAppDir "dll\BASS")
        }
    }

    # 安装版应用内更新依赖该助手等待主程序退出，再启动安装程序。
    Invoke-Step "copy installer update helper" {
        $helperSource = Join-Path $PSScriptRoot "tool\apply_installer_update.ps1"
        if (-not (Test-Path -LiteralPath $helperSource -PathType Leaf)) {
            throw "Installer update helper not found: $helperSource"
        }
        $helperDir = Join-Path $finalAppDir "tool"
        New-Item -ItemType Directory -Force -Path $helperDir | Out-Null
        Copy-Item -LiteralPath $helperSource -Destination (
            Join-Path $helperDir "apply_installer_update.ps1"
        ) -Force
    }

    Invoke-Step "strip unused icon fonts" {
        Optimize-FlutterIconFonts $finalAppDir
    }

    # 安装版的用户数据根固定为 exe 旁的 user_data。产物中保留空目录用于检查布局；
    # 不放占位文件，导入脚本要求目标目录为空才会导入便携版或旧版安装数据。
    if (-not $isPortable) {
        $userDataDir = Join-Path $finalAppDir "user_data"
        New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null
    }

    return $finalAppDir
}

function Test-KeyFiles([string]$appDir) {
    $required = @(
        "pure_music.exe",
        "flutter_windows.dll",
        "data\app.so",
        "dll\rust_lib_pure_music.dll",
        "dll\BASS\bass.dll",
        "dll\BASS\basswasapi.dll",
        "dll\BASS\bass_fx.dll",
        "dll\BASS\bassmix.dll",
        "dll\BASS\bass_ffmpeg.dll",
        "dll\BASS\avcodec-62.dll",
        "dll\BASS\avformat-62.dll",
        "dll\BASS\avutil-60.dll",
        "dll\BASS\swresample-6.dll",
        "ffmpeg\LICENSE",
        "ffmpeg\README-ffmpeg.txt",
        "ffmpeg\THIRD-PARTY-NOTICES.txt",
        "tool\apply_installer_update.ps1",
        "desktop_lyric\desktop_lyric.exe"
    )
    $missing = @()
    foreach ($rp in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $appDir $rp) -PathType Leaf)) { $missing += $rp }
    }
    $pluginCount = @(Get-ChildItem -LiteralPath $appDir -File -Filter "*_plugin.dll" -ErrorAction SilentlyContinue).Count
    if ($pluginCount -eq 0) { $missing += "*_plugin.dll (none found)" }

    if ($missing.Count -gt 0) {
        throw "Package missing required files: $($missing -join ', ')"
    }
    Write-Host "Key file check passed." -ForegroundColor Green
}

function Read-InnoSections([string]$path) {
    $sections = @{}
    $current = ""
    foreach ($raw in [System.IO.File]::ReadAllLines($path)) {
        $line = $raw.Trim()
        if ($line.Length -eq 0) { continue }
        if ($line.StartsWith(";") -or $line.StartsWith("#")) { continue }
        $header = [regex]::Match($line, '^\[(.+)\]$')
        if ($header.Success) {
            $current = $header.Groups[1].Value.ToLowerInvariant()
            if (-not $sections.ContainsKey($current)) { $sections[$current] = @() }
            continue
        }
        if (-not $current) { continue }
        $sections[$current] += $line
    }
    return $sections
}

function Assert-InstallerScriptLayout([string]$issPath) {
    $sections = Read-InnoSections $issPath

    foreach ($line in @($sections["installdelete"])) {
        $name = [regex]::Match($line, 'Name:\s*"([^"]*)"').Groups[1].Value
        if ($name -match 'user_data') {
            throw "Installer [InstallDelete] must not touch user_data: $line"
        }
    }

    $dirs = @($sections["dirs"])
    if (-not ($dirs | Where-Object { $_ -match 'Name:\s*"\{app\}\\user_data"' })) {
        throw "Installer [Dirs] must declare {app}\user_data"
    }

    $files = @($sections["files"])
    if (-not ($files | Where-Object { $_ -match 'Excludes:.*user_data' })) {
        throw "Installer [Files] must exclude user_data so an install never overwrites user data"
    }

    Write-Host "Installer data layout check passed." -ForegroundColor Green
}

function Assert-InstallerUserDataDir([string]$appDir) {
    $userDataDir = Join-Path $appDir "user_data"
    if (-not (Test-Path -LiteralPath $userDataDir -PathType Container)) {
        throw "Installer package is missing the user_data directory: $userDataDir"
    }
    $entries = @(Get-ChildItem -LiteralPath $userDataDir -Force)
    if ($entries.Count -gt 0) {
        throw "user_data in the installer package must stay empty: $(($entries | ForEach-Object { $_.Name }) -join ', ')"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $appDir "data\app.so") -PathType Leaf)) {
        throw "Installer package is missing Flutter runtime resources: $appDir\data"
    }
    Write-Host "Installer user_data layout check passed." -ForegroundColor Green
}

function Write-PortableIntegrityFiles([string]$artifactRoot, [string]$version) {
    $manifestEntries = @()
    $checksumLines = @()
    $excludedNames = @("package_manifest.json", "SHA256SUMS.txt")
    $supportDir = Join-Path $artifactRoot ".update"

    Get-ChildItem -LiteralPath $artifactRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
        if ($excludedNames -contains $_.Name) { return }
        $relativePath = $_.FullName.Substring($artifactRoot.Length).TrimStart('\').Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifestEntries += [ordered]@{
            path = $relativePath
            size = $_.Length
            sha256 = $hash
        }
        $checksumLines += "{0} *{1}" -f $hash, $relativePath
    }

    $manifest = [ordered]@{
        version = $version
        files = $manifestEntries
    }
    Write-Utf8NoBom (
        Join-Path $supportDir "package_manifest.json"
    ) (($manifest | ConvertTo-Json -Depth 5) + "`n")
    Write-Utf8NoBom (
        Join-Path $supportDir "SHA256SUMS.txt"
    ) (($checksumLines -join "`n") + "`n")
}

function Set-PortableSupportHidden([string]$artifactRoot) {
    $supportDir = Join-Path $artifactRoot ".update"
    if (-not (Test-Path -LiteralPath $supportDir -PathType Container)) {
        throw "Portable update directory not found: $supportDir"
    }

    Get-ChildItem -LiteralPath $supportDir -Force -Recurse | ForEach-Object {
        $_.Attributes = $_.Attributes -bor [System.IO.FileAttributes]::Hidden
    }
    $directory = Get-Item -LiteralPath $supportDir -Force
    $directory.Attributes = $directory.Attributes -bor [System.IO.FileAttributes]::Hidden
}

function Add-ZipCompressionTypes() {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}

function Set-ZipPortableSupportHidden([string]$zipPath) {
    Add-ZipCompressionTypes
    $zip = [System.IO.Compression.ZipFile]::Open(
        $zipPath,
        [System.IO.Compression.ZipArchiveMode]::Update
    )
    try {
        $directoryEntry = @($zip.Entries) | Where-Object {
            $_.FullName -eq ".update/"
        } | Select-Object -First 1
        if ($null -eq $directoryEntry) {
            $directoryEntry = $zip.CreateEntry(".update/")
        }
        $directoryEntry.ExternalAttributes =
            ([int][System.IO.FileAttributes]::Hidden -bor
            [int][System.IO.FileAttributes]::Directory)

        foreach ($entry in @($zip.Entries)) {
            if ($entry.FullName.StartsWith(
                    ".update/",
                    [System.StringComparison]::OrdinalIgnoreCase
                ) -and -not $entry.FullName.EndsWith("/")) {
                $entry.ExternalAttributes = [int][System.IO.FileAttributes]::Hidden
            }
        }
    }
    finally {
        $zip.Dispose()
    }
}

function New-PortablePackage([string]$version, [bool]$buildFirst, [bool]$makeZip) {
    if ($buildFirst) { Invoke-Build $version $true }
    $artifactName = "pure_music_{0}_release_portable" -f $version
    $publishedRoot = Join-Path $finalOutputDir $artifactName
    $publishedZip = Join-Path $finalOutputDir "$artifactName.zip"
    $publishedChecksum = "$publishedZip.sha256"

    if (Test-Path -LiteralPath $publishedRoot) {
        Assert-PathWithin $publishedRoot $finalOutputDir
        Remove-Item -LiteralPath $publishedRoot -Recurse -Force
    }
    foreach ($path in @($publishedZip, $publishedChecksum)) {
        if ($makeZip -and (Test-Path -LiteralPath $path)) {
            Assert-PathWithin $path $finalOutputDir
            Remove-Item -LiteralPath $path -Force
        }
    }

    $staging = New-StagingContainer
    try {
        $artifactRoot = Join-Path $staging $artifactName
        New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
        $finalAppDir = New-AppPackage $artifactRoot $version $true

        Invoke-Step "copy portable update scripts" {
            $supportDir = Join-Path $artifactRoot ".update"
            New-Item -ItemType Directory -Force -Path $supportDir | Out-Null
            foreach ($fileName in @(
                "PORTABLE_README.txt",
                "upgrade_from_previous.ps1",
                "apply_portable_update.ps1"
            )) {
                $source = Join-Path $PSScriptRoot "tool\$fileName"
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                    throw "Portable update file not found: $source"
                }
                Copy-Item -LiteralPath $source -Destination (
                    Join-Path $supportDir $fileName
                ) -Force
            }
        }
        Write-PortableIntegrityFiles $artifactRoot $version

        Invoke-Step "validate portable package" {
            Test-KeyFiles $finalAppDir
            foreach ($fileName in @(
                "PORTABLE_README.txt",
                "upgrade_from_previous.ps1",
                "apply_portable_update.ps1"
            )) {
                $supportFile = Join-Path $artifactRoot ".update\$fileName"
                if (-not (Test-Path -LiteralPath $supportFile -PathType Leaf)) {
                    throw "Portable update file missing from package: $supportFile"
                }
            }
        }

        if ($makeZip) {
            Invoke-Step "create portable archive" {
                $bz = Get-BandizipCliPath
                if ($bz) {
                    Push-Location $artifactRoot
                    try {
                        & $bz c -y -l:9 -r -fmt:zip $publishedZip *
                        if ($LASTEXITCODE -ne 0) {
                            throw "Bandizip failed with exit code $LASTEXITCODE."
                        }
                    }
                    finally { Pop-Location }
                }
                else {
                    Add-ZipCompressionTypes
                    [System.IO.Compression.ZipFile]::CreateFromDirectory(
                        $artifactRoot,
                        $publishedZip,
                        [System.IO.Compression.CompressionLevel]::Optimal,
                        $false
                    )
                }
                if (-not (Test-Path -LiteralPath $publishedZip -PathType Leaf)) {
                    throw "Portable zip was not created: $publishedZip"
                }
                Set-ZipPortableSupportHidden $publishedZip
                $hash = (Get-FileHash -LiteralPath $publishedZip -Algorithm SHA256).Hash.ToLowerInvariant()
                Write-Utf8NoBom $publishedChecksum (
                    "{0} *{1}`n" -f $hash, [System.IO.Path]::GetFileName($publishedZip)
                )
            }
        }

        # Copy first, then hide .update. Hidden folders are skipped by Copy-Item.
        Copy-Item -LiteralPath $artifactRoot -Destination $publishedRoot -Recurse -Force
        Set-PortableSupportHidden $publishedRoot
    }
    finally {
        Remove-StagingContainer
    }

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Portable package completed successfully." -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Folder:   $publishedRoot" -ForegroundColor Yellow
    if ($makeZip) {
        Write-Host "Archive:  $publishedZip" -ForegroundColor Yellow
        Write-Host "SHA256:   $publishedChecksum" -ForegroundColor Yellow
    }
}

function New-InstallerPackage([string]$version, [bool]$buildFirst) {
    if ($buildFirst) {
        Invoke-Build $version $false
    }
    else {
        Write-Warning "复用的已有产物必须是以 PORTABLE_BUILD=false 编译的安装版，否则数据根会落在 <exe>\data 而不是 <exe>\user_data。"
    }
    $artifactName = "pure_music_{0}_release_installer" -f $version
    $publishedInstaller = Join-Path $finalOutputDir "$artifactName.exe"
    $publishedChecksum = "$publishedInstaller.sha256"

    $innoCompiler = Get-InnoSetupCompilerPath
    if (-not $innoCompiler) {
        throw "Inno Setup compiler not found. Install Inno Setup 7 or add ISCC.exe to PATH."
    }

    $installerScript = Join-Path $PSScriptRoot "installer\pure_music.iss"
    if (-not (Test-Path -LiteralPath $installerScript -PathType Leaf)) {
        throw "Inno Setup script not found: $installerScript"
    }
    Assert-InstallerScriptLayout $installerScript

    $staging = New-StagingContainer
    try {
        $artifactRoot = Join-Path $staging $artifactName
        New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
        $finalAppDir = New-AppPackage $artifactRoot $version $false

        Invoke-Step "validate installer application" {
            Test-KeyFiles $finalAppDir
            Assert-InstallerUserDataDir $finalAppDir
        }

        Invoke-Step "create Inno Setup installer" {
            $compiledOutputDir = Join-Path $staging "compiled"
            New-Item -ItemType Directory -Force -Path $compiledOutputDir | Out-Null
            $innoArgs = @(
                "/DSourceDir=$finalAppDir",
                "/DAppVersion=$version",
                "/O$compiledOutputDir",
                "/F$artifactName",
                $installerScript
            )
            & $innoCompiler @innoArgs
            if ($LASTEXITCODE -ne 0) {
                throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
            }

            $compiledInstaller = Join-Path $compiledOutputDir "$artifactName.exe"
            if (-not (Test-Path -LiteralPath $compiledInstaller -PathType Leaf)) {
                throw "Inno Setup did not create the expected installer."
            }

            foreach ($path in @($publishedInstaller, $publishedChecksum)) {
                if (Test-Path -LiteralPath $path) {
                    Assert-PathWithin $path $finalOutputDir
                    Remove-Item -LiteralPath $path -Force
                }
            }
            Move-Item -LiteralPath $compiledInstaller -Destination $publishedInstaller

            $hash = (Get-FileHash -LiteralPath $publishedInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
            Write-Utf8NoBom $publishedChecksum ("{0} *{1}`n" -f $hash, [System.IO.Path]::GetFileName($publishedInstaller))
        }
    }
    finally {
        Remove-StagingContainer
    }

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Installer completed successfully." -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Installer: $publishedInstaller" -ForegroundColor Yellow
    Write-Host "SHA256:   $publishedChecksum" -ForegroundColor Yellow
}

# ---------- entry ----------

$script:exitCode = 0

trap {
    Remove-StagingContainer
    Write-Host $_.Exception.Message -ForegroundColor Red
    $script:exitCode = 1
    Wait-ForExitPrompt
    exit 1
}

Write-Host "`n===== Pure Music Build =====" -ForegroundColor Cyan
Write-Host "  1. 编译便携版（只出文件夹，不打包）" -ForegroundColor White
Write-Host "  2. 编译便携版并打包 zip" -ForegroundColor White
Write-Host "  3. 编译并制作 Inno Setup 安装器" -ForegroundColor White
Write-Host "  4. 跳过编译，打包已有产物（便携版 zip）" -ForegroundColor White
Write-Host "  5. 跳过编译，使用已有产物制作安装器" -ForegroundColor White
Write-Host "===========================" -ForegroundColor Cyan

if ($Mode -eq 0) {
    $modeInput = (Read-Input "请选择 [1/2/3/4/5]").Trim()
    if ([string]::IsNullOrWhiteSpace($modeInput)) { $modeInput = "2" }
    if ($modeInput -notin @("1", "2", "3", "4", "5")) {
        throw "Invalid selection: $modeInput"
    }
    $selectedMode = [int]$modeInput
}
else {
    $selectedMode = $Mode
}

$defaultVersion = Get-AppSettingsVersion
if ([string]::IsNullOrWhiteSpace($defaultVersion)) { $defaultVersion = "unknown" }

if (-not [string]::IsNullOrWhiteSpace($Version)) {
    $version = $Version.Trim()
}
else {
    $version = (Read-Input "Version (default $defaultVersion)").Trim()
    if ([string]::IsNullOrWhiteSpace($version)) { $version = $defaultVersion }
}
$version = Test-Version $version

# 只有编译模式需要 Flutter；模式 4/5 复用已有构建产物，仅做拷贝与打包。
if ($selectedMode -in @(1, 2, 3)) {
    Assert-FlutterAvailable
}
else {
    Write-Host ("Mode {0}: packaging existing build output; Flutter is not required." -f $selectedMode) -ForegroundColor Gray
}

switch ($selectedMode) {
    1 { New-PortablePackage $version $true $false }
    2 { New-PortablePackage $version $true $true }
    3 { New-InstallerPackage $version $true }
    4 { New-PortablePackage $version $false $true }
    5 { New-InstallerPackage $version $false }
}

Write-Host "The running Pure Music process was not stopped." -ForegroundColor Gray
Wait-ForExitPrompt
exit 0
