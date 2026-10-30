//! Area TOC 内的轨道列表解析。
//!
//! - `SACDTRL1`：255 组 `start_lsn` + 255 组 `length_lsn`（各 4 字节大端）。
//! - `SACDTRL2`：255 组起始时间 + 255 组时长（各 4 字节：分、秒、帧、标志）。
//!
//! 两个列表都位于 Area TOC 数据内，按 2048 字节扇区步长扫描签名。

use super::types::{
    timecode_to_ms, SacdError, SacdTrack, SliceReader, SACD_LSN_SIZE,
};

/// 轨道起长列表签名。
const TRACK_LIST_1_SIGNATURE: &[u8] = b"SACDTRL1";

/// 轨道时间列表签名。
const TRACK_LIST_2_SIGNATURE: &[u8] = b"SACDTRL2";

/// 每个轨道的表项数量（规范固定为 255）。
const TRACK_LIST_CAPACITY: usize = 255;

/// 单个时间码表项的字节数。
const TRACK_TIME_ENTRY_SIZE: usize = 4;

/// Area TOC 内找到的轨道列表。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct AreaTrackLists {
    /// 轨道起长列表。
    pub(super) list_1: Option<TrackList1>,
    /// 轨道时间列表。
    pub(super) list_2: Option<TrackList2>,
}

/// `SACDTRL1` 中与轨道数对应的前若干项。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct TrackList1 {
    /// 各轨起始 LSN。
    pub(super) starts: Vec<u32>,
    /// 各轨长度（LSN）。
    pub(super) lengths: Vec<u32>,
}

/// `SACDTRL2` 中与轨道数对应的前若干项，时间已换算为毫秒。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct TrackList2 {
    /// 各轨起始时间（毫秒）。
    pub(super) starts_ms: Vec<u64>,
    /// 各轨时长（毫秒）。
    pub(super) durations_ms: Vec<u64>,
}

/// 扫描 Area TOC 数据中的所有扇区，解析存在的轨道列表。
///
/// 第 0 个扇区是 Area TOC 头部，从第 1 个扇区开始扫描。
pub(super) fn parse_track_lists(
    area_bytes: &[u8],
    toc_sectors: u16,
    track_count: u16,
) -> Result<AreaTrackLists, SacdError> {
    let mut list_1 = None;
    let mut list_2 = None;

    for sector_index in 1..usize::from(toc_sectors) {
        let offset = sector_index
            .checked_mul(SACD_LSN_SIZE)
            .ok_or_else(|| SacdError::invalid("Area TOC 扇区偏移溢出"))?;
        let end = offset
            .checked_add(SACD_LSN_SIZE)
            .ok_or_else(|| SacdError::invalid("Area TOC 扇区范围溢出"))?;
        let sector = area_bytes.get(offset..end).ok_or_else(|| {
            SacdError::invalid(format!("Area TOC 第 {sector_index} 个扇区超出数据范围"))
        })?;

        let signature = sector
            .get(..8)
            .ok_or_else(|| SacdError::invalid("Area TOC 扇区不足 8 字节"))?;

        if list_1.is_none() && signature == TRACK_LIST_1_SIGNATURE {
            list_1 = Some(TrackList1::parse(sector, track_count)?);
        } else if list_2.is_none() && signature == TRACK_LIST_2_SIGNATURE {
            list_2 = Some(TrackList2::parse(sector, track_count)?);
        }
    }

    Ok(AreaTrackLists { list_1, list_2 })
}

impl TrackList1 {
    /// 解析一个 `SACDTRL1` 扇区。
    fn parse(sector: &[u8], track_count: u16) -> Result<Self, SacdError> {
        let mut reader = SliceReader::new(sector);
        let signature = reader.read_bytes(8)?; // 0x0000..0x0008
        if signature != TRACK_LIST_1_SIGNATURE {
            return Err(SacdError::invalid("SACDTRL1 签名不匹配"));
        }

        let wanted = usize::from(track_count);
        let mut starts = Vec::with_capacity(wanted);
        for _ in 0..wanted {
            starts.push(reader.read_u32()?);
        }

        // 跳过第 track_count 项之后剩余的起始 LSN 表项。
        let remaining = TRACK_LIST_CAPACITY
            .checked_sub(wanted)
            .ok_or_else(|| SacdError::invalid("轨道数超过 SACDTRL1 容量"))?;
        let skip_bytes = remaining
            .checked_mul(4)
            .ok_or_else(|| SacdError::invalid("SACDTRL1 偏移溢出"))?;
        reader.skip(skip_bytes)?;

        let mut lengths = Vec::with_capacity(wanted);
        for _ in 0..wanted {
            lengths.push(reader.read_u32()?);
        }

        Ok(Self { starts, lengths })
    }
}

