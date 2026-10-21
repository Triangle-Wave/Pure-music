//! Area TOC（双声道 / 多声道音频区目录）解析。
//!
//! 字段偏移取自 Scarlet Book 的 Area_TOC 结构：
//! `TWOCHTOC` / `MULCHTOC` 签名 + 版本 + 长度 + 音频参数 + 轨道范围。

use super::types::{
    timecode_to_ms, validate_version, SacdAreaKind, SacdError, SacdFrameFormat, SliceReader,
    MAX_AREA_TOC_SECTORS, MAX_TRACK_COUNT, MIN_AREA_TOC_SECTORS, SACD_LSN_SIZE,
};

/// 双声道 Area TOC 签名。
const AREA_TOC_TWO_CHANNEL_SIGNATURE: &[u8] = b"TWOCHTOC";

/// 多声道 Area TOC 签名。
const AREA_TOC_MULTI_CHANNEL_SIGNATURE: &[u8] = b"MULCHTOC";

/// Area TOC 首个扇区中的头部字段。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct AreaTocHeader {
    /// 音频区类型，由签名决定。
    pub(super) kind: SacdAreaKind,
    /// Area TOC 长度，单位扇区（偏移 0x000A）。
    pub(super) toc_sectors: u16,
    /// 声道数（偏移 0x0020）。
    pub(super) channel_count: u8,
    /// 轨道数（偏移 0x0045）。
    pub(super) track_count: u16,
    /// 全区总播放时长（毫秒）。
    pub(super) total_playtime_ms: u64,
    /// 帧格式（Area_Flags 低 4 位，偏移 0x0015）。
    pub(super) frame_format: SacdFrameFormat,
    /// 音频区起始 LSN（偏移 0x0048）。
    pub(super) track_start_lsn: u32,
    /// 音频区结束 LSN（偏移 0x004C）。
    pub(super) track_end_lsn: u32,
}

impl AreaTocHeader {
    /// 从 Area TOC 数据（至少一个扇区）解析头部。
    pub(super) fn parse(bytes: &[u8]) -> Result<Self, SacdError> {
        let sector = bytes
            .get(..SACD_LSN_SIZE)
            .ok_or_else(|| SacdError::invalid("Area TOC 数据不足一个扇区"))?;
        let mut reader = SliceReader::new(sector);

        let signature = reader.read_bytes(8)?; // 0x0000..0x0008
        let kind = if signature == AREA_TOC_TWO_CHANNEL_SIGNATURE {
            SacdAreaKind::TwoChannel
        } else if signature == AREA_TOC_MULTI_CHANNEL_SIGNATURE {
            SacdAreaKind::MultiChannel
        } else {
            return Err(SacdError::invalid(format!(
                "Area TOC 签名无效: {}",
                String::from_utf8_lossy(signature)
            )));
        };

        let version_major = reader.read_u8()?; // 0x0008
        let version_minor = reader.read_u8()?; // 0x0009
        validate_version(version_major, version_minor)?;

        let toc_sectors = reader.read_u16()?; // 0x000A
        if !(MIN_AREA_TOC_SECTORS..=MAX_AREA_TOC_SECTORS).contains(&toc_sectors) {
            return Err(SacdError::invalid(format!(
                "Area TOC 长度 {toc_sectors} 不在 {}..={} 范围内",
                MIN_AREA_TOC_SECTORS, MAX_AREA_TOC_SECTORS
            )));
        }

        reader.skip(4)?; // 0x000C..0x0010 reserved
        let _max_byte_rate = reader.read_u32()?; // 0x0010
        let _sample_frequency = reader.read_u8()?; // 0x0014
        let area_flags = reader.read_u8()?; // 0x0015
        let frame_format = if area_flags & 0x0F == 0 {
            SacdFrameFormat::Dst
        } else {
            // 1 为保留值，2..=7 为固定 DSD 格式（3-in-14、3-in-16 等），
            // 8..=15 未定义；除 DST 外统一按未压缩 DSD 处理。
            SacdFrameFormat::Dsd
        };

        reader.skip(10)?; // 0x0016..0x0020 reserved
        let channel_count = reader.read_u8()?; // 0x0020
        if !(1..=8).contains(&channel_count) {
            return Err(SacdError::invalid(format!(
                "Area TOC 声道数 {channel_count} 不在 1..=8 范围内"
            )));
        }

        reader.skip(1)?; // 0x0021 Area_Config
        reader.skip(1)?; // 0x0022 Max_Available_Channels
        reader.skip(1)?; // 0x0023 Area_Mute_Flags
        reader.skip(12)?; // 0x0024..0x0030 reserved
        reader.skip(1)?; // 0x0030 Area_Copy_Management
        reader.skip(15)?; // 0x0031..0x0040 reserved

        let total_minutes = reader.read_u8()?; // 0x0040
        let total_seconds = reader.read_u8()?; // 0x0041
        let total_frames = reader.read_u8()?; // 0x0042
        reader.skip(1)?; // 0x0043 reserved
        let _track_offset = reader.read_u8()?; // 0x0044
        let track_count = u16::from(reader.read_u8()?); // 0x0045
        if !(1..=MAX_TRACK_COUNT).contains(&track_count) {
            return Err(SacdError::invalid(format!(
                "Area TOC 轨道数 {track_count} 不在 1..={MAX_TRACK_COUNT} 范围内"
            )));
        }

        reader.skip(2)?; // 0x0046..0x0048 reserved
        let track_start_lsn = reader.read_u32()?; // 0x0048
        let track_end_lsn = reader.read_u32()?; // 0x004C

        Ok(Self {
            kind,
            toc_sectors,
            channel_count,
            track_count,
            total_playtime_ms: timecode_to_ms(total_minutes, total_seconds, total_frames),
            frame_format,
            track_start_lsn,
            track_end_lsn,
        })
    }
}
