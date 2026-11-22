//! 虚拟文件布局：头部生成与偏移换算。
//!
//! 直解模式把 ISO 中的 DSD 数据包装成虚拟 DSF（92 字节头 + 块交织 data），
//! 实时 PCM 模式包装成虚拟 WAV（44 字节头 + 交织 PCM）。两种头部字段都与
//! 现有文件写入器保持一致，BASS 才能正确换算长度与 seek。

use flutter_rust_bridge::frb;

use super::super::dsf::{channel_type, DSF_BLOCK_SIZE_PER_CHANNEL};

/// DSF 固定头长度：DSD chunk 28 字节 + fmt chunk 52 字节 + data chunk 头 12 字节。
pub(super) const DSF_HEADER_LEN: u64 = 92;

/// WAV 固定头长度：RIFF 12 + fmt 24 + data 8。
pub(super) const WAV_HEADER_LEN: u64 = 44;

/// DSF chunk 标识与固定长度，与文件写入器共用同一组数值。
const DSD_CHUNK_ID: &[u8; 4] = b"DSD ";
const FMT_CHUNK_ID: &[u8; 4] = b"fmt ";
const DATA_CHUNK_ID: &[u8; 4] = b"data";
const DSD_CHUNK_SIZE: u64 = 28;
const FMT_CHUNK_SIZE: u64 = 52;
const DATA_CHUNK_HEADER_SIZE: u64 = 12;

/// SACD 时间码帧率：每秒 75 帧。
pub(super) const SACD_FRAMES_PER_SECOND: u64 = 75;

/// 把一段字节写入 `header` 的当前位置并推进偏移；越界时保持原样（不会 panic）。
#[frb(ignore)]
fn put_bytes(header: &mut [u8], offset: &mut usize, bytes: &[u8]) {
    let end = offset.saturating_add(bytes.len());
    if let Some(target) = header.get_mut(*offset..end) {
        target.copy_from_slice(bytes);
    }
    *offset = end;
}

/// 按毫秒时长估算每通道有效 DSD 字节数（未按块对齐）。
///
/// `per_channel = ceil(duration_ms * sample_rate / 8 / 1000)`。时长或采样率为
/// 0 时返回 0。
#[frb(ignore)]
pub(super) fn dsf_valid_bytes_per_channel(duration_ms: u64, sample_rate: u32) -> u64 {
    if duration_ms == 0 || sample_rate == 0 {
        return 0;
    }
    let numerator = u128::from(duration_ms) * u128::from(sample_rate);
    u64::try_from((numerator + 7_999) / 8_000).unwrap_or(u64::MAX)
}

/// 按毫秒时长估算每通道的 DSD 字节数，并向上对齐到 DSF 块。
///
/// `per_channel = ceil(duration_ms * sample_rate / 8 / 1000)`，再对齐到
/// 4096 字节。返回对齐后的每通道字节数。时长或采样率为 0 时返回 0。
#[frb(ignore)]
pub(super) fn dsf_bytes_per_channel(duration_ms: u64, sample_rate: u32) -> u64 {
    let valid = dsf_valid_bytes_per_channel(duration_ms, sample_rate);
    if valid == 0 {
        return 0;
    }
    let block = u128::from(DSF_BLOCK_SIZE_PER_CHANNEL as u64);
    let aligned = u128::from(valid).div_ceil(block) * block;
    u64::try_from(aligned).unwrap_or(u64::MAX)
}

/// 虚拟 DSF 的 data 字节数：对齐后的每通道字节数乘以声道数。
#[frb(ignore)]
pub(super) fn dsf_data_bytes(duration_ms: u64, channels: u32, sample_rate: u32) -> u64 {
    if channels == 0 {
        return 0;
    }
    dsf_bytes_per_channel(duration_ms, sample_rate).saturating_mul(u64::from(channels))
}