impl TrackList2 {
    /// 解析一个 `SACDTRL2` 扇区。
    fn parse(sector: &[u8], track_count: u16) -> Result<Self, SacdError> {
        let mut reader = SliceReader::new(sector);
        let signature = reader.read_bytes(8)?; // 0x0000..0x0008
        if signature != TRACK_LIST_2_SIGNATURE {
            return Err(SacdError::invalid("SACDTRL2 签名不匹配"));
        }

        let wanted = usize::from(track_count);
        let mut starts_ms = Vec::with_capacity(wanted);
        for _ in 0..wanted {
            starts_ms.push(read_timecode(&mut reader)?);
        }

        // 跳过第 track_count 项之后剩余的起始时间表项。
        let remaining = TRACK_LIST_CAPACITY
            .checked_sub(wanted)
            .ok_or_else(|| SacdError::invalid("轨道数超过 SACDTRL2 容量"))?;
        let skip_bytes = remaining
            .checked_mul(TRACK_TIME_ENTRY_SIZE)
            .ok_or_else(|| SacdError::invalid("SACDTRL2 偏移溢出"))?;
        reader.skip(skip_bytes)?;

        let mut durations_ms = Vec::with_capacity(wanted);
        for _ in 0..wanted {
            durations_ms.push(read_timecode(&mut reader)?);
        }

        Ok(Self {
            starts_ms,
            durations_ms,
        })
    }
}

/// 读取一个 4 字节时间码表项（分、秒、帧、标志）并换算为毫秒。
fn read_timecode(reader: &mut SliceReader<'_>) -> Result<u64, SacdError> {
    let minutes = reader.read_u8()?;
    let seconds = reader.read_u8()?;
    let frames = reader.read_u8()?;
    let _flags = reader.read_u8()?;
    Ok(timecode_to_ms(minutes, seconds, frames))
}

/// 按轨号合并 LSN 列表与时间列表，生成最终轨道数据。
///
/// `SACDTRL1` 是轨道 LSN 的必需来源；`SACDTRL2` 缺失时时间字段为 0。
pub(super) fn build_tracks(
    track_count: u16,
    list_1: Option<&TrackList1>,
    list_2: Option<&TrackList2>,
) -> Result<Vec<SacdTrack>, SacdError> {
    let list_1 = list_1.ok_or_else(|| SacdError::invalid("未找到 SACDTRL1 轨道起长表"))?;

    let mut tracks = Vec::with_capacity(usize::from(track_count));
    for index in 0..usize::from(track_count) {
        let number = u16::try_from(index + 1)
            .map_err(|_| SacdError::invalid("轨号超出 u16 范围"))?;
        let start_lsn = *list_1.starts.get(index).ok_or_else(|| {
            SacdError::invalid(format!("SACDTRL1 缺少第 {number} 轨的起始 LSN"))
        })?;
        let length_lsn = *list_1.lengths.get(index).ok_or_else(|| {
            SacdError::invalid(format!("SACDTRL1 缺少第 {number} 轨的长度"))
        })?;

        let (start_ms, duration_ms) = match list_2 {
            Some(list_2) => {
                let start_ms = *list_2.starts_ms.get(index).ok_or_else(|| {
                    SacdError::invalid(format!("SACDTRL2 缺少第 {number} 轨的起始时间"))
                })?;
                let duration_ms = *list_2.durations_ms.get(index).ok_or_else(|| {
                    SacdError::invalid(format!("SACDTRL2 缺少第 {number} 轨的时长"))
                })?;
                (start_ms, duration_ms)
            }
            None => (0, 0),
        };

        tracks.push(SacdTrack {
            number,
            start_lsn,
            length_lsn,
            start_ms,
            duration_ms,
        });
    }

    Ok(tracks)
}
