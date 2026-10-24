# 随包 FFmpeg

TAK 无法由 BASS 解码。播放前由 Rust 侧调用 `<应用目录>/ffmpeg/ffmpeg.exe`，把首条音频流无损转成 FLAC 缓存。本目录存放构建期准备的 FFmpeg 运行时，二进制不提交到仓库。

## 版本与来源

| 项目 | 值 |
| --- | --- |
| 版本 | FFmpeg 8.1.2 |
| 来源 | `https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-8.1.2-essentials_build.zip` |
| SHA256 | `db580001caa24ac104c8cb856cd113a87b0a443f7bdf47d8c12b1d740584a2ec` |
| 许可 | GPLv3，随包附 `LICENSE` 全文 |
| 源码 | `https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz` |

## 体积实测（8.1.2）

| 方案 | 运行时文件 | 未压缩 |
| --- | --- | --- |
| 预编译静态（essentials，单文件） | `ffmpeg.exe` | 101.9 MB |
| 预编译 shared（ffmpeg.exe + 必需 DLL） | `ffmpeg.exe`、`avcodec-62`、`avdevice-62`、`avfilter-11`、`avformat-62`、`avutil-60`、`swresample-6`、`swscale-9` | 265.3 MB |
| 极简自建（TAK + FLAC） | `ffmpeg.exe` | 3–6 MB（脚本打印实际值） |

预编译静态版压缩包内 `ffmpeg.exe` 为 35.7 MB（deflate）。shared 版只保留 `ffmpeg.exe` 与 4 个 DLL 无法启动：`ffmpeg.exe` 同时导入 `avdevice`、`avfilter`、`swscale`。因此预编译方案选静态单文件。

## 准备运行时

预编译（默认，需联网）：

```powershell
pwsh -File tool/ffmpeg/fetch_ffmpeg.ps1
```

极简自建（MSYS2 MINGW64，体积最小）：

```bash
bash tool/ffmpeg/build_minimal_ffmpeg.sh
```

极简构建只启用 `file` 协议、TAK 解封装/解码、FLAC 编码/封装，以及 `aresample`、`aformat`、`anull`、`buffersrc`/`buffersink` 滤镜，静态链接为单文件，产物落在本目录。构建脚本按源码 SHA256 校验，并检查运行时 DLL 依赖。

`PURE_MUSIC_FFMPEG_DIR` 可指向已准备好的外部 FFmpeg 目录，构建脚本优先使用它。

`tool/ffmpeg` 固定包含 `ffmpeg.exe`、`LICENSE`、`README-ffmpeg.txt` 与版本标记 `ffmpeg-version.txt`（shared 方案另有 DLL）；随包产物只带前三项。

## 构建接入

- `build_windows.ps1` 在 Flutter 构建前准备运行时，并把上述文件复制到产物 `ffmpeg/`；便携包与安装包共用该目录。
- `windows/CMakeLists.txt` 在 install 阶段把 `ffmpeg.exe`、`LICENSE`、`README-ffmpeg.txt` 与可选 DLL 复制到产物。
- `installer/pure_music.iss` 通过 `{SourceDir}\*` 递归收录 `ffmpeg/`，覆盖安装前清理旧 `{app}\ffmpeg`。
- `.github/workflows/build-windows.yml` 默认下载预编译版（带缓存与 SHA256 校验）；`workflow_dispatch` 的 `ffmpeg_variant=minimal` 改为在 CI 内构建极简版。

## 许可证

FFmpeg 以 GPLv3 分发，`LICENSE` 完整保留在运行时目录并随安装包发布。修改或再分发时保留该文件，并按 GPLv3 提供对应源码（版本与源码地址见上表）。