/// 构造 92 字节的 DSF 头，字段顺序与本项目的 DSF 写入器一致。
///
/// `sample_count` 是每通道样本数（位），`data_bytes` 是 data chunk 的音频字节数
/// （已按块对齐）。总文件大小与 data chunk 长度直接写入确定值，不占位。
#[frb(ignore)]
pub(super) fn dsf_header(
    channels: u32,
    sample_rate: u32,
    sample_count: u64,
    data_bytes: u64,
) -> [u8; DSF_HEADER_LEN as usize] {
    let mut header = [0u8; DSF_HEADER_LEN as usize];
    let total_file_size = DSF_HEADER_LEN.saturating_add(data_bytes);
    let mut offset = 0usize;

    // DSD chunk：标识、块长度、总文件大小、metadata 指针（0 表示无 ID3）。
    put_bytes(&mut header, &mut offset, DSD_CHUNK_ID);
    put_bytes(&mut header, &mut offset, &DSD_CHUNK_SIZE.to_le_bytes());
    put_bytes(&mut header, &mut offset, &total_file_size.to_le_bytes());
    put_bytes(&mut header, &mut offset, &0u64.to_le_bytes());

    // fmt chunk：版本、格式、声道类型、声道数、采样率、位深、样本数、块大小、保留。
    put_bytes(&mut header, &mut offset, FMT_CHUNK_ID);
    put_bytes(&mut header, &mut offset, &FMT_CHUNK_SIZE.to_le_bytes());
    put_bytes(&mut header, &mut offset, &1u32.to_le_bytes());
    put_bytes(&mut header, &mut offset, &0u32.to_le_bytes());
    put_bytes(
        &mut header,
        &mut offset,
        &channel_type(channels, 0).to_le_bytes(),
    );
    put_bytes(&mut header, &mut offset, &channels.to_le_bytes());
    put_bytes(&mut header, &mut offset, &sample_rate.to_le_bytes());
    put_bytes(&mut header, &mut offset, &1u32.to_le_bytes());
    put_bytes(&mut header, &mut offset, &sample_count.to_le_bytes());
    put_bytes(
        &mut header,
        &mut offset,
        &(DSF_BLOCK_SIZE_PER_CHANNEL as u32).to_le_bytes(),
    );
    put_bytes(&mut header, &mut offset, &0u32.to_le_bytes());

    // data chunk：标识与 audio data 长度（含 12 字节头）。
    put_bytes(&mut header, &mut offset, DATA_CHUNK_ID);
    put_bytes(
        &mut header,
        &mut offset,
        &DATA_CHUNK_HEADER_SIZE.saturating_add(data_bytes).to_le_bytes(),
    );

    header
}

/// 按毫秒时长估算虚拟 WAV 的 data 字节数。
///
/// 帧数按 `duration_ms * out_rate / 1000` 向下取整，再乘以声道数与每样本字节数。
#[frb(ignore)]
pub(super) fn wav_data_bytes(
    duration_ms: u64,
    out_rate: u32,
    channels: u32,
    bit_depth: u16,
) -> u64 {
    let bytes_per_sample = u64::from(bit_depth / 8);
    if out_rate == 0 || channels == 0 || bytes_per_sample == 0 {
        return 0;
    }
    let frames = u128::from(duration_ms) * u128::from(out_rate) / 1_000;
    let data = frames * u128::from(channels) * u128::from(bytes_per_sample);
    u64::try_from(data).unwrap_or(u64::MAX)
}

/// 构造 44 字节的标准 PCM WAV 头，字段顺序与本项目的 PCM 写入器一致。
///
/// RIFF 与 data 长度字段是 32 位，超过 4 GiB 时按上限截断并记录警告；调用方
/// 应把截断视为格式限制，播放会在 4 GiB 处提前结束。
#[frb(ignore)]
pub(super) fn wav_header(
    channels: u32,
    sample_rate: u32,
    bit_depth: u16,
    data_bytes: u64,
) -> [u8; WAV_HEADER_LEN as usize] {
    let mut header = [0u8; WAV_HEADER_LEN as usize];
    let bytes_per_sample = bit_depth / 8;
    let block_align = u32::try_from(u64::from(channels) * u64::from(bytes_per_sample))
        .unwrap_or(u32::MAX);
    let byte_rate = u64::from(sample_rate) * u64::from(block_align);
    let byte_rate = u32::try_from(byte_rate).unwrap_or(u32::MAX);
    let riff_limit = u64::from(u32::MAX) - 36;
    let data_size = if data_bytes > riff_limit {
        log::warn!(
            "虚拟 WAV 数据 {data_bytes} 字节超过 RIFF 32 位上限，按 {riff_limit} 字节截断: rate={sample_rate}, depth={bit_depth}, channels={channels}"
        );
        riff_limit
    } else {
        data_bytes
    };
    let data_size = data_size as u32;

    let mut offset = 0usize;
    put_bytes(&mut header, &mut offset, b"RIFF");
    put_bytes(
        &mut header,
        &mut offset,
        &(36u32.saturating_add(data_size)).to_le_bytes(),
    );
    put_bytes(&mut header, &mut offset, b"WAVE");
    put_bytes(&mut header, &mut offset, b"fmt ");
    put_bytes(&mut header, &mut offset, &16u32.to_le_bytes());
    put_bytes(&mut header, &mut offset, &1u16.to_le_bytes());
    put_bytes(
        &mut header,
        &mut offset,
        &u16::try_from(channels).unwrap_or(u16::MAX).to_le_bytes(),
    );
    put_bytes(&mut header, &mut offset, &sample_rate.to_le_bytes());
    put_bytes(&mut header, &mut offset, &byte_rate.to_le_bytes());
    put_bytes(
        &mut header,
        &mut offset,
        &u16::try_from(block_align).unwrap_or(u16::MAX).to_le_bytes(),
    );
    put_bytes(&mut header, &mut offset, &bit_depth.to_le_bytes());
    put_bytes(&mut header, &mut offset, b"data");
    put_bytes(&mut header, &mut offset, &data_size.to_le_bytes());

    header
}

