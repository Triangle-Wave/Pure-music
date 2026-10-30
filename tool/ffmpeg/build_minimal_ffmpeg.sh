#!/usr/bin/env bash
# 构建 TAK 播放所需的 FFmpeg 8.1.2 裁剪共享库（Windows x64）。
# 运行环境：MSYS2 MINGW64 shell（GitHub Actions 的 msys2/setup-msys2@v2）。
# 产物：tool/ffmpeg/runtime/avcodec-62.dll、avformat-62.dll、avutil-60.dll、swresample-6.dll。
#
# bass_ffmpeg.dll 由 tool/ffmpeg/fetch_ffmpeg.ps1 从官方发布包取得，本脚本只负责 FFmpeg 库。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFMPEG_VERSION="8.1.2"
SOURCE_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SOURCE_SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"

RUNTIME_DIR="${SCRIPT_DIR}/runtime"
BUILD_ROOT="${SCRIPT_DIR}/.build"
ARCHIVE="${BUILD_ROOT}/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SRC_DIR="${BUILD_ROOT}/ffmpeg-${FFMPEG_VERSION}"
OUT_DIR="${BUILD_ROOT}/out"
MARKER="${RUNTIME_DIR}/ffmpeg-version.txt"

DLL_NAMES=("avcodec-62.dll" "avformat-62.dll" "avutil-60.dll" "swresample-6.dll")

# 音频解封装：覆盖 BASS 现有插件（AAC/ALAC/APE/DSD/FLAC/Opus/WebM/WV）与 TAK。
DEMUXERS="aac ac3 aiff ape asf au caf dsf eac3 flac iff matroska mov mp3 mpc mpc8 ogg tak tta wav wv dts oma loas"

DECODERS="aac alac ape flac opus vorbis wavpack dsd_lsbf dsd_msbf dsd_lsbf_planar dsd_msbf_planar"
DECODERS="${DECODERS} mp3 mp3float pcm_s16le pcm_s24le pcm_s32le pcm_f32le pcm_f64le"
DECODERS="${DECODERS} pcm_u8 pcm_s8 pcm_alaw pcm_mulaw pcm_s16be pcm_s24be pcm_s32be"
DECODERS="${DECODERS} wmav1 wmav2 wmapro wmalossless tta mpc7 mpc8 ac3 eac3 dca truehd mlp"
DECODERS="${DECODERS} speex cook tak"

PARSERS="aac aac_latm ac3 dca flac mpegaudio opus tak vorbis"
BSFS="aac_adtstoasc extract_extradata null"

# 共享 DLL 静态链接 MSYS2 运行时：产物不得依赖 libwinpthread-1.dll、libgcc_s_*.dll、libstdc++-6.dll。
# -static 让链接器对目标文件之后的所有 -l（含 configure 探测到的 winpthread）选择静态库，
# 不受 --extra-ldflags 位于链接行前部的影响，对四个 DLL 一致生效。
STATIC_RUNTIME_LDFLAGS="-static -static-libgcc -static-libstdc++"

CONFIGURE_FLAGS=(
  "--arch=x86_64"
  "--target-os=mingw32"
  "--disable-everything"
  "--disable-autodetect"
  "--disable-doc"
  "--disable-debug"
  "--disable-network"
  "--disable-iconv"
  "--disable-zlib"
  "--disable-bzlib"
  "--disable-lzma"
  "--disable-programs"
  "--disable-static"
  "--enable-shared"
  "--enable-small"
  "--disable-pthreads"
  "--enable-w32threads"
  "--enable-protocol=file"
  "--enable-demuxer=${DEMUXERS// /,}"
  "--enable-decoder=${DECODERS// /,}"
  "--enable-parser=${PARSERS// /,}"
  "--enable-bsf=${BSFS// /,}"
  "--extra-ldflags=${STATIC_RUNTIME_LDFLAGS}"
)

CONFIG_HASH="$(printf '%s\n' "${CONFIGURE_FLAGS[@]}" | sha256sum | cut -d' ' -f1)"
MARKER_VALUE="bass_ffmpeg=1.0.0 variant=shared-minimal ffmpeg=${FFMPEG_VERSION} source-sha256=${SOURCE_SHA256} config-sha256=${CONFIG_HASH}"

