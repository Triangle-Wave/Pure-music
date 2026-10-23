//! DSF 缓存到 PCM WAV 的转换。
//!
//! 播放 SACD 轨道时，BASSDSD 需要实时软解 DSD，CPU 占用较高。本模块把
//! 已有的 DSF 缓存按通道拆成单声道 DSF，并行交给 `rdsd2pcm` 抽取为 PCM，
//! 再交织成标准的 16/24 位 RIFF/WAVE 文件。转换结果按 DSF 路径、长度、
//! 修改时间、采样率、位深与转换器版本缓存，命中且结构完整时直接复用。
//!
//! `rdsd2pcm` 的公开接口是整文件转换，没有逐块入口；这里通过拆分单声道
//! 文件让两个通道并行转换。DSF 的音频数据是 LSB-first，`rdsd2pcm` 依据
//! 容器的 `bits_per_sample` 字段识别位序，因此转换阶段不需要额外反位。

use std::fs::{self, File};
use std::io::{BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use rdsd2pcm::{DitherType, FilterType, OutputType, Rdsd2Pcm};

use super::dsf::{DsfWriter, DSF_BLOCK_SIZE_PER_CHANNEL};
use super::types::SacdError;

/// PCM 转换器版本，参与缓存键；升级解码器或调整输出参数时递增。
pub(crate) const PCM_CONVERTER_VERSION: &str = "rdsd2pcm-0.5.0-a06475e";

/// SACD 的 DSD64 采样率（Hz）。
const DSD64_SAMPLE_RATE: u32 = 2_822_400;

/// DSF 固定头长度：DSD chunk 28 字节 + fmt chunk 52 字节 + data chunk 头 12 字节。
const DSF_HEADER_LEN: usize = 92;

/// DSF 的 DSD chunk 固定长度。
const DSF_DSD_CHUNK_SIZE: u64 = 28;

/// DSF 的 fmt chunk 固定长度。
const DSF_FMT_CHUNK_SIZE: u64 = 52;

/// DSF 的 data chunk 头长度。
const DSF_DATA_CHUNK_HEADER_SIZE: u64 = 12;

/// 支持的目标采样率。
const SUPPORTED_SAMPLE_RATES: [u32; 4] = [44_100, 48_000, 88_200, 96_000];

/// 支持的目标位深。
const SUPPORTED_BIT_DEPTHS: [u16; 2] = [16, 24];

/// 交织时单批处理的帧数。
const INTERLEAVE_CHUNK_FRAMES: usize = 4096;

/// 串行化进程内的 PCM 转换，避免同轨并发各自全量转换。
static PCM_LOCK: Mutex<()> = Mutex::new(());

/// 解析出的 DSF 音频信息。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct DsfAudioInfo {
    /// 声道数。
    pub(crate) channels: u32,
    /// DSD 采样率（Hz）。
    pub(crate) sample_rate: u32,
    /// 每通道块大小（字节），DSF 规范固定为 4096。
    pub(crate) block_size: u32,
    /// data chunk 音频数据起始偏移。
    pub(crate) data_offset: u64,
    /// data chunk 音频数据长度（含块补齐）。
    pub(crate) data_len: u64,
    /// 每通道有效样本数（位）。
    pub(crate) sample_count_per_channel: u64,
}

impl DsfAudioInfo {
    /// 每通道有效音频字节数；不足一字节的位按一字节向下取整。
    pub(crate) fn valid_bytes_per_channel(&self) -> u64 {
        self.sample_count_per_channel / 8
    }
}

/// 确保指定 DSF 缓存已有对应的 PCM WAV，并返回 WAV 路径。
///
/// `sample_rate` 只接受 44100/48000/88200/96000，`bit_depth` 只接受 16/24。
/// `rdsd2pcm` 无法把 DSD64 整数抽取到 48kHz 族，请求 48000 时按 44100 输出
/// 并记录警告。缓存命中要求键文件与 WAV 结构同时完整，否则删除后重新转换。
pub(crate) fn ensure_pcm_cached(
    dsf_path: &Path,
    sample_rate: u32,
    bit_depth: u16,
) -> Result<PathBuf, SacdError> {
    validate_request(sample_rate, bit_depth)?;
    let info = parse_dsf_audio_info(dsf_path)?;
    let output_rate = effective_sample_rate(sample_rate);
    let target = pcm_target_path(dsf_path, output_rate, bit_depth)?;
    let key_path = target.with_extension("key");

    let _guard = lock_pcm();

    let key = cache_key(dsf_path, output_rate, bit_depth)?;
    if cache_is_valid(
        &target,
        &key_path,
        &key,
        info.channels as u16,
        output_rate,
        bit_depth,
    ) {
        log::info!("命中 SACD PCM 缓存: {}", target.display());
        return Ok(target);
    }

    remove_cached_file(&target);
    remove_cached_file(&key_path);

    let parent = target
        .parent()
        .ok_or_else(|| SacdError::invalid(format!("PCM 缓存路径没有父目录: {}", target.display())))?;
    let temp_dir = unique_temp_dir(parent)?;
    log::info!(
        "开始转换 SACD 轨道为 PCM: dsf={}, rate={output_rate}, depth={bit_depth}, 输出={}",
        dsf_path.display(),
        target.display()
    );

    let conversion = convert_dsf_to_wav(dsf_path, &info, output_rate, bit_depth, &temp_dir, &target);
    if let Err(error) = fs::remove_dir_all(&temp_dir) {
        if error.kind() != std::io::ErrorKind::NotFound {
            log::warn!("清理 PCM 临时目录失败: {}: {error}", temp_dir.display());
        }
    }
    conversion?;

    write_cache_key(&key_path, &key)?;
    log::info!(
        "SACD PCM 缓存完成: dsf={}, 输出={}",
        dsf_path.display(),
        target.display()
    );
    Ok(target)
}