/// 把 DSF data 内的偏移拆成块号与块内偏移。
///
/// 返回 `(block, within)`：`block` 是 DSF 块序号（每块 `4096 * channels` 字节），
/// `within` 是块内字节偏移。
#[frb(ignore)]
pub(super) fn dsf_block_position(data_offset: u64, channels: u32) -> (u64, u64) {
    if channels == 0 {
        return (0, 0);
    }
    let stride = u64::from(DSF_BLOCK_SIZE_PER_CHANNEL as u64) * u64::from(channels);
    (data_offset / stride, data_offset % stride)
}

/// 每帧每通道的 DSD 字节数（SACD 时间码一帧为 1/75 秒）。
#[frb(ignore)]
pub(super) fn frame_bytes_per_channel(sample_rate: u32) -> u64 {
    u64::from(sample_rate) / SACD_FRAMES_PER_SECOND / 8
}

/// 帧数估算：`ceil(duration_ms * 75 / 1000)`，至少 1。
#[frb(ignore)]
pub(super) fn frame_count(duration_ms: u64) -> u64 {
    let frames = u128::from(duration_ms) * u128::from(SACD_FRAMES_PER_SECOND) / 1_000;
    let frames = u64::try_from(frames).unwrap_or(u64::MAX);
    frames.max(1)
}

/// 把虚拟 WAV 的 data 偏移换算为每通道 DSD 字节位置。
///
/// `frames = data_offset / (channels * bytes_per_sample)`，
/// `dsd_bytes = frames * (dsd_rate / 8) / out_rate`（向下取整）。每通道的 DSD
/// 字节率是采样率除以 8，所以换算结果与 `length_lsn` 估算的字节数同量级；
/// 与滤波器实际产出可能有一帧以内的出入，尾部以真实 EOF 为准。
#[frb(ignore)]
pub(super) fn pcm_offset_to_dsd_bytes(
    data_offset: u64,
    channels: u32,
    bytes_per_sample: u16,
    dsd_rate: u32,
    out_rate: u32,
) -> u64 {
    let frame_stride = u64::from(channels).saturating_mul(u64::from(bytes_per_sample));
    if frame_stride == 0 || out_rate == 0 {
        return 0;
    }
    let frames = data_offset / frame_stride;
    let dsd_bits = u128::from(frames) * u128::from(dsd_rate) / u128::from(out_rate);
    u64::try_from(dsd_bits / 8).unwrap_or(u64::MAX)
}

/// 0.2 秒预滚对应的每通道 DSD 字节数。
#[frb(ignore)]
pub(super) fn preroll_dsd_bytes(sample_rate: u32) -> u64 {
    // 0.2 秒 = 1/5 秒；每通道每秒 sample_rate / 8 字节。
    u64::from(sample_rate) / 8 / 5
}