die() {
  echo "错误：$*" >&2
  exit 1
}

if [[ -f "${MARKER}" ]] && grep -qxF "${MARKER_VALUE}" "${MARKER}"; then
  echo "裁剪版 FFmpeg 已就绪，跳过构建：${RUNTIME_DIR}"
  exit 0
fi

command -v gcc >/dev/null 2>&1 || die "未找到 gcc，请在 MSYS2 MINGW64 shell 中运行"
command -v make >/dev/null 2>&1 || die "未找到 make，请安装 msys/make"
command -v sha256sum >/dev/null 2>&1 || die "未找到 sha256sum"
command -v objdump >/dev/null 2>&1 || die "未找到 objdump，请安装 mingw-w64-x86_64-binutils"

if [[ -z "${MSYSTEM:-}" || "${MSYSTEM}" != "MINGW64" ]]; then
  die "请在 MSYS2 MINGW64 shell 中运行（当前 MSYSTEM=${MSYSTEM:-未设置}）"
fi

mkdir -p "${BUILD_ROOT}" "${RUNTIME_DIR}"

if [[ ! -f "${ARCHIVE}" ]] || ! printf '%s  %s\n' "${SOURCE_SHA256}" "${ARCHIVE}" | sha256sum -c --status; then
  echo "下载 FFmpeg 源码：${SOURCE_URL}"
  rm -f "${ARCHIVE}.part"
  curl -L --fail --silent --show-error --retry 3 --retry-all-errors \
    -o "${ARCHIVE}.part" "${SOURCE_URL}" || die "源码下载失败：${SOURCE_URL}"
  mv "${ARCHIVE}.part" "${ARCHIVE}"
fi
printf '%s  %s\n' "${SOURCE_SHA256}" "${ARCHIVE}" | sha256sum -c - || die "源码 SHA256 校验失败"

rm -rf "${SRC_DIR}" "${OUT_DIR}"
tar -xf "${ARCHIVE}" -C "${BUILD_ROOT}" || die "源码解压失败"
cd "${SRC_DIR}"

echo "配置 FFmpeg ${FFMPEG_VERSION} 裁剪共享库"
./configure --prefix="${OUT_DIR}" "${CONFIGURE_FLAGS[@]}" || die "configure 失败"

echo "编译 FFmpeg（并行 $(nproc)）"
make -j"$(nproc)" || die "make 失败"
make install || die "make install 失败"

for name in "${DLL_NAMES[@]}"; do
  [[ -f "${OUT_DIR}/bin/${name}" ]] || die "未生成 ${name}：${OUT_DIR}/bin"
done

for name in "${DLL_NAMES[@]}"; do
  cp -f "${OUT_DIR}/bin/${name}" "${RUNTIME_DIR}/${name}"
done

echo "校验产物依赖"
for name in "${DLL_NAMES[@]}"; do
  path="${RUNTIME_DIR}/${name}"
  deps="$(objdump -p "${path}" | awk '/DLL Name/ {print $3}' | sort -u)"
  echo "  ${name} 导入：$(tr '\n' ' ' <<< "${deps}")"
  while IFS= read -r dep; do
    [[ -z "${dep}" ]] && continue
    case "${dep}" in
      libgcc*|libwinpthread*|libstdc++*)
        die "${name} 仍依赖 MSYS2 运行时 DLL：${dep}（--extra-ldflags 的 -static 未生效）"
        ;;
      avcodec-62.dll|avformat-62.dll|avutil-60.dll|swresample-6.dll|bass.dll)
        continue
        ;;
      KERNEL32.dll|kernel32.dll|msvcrt.dll|USER32.dll|user32.dll|ADVAPI32.dll|advapi32.dll|SHELL32.dll|shell32.dll|ole32.dll|OLE32.dll|bcrypt.dll|BCRYPT.dll|CRYPT32.dll|crypt32.dll|ncrypt.dll|NCRYPT.dll|Secur32.dll|secur32.dll|IPHLPAPI.DLL|iphlpapi.dll|WS2_32.dll|ws2_32.dll|RPCRT4.dll|rpcrt4.dll|USP10.dll|usp10.dll|GDI32.dll|gdi32.dll|d2d1.dll|D2D1.dll|DWrite.dll|dwrite.dll|CFGMGR32.dll|cfgmgr32.dll|ntdll.dll|NTDLL.DLL)
        continue
        ;;
      *)
        die "${name} 依赖未预期的 DLL：${dep}"
        ;;
    esac
  done <<< "${deps}"