/// 校验调用方请求的采样率与位深。
fn validate_request(sample_rate: u32, bit_depth: u16) -> Result<(), SacdError> {
    if !SUPPORTED_SAMPLE_RATES.contains(&sample_rate) {
        return Err(SacdError::invalid(format!(
            "不支持的 PCM 采样率 {sample_rate}，仅支持 44100/48000/88200/96000"
        )));
    }
    if !SUPPORTED_BIT_DEPTHS.contains(&bit_depth) {
        return Err(SacdError::invalid(format!(
            "不支持的 PCM 位深 {bit_depth}，仅支持 16/24"
        )));
    }
    Ok(())
}

/// 把请求采样率换算为 `rdsd2pcm` 实际能输出的采样率。
///
/// DSD64 到 48kHz 族的比值不是整数，`rdsd2pcm` 会退回 64:1 抽取并把 WAV
/// 头写成 48kHz，导致音调与时长错误。48kHz 请求统一回退到 44100Hz。
fn effective_sample_rate(requested: u32) -> u32 {
    if requested == 48_000 {
        log::warn!("rdsd2pcm 不支持 48kHz 输出，回退到 44100Hz");
        44_100
    } else {
        requested
    }
}

/// 取 PCM 转换的进程级互斥锁；锁中毒时记录警告并恢复内层数据。
fn lock_pcm() -> MutexGuard<'static, ()> {
    match PCM_LOCK.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            log::warn!("SACD PCM 转换锁中毒，恢复后继续串行转换");
            poisoned.into_inner()
        }
    }
}

/// 构造 PCM 缓存路径：与 DSF 同目录，文件名带声道数、轨号、采样率与位深。
fn pcm_target_path(dsf_path: &Path, sample_rate: u32, bit_depth: u16) -> Result<PathBuf, SacdError> {
    let parent = dsf_path.parent().ok_or_else(|| {
        SacdError::invalid(format!("DSF 路径没有父目录: {}", dsf_path.display()))
    })?;
    let stem = dsf_path
        .file_stem()
        .and_then(|value| value.to_str())
        .ok_or_else(|| {
            SacdError::invalid(format!(
                "DSF 文件名无法转换为 UTF-8: {}",
                dsf_path.display()
            ))
        })?;
    Ok(parent.join(format!("{stem}-{sample_rate}-{bit_depth}.wav")))
}

/// 构造 PCM 缓存键文本。
fn cache_key(dsf_path: &Path, sample_rate: u32, bit_depth: u16) -> Result<String, SacdError> {
    let metadata = fs::metadata(dsf_path).map_err(|error| {
        io_error(
            error,
            format!("读取 DSF 缓存信息失败: {}", dsf_path.display()),
        )
    })?;
    let mtime_secs = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |duration| duration.as_secs());
    Ok(format!(
        "{}|{}|{}|{}|{}|{}",
        dsf_path.to_string_lossy(),
        metadata.len(),
        mtime_secs,
        sample_rate,
        bit_depth,
        PCM_CONVERTER_VERSION
    ))
}

/// 判断缓存键与 WAV 结构是否同时有效。
fn cache_is_valid(
    target: &Path,
    key_path: &Path,
    expected_key: &str,
    channels: u16,
    sample_rate: u32,
    bit_depth: u16,
) -> bool {
    let cached_key = match fs::read_to_string(key_path) {
        Ok(value) => value,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return false,
        Err(error) => {
            log::warn!("读取 PCM 缓存键失败: {}: {error}", key_path.display());
            return false;
        }
    };
    if cached_key != expected_key {
        return false;
    }
    match verify_wav(target, channels, sample_rate, bit_depth) {
        Ok(_) => true,
        Err(reason) => {
            log::warn!(
                "PCM 缓存文件不完整，重新转换: {}: {reason}",
                target.display()
            );
            false
        }
    }
}

/// 删除不可信的缓存文件；删除失败只记警告，由后续转换覆盖。
fn remove_cached_file(path: &Path) {
    match fs::remove_file(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => log::warn!("删除无效 PCM 缓存失败: {}: {error}", path.display()),
    }
}

/// 写入缓存键：先写临时文件再改名，避免中断留下半截内容。
fn write_cache_key(path: &Path, key: &str) -> Result<(), SacdError> {
    let temp = super::temporary_path(path);
    fs::write(&temp, key.as_bytes()).map_err(|error| {
        io_error(
            error,
            format!("写入 PCM 缓存键临时文件失败: {}", temp.display()),
        )
    })?;
    super::replace_file(&temp, path).map_err(|error| {
        let _ = fs::remove_file(&temp);
        io_error(error, format!("写入 PCM 缓存键失败: {}", path.display()))
    })
}