/// 0.2 秒预滚对应的输出 PCM 帧数。
#[frb(ignore)]
pub(super) fn preroll_pcm_frames(out_rate: u32) -> u64 {
    u64::from(out_rate) / 5
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::super::SACD_SAMPLE_RATE_HZ;

    fn read_u32(bytes: &[u8], offset: usize) -> u32 {
        let target = bytes.get(offset..offset + 4).expect("读取 u32 越界");
        u32::from_le_bytes(target.try_into().expect("u32 长度错误"))
    }

    fn read_u64(bytes: &[u8], offset: usize) -> u64 {
        let target = bytes.get(offset..offset + 8).expect("读取 u64 越界");
        u64::from_le_bytes(target.try_into().expect("u64 长度错误"))
    }

    #[test]
    fn dsf_header_places_fields_at_dsf_offsets() {
        let data_bytes = 4096 * 2;
        let header = dsf_header(2, SACD_SAMPLE_RATE_HZ, 4096 * 8, data_bytes);

        assert_eq!(&header[0..4], b"DSD ");
        assert_eq!(read_u64(&header, 4), 28);
        assert_eq!(read_u64(&header, 12), 92 + data_bytes);
        assert_eq!(read_u64(&header, 20), 0);
        assert_eq!(&header[28..32], b"fmt ");
        assert_eq!(read_u64(&header, 32), 52);
        assert_eq!(read_u32(&header, 40), 1);
        assert_eq!(read_u32(&header, 44), 0);
        assert_eq!(read_u32(&header, 48), 2);
        assert_eq!(read_u32(&header, 52), 2);
        assert_eq!(read_u32(&header, 56), SACD_SAMPLE_RATE_HZ);
        assert_eq!(read_u32(&header, 60), 1);
        assert_eq!(read_u64(&header, 64), 4096 * 8);
        assert_eq!(read_u32(&header, 72), 4096);
        assert_eq!(read_u32(&header, 76), 0);
        assert_eq!(&header[80..84], b"data");
        assert_eq!(read_u64(&header, 84), 12 + data_bytes);
    }

    #[test]
    fn dsf_header_uses_six_channel_type() {
        let header = dsf_header(6, SACD_SAMPLE_RATE_HZ, 0, 0);
        assert_eq!(read_u32(&header, 48), 7);
    }

    #[test]
    fn wav_header_places_fields_at_wav_offsets() {
        let header = wav_header(2, 44_100, 16, 1_000);
        assert_eq!(&header[0..4], b"RIFF");
        assert_eq!(read_u32(&header, 4), 36 + 1_000);
        assert_eq!(&header[8..12], b"WAVE");
        assert_eq!(&header[12..16], b"fmt ");
        assert_eq!(read_u32(&header, 16), 16);
        assert_eq!(u16::from_le_bytes(header[20..22].try_into().unwrap()), 1);
        assert_eq!(u16::from_le_bytes(header[22..24].try_into().unwrap()), 2);
        assert_eq!(read_u32(&header, 24), 44_100);
        assert_eq!(read_u32(&header, 28), 44_100 * 4);
        assert_eq!(u16::from_le_bytes(header[32..34].try_into().unwrap()), 4);
        assert_eq!(u16::from_le_bytes(header[34..36].try_into().unwrap()), 16);
        assert_eq!(&header[36..40], b"data");
        assert_eq!(read_u32(&header, 40), 1_000);
    }

    #[test]
    fn dsf_data_bytes_aligns_to_block() {
        // 1 秒 DSD64 每通道 352800 字节，对齐到 87 个 4096 字节块。
        let per_channel = dsf_bytes_per_channel(1_000, SACD_SAMPLE_RATE_HZ);
        assert_eq!(per_channel % 4096, 0);
        assert_eq!(per_channel, 87 * 4096);

        let data = dsf_data_bytes(1_000, 2, SACD_SAMPLE_RATE_HZ);
        assert_eq!(data, per_channel * 2);
    }

    #[test]
    fn dsf_data_bytes_zero_for_missing_duration() {
        assert_eq!(dsf_data_bytes(0, 2, SACD_SAMPLE_RATE_HZ), 0);
        assert_eq!(dsf_data_bytes(1_000, 0, SACD_SAMPLE_RATE_HZ), 0);
    }

    #[test]
    fn dsf_block_position_splits_block_and_offset() {
        let stride = 4096 * 2;
        assert_eq!(dsf_block_position(0, 2), (0, 0));
        assert_eq!(dsf_block_position(stride as u64, 2), (1, 0));
        assert_eq!(dsf_block_position(stride as u64 + 5, 2), (1, 5));
        assert_eq!(dsf_block_position(4096, 2), (0, 4096));
    }

    #[test]
    fn pcm_offset_to_dsd_bytes_scales_by_rate_ratio() {
        // 44.1kHz 一帧的 2ch 24bit 数据 = 6 字节，对应每通道 8 个 DSD 字节（64 bit）。
        assert_eq!(
            pcm_offset_to_dsd_bytes(6, 2, 3, SACD_SAMPLE_RATE_HZ, 44_100),
            8
        );
        assert_eq!(
            pcm_offset_to_dsd_bytes(0, 2, 3, SACD_SAMPLE_RATE_HZ, 44_100),
            0
        );
        assert_eq!(
            pcm_offset_to_dsd_bytes(12, 2, 3, SACD_SAMPLE_RATE_HZ, 44_100),
            16
        );
    }

    #[test]
    fn frame_bytes_per_channel_matches_dsd64() {
        assert_eq!(frame_bytes_per_channel(SACD_SAMPLE_RATE_HZ), 4_704);
        assert_eq!(frame_count(1_000), 75);
        assert_eq!(frame_count(0), 1);
    }

    #[test]
    fn wav_data_bytes_uses_floor_frames() {
        assert_eq!(wav_data_bytes(1_000, 44_100, 2, 16), 44_100 * 4);
        assert_eq!(wav_data_bytes(0, 44_100, 2, 16), 0);
    }

    #[test]
    fn preroll_matches_fifth_of_second() {
        assert_eq!(preroll_dsd_bytes(SACD_SAMPLE_RATE_HZ), 70_560);
        assert_eq!(preroll_pcm_frames(44_100), 8_820);
    }
}