done

for name in "${DLL_NAMES[@]}"; do
  exports="$(objdump -p "${RUNTIME_DIR}/${name}" | awk '/\[Ordinal\/Name Pointer\] Table/ {flag=1; next} flag && NF {print $NF}')"
  case "${name}" in
    avcodec-62.dll)
      grep -qx "avcodec_find_decoder" <<< "${exports}" || die "avcodec-62.dll 缺少 avcodec_find_decoder 导出"
      ;;
    avformat-62.dll)
      grep -qx "avformat_open_input" <<< "${exports}" || die "avformat-62.dll 缺少 avformat_open_input 导出"
      ;;
    avutil-60.dll)
      grep -qx "av_frame_alloc" <<< "${exports}" || die "avutil-60.dll 缺少 av_frame_alloc 导出"
      ;;
    swresample-6.dll)
      grep -qx "swr_init" <<< "${exports}" || die "swresample-6.dll 缺少 swr_init 导出"
      ;;
  esac
done

LICENSE_SOURCE=""
for candidate in COPYING.GPLv3 COPYING.GPLv2; do
  if [[ -f "${candidate}" ]]; then
    LICENSE_SOURCE="${candidate}"
    break
  fi
done
[[ -n "${LICENSE_SOURCE}" ]] || die "源码中未找到 GPL 许可文本"
cp -f "${LICENSE_SOURCE}" "${RUNTIME_DIR}/LICENSE"

cat > "${RUNTIME_DIR}/README-ffmpeg.txt" <<EOF
BASS_FFMPEG 插件与 FFmpeg 运行时（TAK 原生解码）

插件：bass_ffmpeg.dll 1.0.0
来源：tool/ffmpeg/build_minimal_ffmpeg.sh 在 MSYS2 MINGW64 下构建的 FFmpeg ${FFMPEG_VERSION} 裁剪共享库。
只包含音频解封装与解码（含 TAK）、swresample 与 file 协议，不含视频、编码器、滤镜与网络组件。
上游仓库：https://github.com/pudding-fox/BASS_FFMPEG
FFmpeg 许可：GPLv3，全文见同目录 LICENSE。

源码：${SOURCE_URL}
源码 SHA256：${SOURCE_SHA256}

configure 参数：
${CONFIGURE_FLAGS[*]}

运行时文件：
  avcodec-62.dll
  avformat-62.dll
  avutil-60.dll
  swresample-6.dll

安装后位于应用目录的 dll/BASS/，与 bass.dll 同目录，便于 Windows 加载器解析依赖。
EOF

cat > "${RUNTIME_DIR}/THIRD-PARTY-NOTICES.txt" <<'EOF'
第三方组件说明

1. BASS_FFMPEG 1.0.0
   项目地址：https://github.com/pudding-fox/BASS_FFMPEG
   用途：为 BASS 提供 FFmpeg 解码插件，本项目用它解码 TAK。
   许可状态：上游仓库未提供 LICENSE 文件，也未在源码头部声明许可证。
   再分发前需要向作者取得授权，或改用自行实现的插件。

2. FFmpeg 8.x 共享库（avcodec-62 / avformat-62 / avutil-60 / swresample-6）
   项目地址：https://ffmpeg.org/
   许可：GPLv3，全文见同目录 LICENSE。

3. BASS 音频引擎
   项目地址：https://www.un4seen.com/
   许可：非商业用途免费，商业用途需要 Un4seen 授权。
EOF

printf '%s\n' "${MARKER_VALUE}" > "${MARKER}"

TOTAL_BYTES=0
for name in "${DLL_NAMES[@]}"; do
  size="$(stat -c '%s' "${RUNTIME_DIR}/${name}")"
  echo "  ${name}: $((size / 1024 / 1024)) MB（${size} 字节）"
  TOTAL_BYTES=$((TOTAL_BYTES + size))
done
echo "FFmpeg 共享库合计：$((TOTAL_BYTES / 1024 / 1024)) MB"