/// 解析 DSF 头，校验 chunk 标识、字段范围与 data 边界。
pub(crate) fn parse_dsf_audio_info(path: &Path) -> Result<DsfAudioInfo, SacdError> {
    let mut file = File::open(path).map_err(|error| {
        io_error(error, format!("打开 DSF 缓存失败: {}", path.display()))
    })?;
    let actual_len = file
        .metadata()
        .map_err(|error| {
            io_error(
                error,
                format!("读取 DSF 缓存信息失败: {}", path.display()),
            )
        })?
        .len();
    if actual_len < DSF_HEADER_LEN as u64 {
        return Err(SacdError::invalid(format!(
            "DSF 文件长度 {actual_len} 小于固定头长度 {DSF_HEADER_LEN}"
        )));
    }

    let mut header = [0u8; DSF_HEADER_LEN];
    file.read_exact(&mut header).map_err(|error| {
        io_error(error, format!("读取 DSF 头失败: {}", path.display()))
    })?;

    expect_chunk(&header, 0, b"DSD ")?;
    expect_chunk(&header, 28, b"fmt ")?;
    expect_chunk(&header, 80, b"data")?;

    let dsd_chunk_size = read_u64_le(&header, 4)?;
    if dsd_chunk_size != DSF_DSD_CHUNK_SIZE {
        return Err(SacdError::invalid(format!(
            "DSD chunk 长度 {dsd_chunk_size} 与规范 {DSF_DSD_CHUNK_SIZE} 不一致"
        )));
    }
    let declared_total = read_u64_le(&header, 12)?;
    if declared_total != actual_len {
        return Err(SacdError::invalid(format!(
            "DSD chunk 声明文件长度 {declared_total} 与实际长度 {actual_len} 不一致"
        )));
    }

    let fmt_chunk_size = read_u64_le(&header, 32)?;
    if fmt_chunk_size != DSF_FMT_CHUNK_SIZE {
        return Err(SacdError::invalid(format!(
            "fmt chunk 长度 {fmt_chunk_size} 与规范 {DSF_FMT_CHUNK_SIZE} 不一致"
        )));
    }
    let format_version = read_u32_le(&header, 40)?;
    if format_version != 1 {
        return Err(SacdError::invalid(format!(
            "DSF 格式版本 {format_version} 不受支持"
        )));
    }
    let format_id = read_u32_le(&header, 44)?;
    if format_id != 0 {
        return Err(SacdError::invalid(format!(
            "DSF 格式 ID {format_id} 不是裸 DSD"
        )));
    }
    let channel_type = read_u32_le(&header, 48)?;
    if !(1..=7).contains(&channel_type) {
        return Err(SacdError::invalid(format!(
            "DSF 声道类型 {channel_type} 超出范围"
        )));
    }
    let channels = read_u32_le(&header, 52)?;
    if !(1..=6).contains(&channels) {
        return Err(SacdError::invalid(format!(
            "DSF 声道数 {channels} 超出范围"
        )));
    }
    let sample_rate = read_u32_le(&header, 56)?;
    if sample_rate != DSD64_SAMPLE_RATE {
        return Err(SacdError::invalid(format!(
            "DSF 采样率 {sample_rate} 不是 SACD 的 {DSD64_SAMPLE_RATE}"
        )));
    }
    let bits_per_sample = read_u32_le(&header, 60)?;
    if bits_per_sample != 1 {
        return Err(SacdError::invalid(format!(
            "DSF 位深 {bits_per_sample} 不是 LSB-first 的 1"
        )));
    }
    let sample_count = read_u64_le(&header, 64)?;
    if sample_count == 0 {
        return Err(SacdError::invalid("DSF 每通道样本数为 0"));
    }
    if sample_count % 8 != 0 {
        log::warn!("DSF 每通道样本数 {sample_count} 不是 8 的倍数，按向下取整处理");
    }
    let block_size = read_u32_le(&header, 72)?;
    if block_size != DSF_BLOCK_SIZE_PER_CHANNEL as u32 {
        return Err(SacdError::invalid(format!(
            "DSF 每通道块大小 {block_size} 与规范 {DSF_BLOCK_SIZE_PER_CHANNEL} 不一致"
        )));
    }
    let reserved = read_u32_le(&header, 76)?;
    if reserved != 0 {
        return Err(SacdError::invalid("DSF fmt chunk 保留字段不为 0"));
    }

    let data_chunk_size = read_u64_le(&header, 84)?;
    if data_chunk_size < DSF_DATA_CHUNK_HEADER_SIZE {
        return Err(SacdError::invalid(format!(
            "DSF data chunk 长度 {data_chunk_size} 小于头长度 {DSF_DATA_CHUNK_HEADER_SIZE}"
        )));
    }
    let data_len = data_chunk_size - DSF_DATA_CHUNK_HEADER_SIZE;
    let data_offset = DSF_HEADER_LEN as u64;
    let data_end = data_offset
        .checked_add(data_len)
        .ok_or_else(|| SacdError::invalid("DSF data chunk 结束位置溢出"))?;
    if data_end > actual_len {
        return Err(SacdError::invalid(format!(
            "DSF data chunk 结束位置 {data_end} 超出文件长度 {actual_len}"
        )));
    }
    if data_len % u64::from(channels) != 0 {
        return Err(SacdError::invalid(format!(
            "DSF data 长度 {data_len} 不是声道数 {channels} 的整数倍"
        )));
    }
    let per_channel = data_len / u64::from(channels);
    if per_channel % u64::from(block_size) != 0 {
        return Err(SacdError::invalid(format!(
            "DSF 每通道数据长度 {per_channel} 不是块大小 {block_size} 的整数倍"
        )));
    }
    let valid_bytes = sample_count / 8;
    if valid_bytes > per_channel {
        return Err(SacdError::invalid(format!(
            "DSF 每通道有效长度 {valid_bytes} 超过 data 中的 {per_channel}"
        )));
    }

    Ok(DsfAudioInfo {
        channels,
        sample_rate,
        block_size,
        data_offset,
        data_len,
        sample_count_per_channel: sample_count,
    })
}

/// 校验指定偏移处的 chunk 标识。
fn expect_chunk(header: &[u8], offset: usize, expected: &[u8; 4]) -> Result<(), SacdError> {
    let end = offset
        .checked_add(4)
        .ok_or_else(|| SacdError::invalid("chunk 偏移溢出"))?;
    let actual = header
        .get(offset..end)
        .ok_or_else(|| SacdError::invalid(format!("DSF 头缺少偏移 {offset} 处的 chunk 标识")))?;
    if actual != expected.as_slice() {
        return Err(SacdError::invalid(format!(
            "偏移 {offset} 处的 chunk 标识不是 {}",
            String::from_utf8_lossy(expected.as_slice())
        )));
    }
    Ok(())
}

/// 从字节切片读取小端 u32。
fn read_u32_le(bytes: &[u8], offset: usize) -> Result<u32, SacdError> {
    let end = offset
        .checked_add(4)
        .ok_or_else(|| SacdError::invalid("读取 u32 偏移溢出"))?;
    let array: [u8; 4] = bytes
        .get(offset..end)
        .ok_or_else(|| SacdError::invalid(format!("读取 u32 越界: {offset}")))?
        .try_into()
        .map_err(|_| SacdError::invalid("读取 u32 长度错误"))?;
    Ok(u32::from_le_bytes(array))
}

/// 从字节切片读取小端 u64。
fn read_u64_le(bytes: &[u8], offset: usize) -> Result<u64, SacdError> {
    let end = offset
        .checked_add(8)
        .ok_or_else(|| SacdError::invalid("读取 u64 偏移溢出"))?;
    let array: [u8; 8] = bytes
        .get(offset..end)
        .ok_or_else(|| SacdError::invalid(format!("读取 u64 越界: {offset}")))?
        .try_into()
        .map_err(|_| SacdError::invalid("读取 u64 长度错误"))?;
    Ok(u64::from_le_bytes(array))
}

/// 把 DSF 转换为 PCM WAV，成功后把结果改名到目标路径。
fn convert_dsf_to_wav(
    dsf_path: &Path,
    info: &DsfAudioInfo,
    sample_rate: u32,
    bit_depth: u16,
    temp_dir: &Path,
    target: &Path,
) -> Result<(), SacdError> {
    let valid_bytes = info.valid_bytes_per_channel();
    if valid_bytes == 0 {
        return Err(SacdError::invalid("DSF 没有有效音频数据"));
    }

    let mut source = File::open(dsf_path).map_err(|error| {
        io_error(error, format!("打开 DSF 缓存失败: {}", dsf_path.display()))
    })?;
    let mut channel_paths = Vec::with_capacity(info.channels as usize);
    for channel in 0..info.channels {
        let channel_path = temp_dir.join(format!("ch{channel}.dsf"));
        write_channel_dsf(
            &mut source,
            info,
            valid_bytes,
            channel,
            &channel_path,
        )?;
        channel_paths.push(channel_path);
    }

    let mut wav_paths = Vec::with_capacity(channel_paths.len());
    std::thread::scope(|scope| -> Result<(), SacdError> {
        let handles: Vec<_> = channel_paths
            .iter()
            .enumerate()
            .map(|(index, path)| {
                let out_dir = temp_dir.join(format!("out{index}"));
                scope.spawn(move || convert_channel(path, &out_dir, sample_rate, bit_depth))
            })
            .collect();
        for handle in handles {
            let wav_path = handle
                .join()
                .map_err(|_| SacdError::invalid("PCM 转换线程 panic"))??;
            wav_paths.push(wav_path);
        }
        Ok(())
    })?;

    let final_wav = temp_dir.join("final.wav");
    interleave_wav(
        &wav_paths,
        info.channels as u16,
        sample_rate,
        bit_depth,
        &final_wav,
    )?;
    super::replace_file(&final_wav, target).map_err(|error| {
        let _ = fs::remove_file(&final_wav);
        io_error(error, format!("写入 PCM 缓存失败: {}", target.display()))
    })
}

/// 把 DSF 中指定通道的音频数据写成单声道 DSF。
///
/// DSF 的 data chunk 按 `(块号 * 声道数 + 声道号) * 4096` 排列。这里按块
/// 读取目标通道的有效字节，反位为 MSB-first 后交给 [`DsfWriter`]，写入的
/// 单声道 DSF 内仍是 LSB-first，与源文件逐字节一致。
fn write_channel_dsf(
    source: &mut File,
    info: &DsfAudioInfo,
    valid_bytes: u64,
    channel: u32,
    target: &Path,
) -> Result<(), SacdError> {
    let block_size = u64::from(info.block_size);
    let channels = u64::from(info.channels);
    let blocks = valid_bytes.div_ceil(block_size);
    let sample_count = valid_bytes
        .checked_mul(8)
        .ok_or_else(|| SacdError::invalid("DSF 样本数溢出"))?;
    let mut writer = DsfWriter::create(
        target,
        1,
        info.sample_rate,
        sample_count,
        0,
    )?;
    let mut buffer = vec![0u8; block_size as usize];

    for block in 0..blocks {
        let block_start = block * block_size;
        let valid_in_block = (valid_bytes - block_start).min(block_size) as usize;
        if valid_in_block == 0 {
            continue;
        }
        let block_index = block
            .checked_mul(channels)
            .and_then(|value| value.checked_add(u64::from(channel)))
            .ok_or_else(|| SacdError::invalid("DSF 通道块索引溢出"))?;
        let offset = block_index
            .checked_mul(block_size)
            .and_then(|value| info.data_offset.checked_add(value))
            .ok_or_else(|| SacdError::invalid("DSF 通道数据偏移溢出"))?;
        source.seek(SeekFrom::Start(offset)).map_err(|error| {
            io_error(error, format!("定位 DSF 通道数据失败: 偏移 {offset}"))
        })?;
        source
            .read_exact(&mut buffer[..valid_in_block])
            .map_err(|error| {
                io_error(
                    error,
                    format!("读取 DSF 通道 {channel} 第 {block} 块失败"),
                )
            })?;
        for byte in &mut buffer[..valid_in_block] {
            *byte = byte.reverse_bits();
        }
        writer.write_samples(&buffer[..valid_in_block])?;
    }

    writer.finalize()
}

/// 用一个线程把单声道 DSF 转换为单声道 WAV。
fn convert_channel(
    dsf_path: &Path,
    out_dir: &Path,
    sample_rate: u32,
    bit_depth: u16,
) -> Result<PathBuf, SacdError> {
    fs::create_dir_all(out_dir).map_err(|error| {
        io_error(
            error,
            format!("创建 PCM 通道输出目录失败: {}", out_dir.display()),
        )
    })?;
    let base_dir = dsf_path
        .parent()
        .ok_or_else(|| {
            SacdError::invalid(format!("单声道 DSF 没有父目录: {}", dsf_path.display()))
        })?
        .to_path_buf();
    let mut converter = Rdsd2Pcm::from_container(
        bit_depth as usize,
        OutputType::Wav,
        0.0,
        sample_rate,
        Some(out_dir.to_path_buf()),
        DitherType::TPDF,
        FilterType::Equiripple,
        false,
        base_dir,
        dsf_path.to_path_buf(),
    )
    .map_err(|error| {
        SacdError::invalid(format!(
            "初始化 PCM 转换器失败: dsf={}: {error}",
            dsf_path.display()
        ))
    })?;

    let cancel = AtomicBool::new(false);
    converter.do_conversion(&cancel, None).map_err(|error| {
        SacdError::invalid(format!(
            "PCM 转换失败: dsf={}: {error}",
            dsf_path.display()
        ))
    })?;

    let stem = dsf_path
        .file_stem()
        .ok_or_else(|| {
            SacdError::invalid(format!("单声道 DSF 没有文件名: {}", dsf_path.display()))
        })?;
    let output = out_dir.join(stem).with_extension("wav");
    if !output.is_file() {
        return Err(SacdError::invalid(format!(
            "PCM 转换器未生成输出文件: {}",
            output.display()
        )));
    }
    Ok(output)
}

/// 把多个单声道 WAV 交织为最终的 RIFF/WAVE 文件。
fn interleave_wav(
    channel_paths: &[PathBuf],
    channels: u16,
    sample_rate: u32,
    bit_depth: u16,
    target: &Path,
) -> Result<u64, SacdError> {
    if channel_paths.len() != usize::from(channels) {
        return Err(SacdError::invalid(format!(
            "PCM 通道数 {} 与 WAV 声道数 {channels} 不一致",
            channel_paths.len()
        )));
    }
    let bytes_per_sample = usize::from(bit_depth / 8);
    if bytes_per_sample == 0 {
        return Err(SacdError::invalid(format!("不支持的 PCM 位深 {bit_depth}")));
    }

    let mut infos = Vec::with_capacity(channel_paths.len());
    let mut frames: Option<u64> = None;
    for path in channel_paths {
        let info = verify_wav(path, 1, sample_rate, bit_depth)?;
        frames = Some(match frames {
            Some(current) if current != info.frames => {
                log::warn!(
                    "PCM 通道帧数不一致: {} 为 {}，此前为 {current}，按较小值交织",
                    path.display(),
                    info.frames
                );
                current.min(info.frames)
            }
            Some(current) => current,
            None => info.frames,
        });
        infos.push(info);
    }
    let frames = frames.unwrap_or(0);
    let data_size = frames
        .checked_mul(u64::from(channels))
        .and_then(|value| value.checked_mul(bytes_per_sample as u64))
        .ok_or_else(|| SacdError::invalid("PCM 输出长度溢出"))?;
    let riff_size = data_size
        .checked_add(36)
        .ok_or_else(|| SacdError::invalid("PCM RIFF 长度溢出"))?;
    if riff_size > u64::from(u32::MAX) {
        return Err(SacdError::invalid(format!(
            "PCM 输出 {riff_size} 字节超出 WAV 的 4GiB 上限"
        )));
    }

    let file = File::create(target).map_err(|error| {
        io_error(error, format!("创建 PCM 输出失败: {}", target.display()))
    })?;
    let mut writer = BufWriter::with_capacity(1 << 20, file);
    write_wav_header(
        &mut writer,
        channels,
        sample_rate,
        bit_depth,
        data_size as u32,
    )
    .map_err(|error| {
        io_error(error, format!("写入 PCM 输出头失败: {}", target.display()))
    })?;

    let mut readers = Vec::with_capacity(channel_paths.len());
    for (path, info) in channel_paths.iter().zip(infos.iter()) {
        let mut reader = BufReader::with_capacity(
            INTERLEAVE_CHUNK_FRAMES * bytes_per_sample,
            File::open(path).map_err(|error| {
                io_error(error, format!("重新打开 PCM 通道失败: {}", path.display()))
            })?,
        );
        reader
            .seek(SeekFrom::Start(info.data_offset))
            .map_err(|error| {
                io_error(error, format!("定位 PCM 通道数据失败: {}", path.display()))
            })?;
        readers.push(reader);
    }

    let mut channel_buffers = vec![vec![0u8; INTERLEAVE_CHUNK_FRAMES * bytes_per_sample]; readers.len()];
    let mut interleaved = vec![0u8; INTERLEAVE_CHUNK_FRAMES * usize::from(channels) * bytes_per_sample];
    let mut remaining = frames;
    while remaining > 0 {
        let chunk_frames = remaining.min(INTERLEAVE_CHUNK_FRAMES as u64) as usize;
        let chunk_bytes = chunk_frames * bytes_per_sample;
        for (reader, buffer) in readers.iter_mut().zip(channel_buffers.iter_mut()) {
            reader.read_exact(&mut buffer[..chunk_bytes]).map_err(|error| {
                io_error(error, "读取 PCM 通道样本失败")
            })?;
        }
        for frame in 0..chunk_frames {
            let source_start = frame * bytes_per_sample;
            let target_start = frame * usize::from(channels) * bytes_per_sample;
            for channel in 0..usize::from(channels) {
                let from = source_start;
                let to = target_start + channel * bytes_per_sample;
                interleaved[to..to + bytes_per_sample]
                    .copy_from_slice(&channel_buffers[channel][from..from + bytes_per_sample]);
            }
        }
        writer
            .write_all(&interleaved[..chunk_frames * usize::from(channels) * bytes_per_sample])
            .map_err(|error| {
                io_error(error, format!("写入 PCM 样本失败: {}", target.display()))
            })?;
        remaining -= chunk_frames as u64;
    }

    writer.flush().map_err(|error| {
        io_error(error, format!("刷新 PCM 输出失败: {}", target.display()))
    })?;
    Ok(frames)
}

/// 写入 44 字节的标准 PCM WAV 头。
fn write_wav_header(
    writer: &mut impl Write,
    channels: u16,
    sample_rate: u32,
    bit_depth: u16,
    data_size: u32,
) -> std::io::Result<()> {
    let bytes_per_sample = bit_depth / 8;
    let block_align = channels
        .checked_mul(bytes_per_sample)
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidInput, "WAV block_align 溢出"))?;
    let byte_rate = sample_rate
        .checked_mul(u32::from(block_align))
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidInput, "WAV byte_rate 溢出"))?;
    writer.write_all(b"RIFF")?;
    writer.write_all(&(36u32.saturating_add(data_size)).to_le_bytes())?;
    writer.write_all(b"WAVE")?;
    writer.write_all(b"fmt ")?;
    writer.write_all(&16u32.to_le_bytes())?;
    writer.write_all(&1u16.to_le_bytes())?;
    writer.write_all(&channels.to_le_bytes())?;
    writer.write_all(&sample_rate.to_le_bytes())?;
    writer.write_all(&byte_rate.to_le_bytes())?;
    writer.write_all(&block_align.to_le_bytes())?;
    writer.write_all(&bit_depth.to_le_bytes())?;
    writer.write_all(b"data")?;
    writer.write_all(&data_size.to_le_bytes())?;
    Ok(())
}

/// 解析出的 WAV 结构信息。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
pub(crate) struct WavInfo {
    /// 声道数。
    pub(crate) channels: u16,
    /// 采样率（Hz）。
    pub(crate) sample_rate: u32,
    /// 位深。
    pub(crate) bits_per_sample: u16,
    /// 每帧字节数。
    pub(crate) block_align: u16,
    /// data chunk 数据起始偏移。
    pub(crate) data_offset: u64,
    /// data chunk 数据长度。
    pub(crate) data_len: u64,
    /// 帧数。
    pub(crate) frames: u64,
}

/// fmt chunk 中解析出的格式字段。
#[derive(Debug, Clone, Copy)]
struct WavFormat {
    audio_format: u16,
    channels: u16,
    sample_rate: u32,
    byte_rate: u32,
    block_align: u16,
    bits_per_sample: u16,
}

/// 严格校验 RIFF/WAVE 头、fmt chunk 字段与 data chunk 边界。
pub(crate) fn verify_wav(
    path: &Path,
    expected_channels: u16,
    expected_sample_rate: u32,
    expected_bit_depth: u16,
) -> Result<WavInfo, SacdError> {
    let mut file = File::open(path).map_err(|error| {
        io_error(error, format!("打开 PCM 文件失败: {}", path.display()))
    })?;
    let file_len = file
        .metadata()
        .map_err(|error| {
            io_error(error, format!("读取 PCM 文件信息失败: {}", path.display()))
        })?
        .len();
    if file_len < 44 {
        return Err(SacdError::invalid(format!(
            "PCM 文件长度 {file_len} 小于最小 WAV 头长度 44"
        )));
    }

    let mut header = [0u8; 12];
    file.read_exact(&mut header).map_err(|error| {
        io_error(error, format!("读取 PCM 头失败: {}", path.display()))
    })?;
    if &header[0..4] != b"RIFF" || &header[8..12] != b"WAVE" {
        return Err(SacdError::invalid(format!(
            "PCM 文件不是 RIFF/WAVE: {}",
            path.display()
        )));
    }
    let riff_size = u64::from(u32::from_le_bytes(
        header[4..8]
            .try_into()
            .map_err(|_| SacdError::invalid("WAV RIFF 长度字段不完整"))?,
    ));
    if riff_size.checked_add(8) != Some(file_len) {
        return Err(SacdError::invalid(format!(
            "WAV RIFF 声明长度 {} 与文件长度 {file_len} 不一致",
            riff_size + 8
        )));
    }

    let mut format: Option<WavFormat> = None;
    let mut data: Option<(u64, u64)> = None;
    let mut offset = 12u64;
    while offset + 8 <= file_len {
        file.seek(SeekFrom::Start(offset)).map_err(|error| {
            io_error(error, format!("定位 WAV chunk 失败: 偏移 {offset}"))
        })?;
        let mut chunk = [0u8; 8];
        file.read_exact(&mut chunk).map_err(|error| {
            io_error(error, format!("读取 WAV chunk 头失败: 偏移 {offset}"))
        })?;
        let chunk_id = &chunk[0..4];
        let chunk_size = u64::from(u32::from_le_bytes(
            chunk[4..8]
                .try_into()
                .map_err(|_| SacdError::invalid("WAV chunk 长度字段不完整"))?,
        ));
        let body_offset = offset + 8;
        let body_end = body_offset
            .checked_add(chunk_size)
            .ok_or_else(|| SacdError::invalid("WAV chunk 结束位置溢出"))?;
        if body_end > file_len {
            return Err(SacdError::invalid(format!(
                "WAV chunk {:?} 结束位置 {body_end} 超出文件长度 {file_len}",
                String::from_utf8_lossy(chunk_id)
            )));
        }

        if chunk_id == b"fmt " {
            if chunk_size < 16 {
                return Err(SacdError::invalid(format!(
                    "WAV fmt chunk 长度 {chunk_size} 小于 16"
                )));
            }
            file.seek(SeekFrom::Start(body_offset)).map_err(|error| {
                io_error(error, "定位 WAV fmt chunk 失败")
            })?;
            let mut fmt = [0u8; 16];
            file.read_exact(&mut fmt).map_err(|error| {
                io_error(error, "读取 WAV fmt chunk 失败")
            })?;
            let audio_format = u16::from_le_bytes(
                fmt[0..2]
                    .try_into()
                    .map_err(|_| SacdError::invalid("WAV 音频格式字段不完整"))?,
            );
            let channels = u16::from_le_bytes(
                fmt[2..4]
                    .try_into()
                    .map_err(|_| SacdError::invalid("WAV 声道数字段不完整"))?,
            );
            let sample_rate = u32::from_le_bytes(
                fmt[4..8]
                    .try_into()
                    .map_err(|_| SacdError::invalid("WAV 采样率字段不完整"))?,
            );
            let byte_rate = u32::from_le_bytes(
                fmt[8..12]
                    .try_into()
                    .map_err(|_| SacdError::invalid("WAV 字节率字段不完整"))?,
            );
            let block_align = u16::from_le_bytes(
                fmt[12..14]
                    .try_into()
                    .map_err(|_| SacdError::invalid("WAV 块对齐字段不完整"))?,
            );
            let bits_per_sample = u16::from_le_bytes(
                fmt[14..16]
                    .try_into()
                    .map_err(|_| SacdError::invalid("WAV 位深字段不完整"))?,
            );
            format = Some(WavFormat {
                audio_format,
                channels,
                sample_rate,
                byte_rate,
                block_align,
                bits_per_sample,
            });
        } else if chunk_id == b"data" {
            data = Some((body_offset, chunk_size));
        }

        offset = body_end + (chunk_size & 1);
    }

    let format = format.ok_or_else(|| SacdError::invalid("WAV 缺少 fmt chunk"))?;
    let (data_offset, data_len) =
        data.ok_or_else(|| SacdError::invalid("WAV 缺少 data chunk"))?;

    if format.audio_format != 1 {
        return Err(SacdError::invalid(format!(
            "WAV 音频格式 {} 不是整数 PCM",
            format.audio_format
        )));
    }
    if format.channels != expected_channels {
        return Err(SacdError::invalid(format!(
            "WAV 声道数 {} 与预期 {expected_channels} 不一致",
            format.channels
        )));
    }
    if format.sample_rate != expected_sample_rate {
        return Err(SacdError::invalid(format!(
            "WAV 采样率 {} 与预期 {expected_sample_rate} 不一致",
            format.sample_rate
        )));
    }
    if format.bits_per_sample != expected_bit_depth {
        return Err(SacdError::invalid(format!(
            "WAV 位深 {} 与预期 {expected_bit_depth} 不一致",
            format.bits_per_sample
        )));
    }
    let expected_block_align = format
        .channels
        .checked_mul(format.bits_per_sample / 8)
        .ok_or_else(|| SacdError::invalid("WAV 块对齐溢出"))?;
    if format.block_align != expected_block_align {
        return Err(SacdError::invalid(format!(
            "WAV 块对齐 {} 与预期 {expected_block_align} 不一致",
            format.block_align
        )));
    }
    let expected_byte_rate = format
        .sample_rate
        .checked_mul(u32::from(format.block_align))
        .ok_or_else(|| SacdError::invalid("WAV 字节率溢出"))?;
    if format.byte_rate != expected_byte_rate {
        return Err(SacdError::invalid(format!(
            "WAV 字节率 {} 与预期 {expected_byte_rate} 不一致",
            format.byte_rate
        )));
    }
    if format.block_align == 0 || data_len % u64::from(format.block_align) != 0 {
        return Err(SacdError::invalid(format!(
            "WAV data 长度 {data_len} 不是块对齐 {} 的整数倍",
            format.block_align
        )));
    }

    Ok(WavInfo {
        channels: format.channels,
        sample_rate: format.sample_rate,
        bits_per_sample: format.bits_per_sample,
        block_align: format.block_align,
        data_offset,
        data_len,
        frames: data_len / u64::from(format.block_align),
    })
}

/// 构造唯一的 PCM 转换临时目录。
fn unique_temp_dir(parent: &Path) -> Result<PathBuf, SacdError> {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let sequence = COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir = parent.join(format!(
        ".pcm-{}-{}-{}",
        std::process::id(),
        nanos,
        sequence
    ));
    fs::create_dir_all(&dir).map_err(|error| {
        io_error(
            error,
            format!("创建 PCM 临时目录失败: {}", dir.display()),
        )
    })?;
    Ok(dir)
}

/// 构造带上下文的 IO 错误。
fn io_error(error: std::io::Error, context: impl Into<String>) -> SacdError {
    let message = context.into();
    SacdError::Io(std::io::Error::new(
        error.kind(),
        format!("{message}: {error}"),
    ))
}

#[cfg(test)]
mod tests {
    use super::{
        effective_sample_rate, ensure_pcm_cached, parse_dsf_audio_info, validate_request,
        verify_wav, DSD64_SAMPLE_RATE,
    };
    use crate::api::sacd::dsf::DsfWriter;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    /// dst-decoder 仓库的 stereo frame_001 测试向量：每通道 4704 字节。
    const DSD_FIXTURE: &[u8] = include_bytes!("testdata/frame_001.dsd");

    /// 测试结束后自动删除的临时目录。
    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new() -> Self {
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or(0);
            let sequence = COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "pure_music_pcm_{}_{}_{}",
                std::process::id(),
                nanos,
                sequence
            ));
            fs::create_dir_all(&path).expect("创建测试临时目录");
            Self { path }
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    /// 用 DSD fixture 构造一个最小立体声 DSF。
    fn build_fixture_dsf(path: &Path) {
        let per_channel_bytes = DSD_FIXTURE.len() / 2;
        let mut writer = DsfWriter::create(
            path,
            2,
            DSD64_SAMPLE_RATE,
            (per_channel_bytes * 8) as u64,
            0,
        )
        .expect("创建测试 DSF");
        writer.write_samples(DSD_FIXTURE).expect("写入测试 DSF 样本");
        writer.finalize().expect("完成测试 DSF");
    }

    fn read_u32(bytes: &[u8], offset: usize) -> u32 {
        let target = bytes.get(offset..offset + 4).expect("读取 u32 越界");
        u32::from_le_bytes(target.try_into().expect("u32 长度错误"))
    }

    #[test]
    fn parses_minimal_dsf_header() {
        let temp = TempDir::new();
        let dsf = temp.path.join("2ch-01.dsf");
        build_fixture_dsf(&dsf);

        let info = parse_dsf_audio_info(&dsf).expect("解析 DSF 头");
        assert_eq!(info.channels, 2);
        assert_eq!(info.sample_rate, DSD64_SAMPLE_RATE);
        assert_eq!(info.block_size, 4096);
        assert_eq!(info.data_offset, 92);
        assert_eq!(info.data_len, 2 * 2 * 4096);
        assert_eq!(info.sample_count_per_channel, 4704 * 8);
        assert_eq!(info.valid_bytes_per_channel(), 4704);
    }

    #[test]
    fn rejects_truncated_dsf_header() {
        let temp = TempDir::new();
        let dsf = temp.path.join("truncated.dsf");
        fs::write(&dsf, b"DSD ").expect("写入截断文件");
        assert!(parse_dsf_audio_info(&dsf).is_err());
    }

    #[test]
    fn rejects_invalid_request() {
        assert!(validate_request(22_050, 24).is_err());
        assert!(validate_request(44_100, 32).is_err());
        assert!(validate_request(44_100, 24).is_ok());
    }

    #[test]
    fn falls_back_to_44k_for_48k_request() {
        assert_eq!(effective_sample_rate(48_000), 44_100);
        assert_eq!(effective_sample_rate(44_100), 44_100);
        assert_eq!(effective_sample_rate(88_200), 88_200);
        assert_eq!(effective_sample_rate(96_000), 96_000);
    }

    #[test]
    fn converts_stereo_dsf_to_24bit_wav() {
        let temp = TempDir::new();
        let dsf = temp.path.join("2ch-01.dsf");
        build_fixture_dsf(&dsf);

        let output = ensure_pcm_cached(&dsf, 44_100, 24).expect("转换 24 位 PCM");
        let info = verify_wav(&output, 2, 44_100, 24).expect("校验 24 位 WAV");
        assert_eq!(info.block_align, 6);
        assert_eq!(info.frames, 588, "4704 字节 / 8 字节每输出帧");

        let bytes = fs::read(&output).expect("读取 WAV");
        assert_eq!(bytes.len(), 44 + 588 * 6);
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WAVE");
        assert_eq!(&bytes[36..40], b"data");
        assert_eq!(read_u32(&bytes, 40), 588 * 6);
    }

    #[test]
    fn converts_stereo_dsf_to_16bit_wav() {
        let temp = TempDir::new();
        let dsf = temp.path.join("2ch-01.dsf");
        build_fixture_dsf(&dsf);

        let output = ensure_pcm_cached(&dsf, 44_100, 16).expect("转换 16 位 PCM");
        let info = verify_wav(&output, 2, 44_100, 16).expect("校验 16 位 WAV");
        assert_eq!(info.block_align, 4);
        assert_eq!(info.frames, 588);

        let bytes = fs::read(&output).expect("读取 WAV");
        assert_eq!(bytes.len(), 44 + 588 * 4);
        assert_eq!(read_u32(&bytes, 40), 588 * 4);
    }

    #[test]
    fn reuses_complete_cache_and_rebuilds_truncated_wav() {
        let temp = TempDir::new();
        let dsf = temp.path.join("2ch-01.dsf");
        build_fixture_dsf(&dsf);

        let first = ensure_pcm_cached(&dsf, 44_100, 16).expect("首次转换");
        let second = ensure_pcm_cached(&dsf, 44_100, 16).expect("命中缓存");
        assert_eq!(first, second, "完整缓存应返回同一路径");

        fs::write(&first, b"RIFF").expect("截断缓存 WAV");
        let rebuilt = ensure_pcm_cached(&dsf, 44_100, 16).expect("重建缓存");
        assert_eq!(rebuilt, first);
        verify_wav(&rebuilt, 2, 44_100, 16).expect("重建后的 WAV 应完整");
    }
}
