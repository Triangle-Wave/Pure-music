//! SACD 只读解析模块的公共数据类型、错误定义与字节读取工具。

use std::fmt;
use std::io;

/// SACD 逻辑扇区大小（字节）。
pub(crate) const SACD_LSN_SIZE: usize = 2048;

/// Area TOC 允许的最小扇区数。
pub(crate) const MIN_AREA_TOC_SECTORS: u16 = 5;

/// Area TOC 允许的最大扇区数。
pub(crate) const MAX_AREA_TOC_SECTORS: u16 = 64;

/// 单个 Area 允许的最大轨道数。
pub(crate) const MAX_TRACK_COUNT: u16 = 99;

/// SACD 时间码帧率：每秒 75 帧。
const FRAMES_PER_SECOND: u64 = 75;

/// 解析后的 SACD 目录结构。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SacdToc {
    /// Master TOC 版本主号。
    pub(crate) version_major: u8,
    /// Master TOC 版本次号。
    pub(crate) version_minor: u8,
    /// 光盘标志位（bit 7 表示 Hybrid）。
    pub(crate) disc_flags: u8,
    /// 套装内光盘总数。
    pub(crate) album_set_size: u16,
    /// 当前光盘在套装内的序号。
    pub(crate) album_sequence_number: u16,
    /// 光盘上存在的音频区，双声道区排在多声道区之前。
    pub(crate) areas: Vec<SacdArea>,
}

/// 单个音频区（2CH 或 MCH）的目录信息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SacdArea {
    /// 音频区类型。
    pub(crate) kind: SacdAreaKind,
    /// 声道数。
    pub(crate) channel_count: u8,
    /// 轨道数。
    pub(crate) track_count: u16,
    /// 全区总播放时长（毫秒）。
    pub(crate) total_playtime_ms: u64,
    /// 帧格式：DST 或裸 DSD。
    pub(crate) frame_format: SacdFrameFormat,
    /// 音频区起始逻辑扇区号。
    pub(crate) track_start_lsn: u32,
    /// 音频区结束逻辑扇区号。
    pub(crate) track_end_lsn: u32,
    /// 轨道列表。
    pub(crate) tracks: Vec<SacdTrack>,
}

/// 单条轨道信息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SacdTrack {
    /// 轨号，从 1 开始。
    pub(crate) number: u16,
    /// 起始逻辑扇区号。
    pub(crate) start_lsn: u32,
    /// 轨道长度（逻辑扇区数）。
    pub(crate) length_lsn: u32,
    /// 起始时间（毫秒）；缺少 SACDTRL2 时为 0。
    pub(crate) start_ms: u64,
    /// 播放时长（毫秒）；缺少 SACDTRL2 时为 0。
    pub(crate) duration_ms: u64,
}

/// 音频区类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SacdAreaKind {
    /// 双声道区（TWOCHTOC）。
    TwoChannel,
    /// 多声道区（MULCHTOC）。
    MultiChannel,
}

/// 音频帧格式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SacdFrameFormat {
    /// DST 压缩帧。
    Dst,
    /// 裸 DSD 帧（包含 3-in-14、3-in-16 等固定格式）。
    Dsd,
}

/// SACD 解析错误。
#[derive(Debug)]
pub(crate) enum SacdError {
    /// 文件读取、定位或元数据获取失败。
    Io(io::Error),
    /// 魔数不匹配，目标不是 SACD 镜像。
    NotSacd,
    /// 数据结构损坏、字段越界或缺少必需结构。
    InvalidData(String),
    /// 版本或特性暂不支持。
    Unsupported,
}

impl SacdError {
    /// 构造带说明的无效数据错误。
    pub(crate) fn invalid(message: impl Into<String>) -> Self {
        Self::InvalidData(message.into())
    }
}

impl fmt::Display for SacdError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(f, "读取 SACD 镜像失败: {error}"),
            Self::NotSacd => f.write_str("目标文件不是 SACD 镜像"),
            Self::InvalidData(message) => write!(f, "SACD 数据结构无效: {message}"),
            Self::Unsupported => f.write_str("暂不支持的 SACD 版本或特性"),
        }
    }
}

impl std::error::Error for SacdError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<io::Error> for SacdError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// 校验 SACD 规范版本。
///
/// 已知光盘使用 1.00 / 1.10 / 1.20（主号 1，次号 0x00 / 0x10 / 0x14）。
/// 这里接受 1.x 且次号不超过 0x20 的版本，其余版本交由调用方按不支持处理。
pub(crate) fn validate_version(major: u8, minor: u8) -> Result<(), SacdError> {
    if major != 1 || minor > 0x20 {
        return Err(SacdError::Unsupported);
    }
    Ok(())
}

/// 将 SACD 时间码（分:秒:帧，75 帧/秒）换算为毫秒。
pub(crate) fn timecode_to_ms(minutes: u8, seconds: u8, frames: u8) -> u64 {
    let minutes = u64::from(minutes);
    let seconds = u64::from(seconds);
    let frames = u64::from(frames);
    (minutes * 60 + seconds) * 1000 + frames * 1000 / FRAMES_PER_SECOND
}

/// 带边界检查的顺序字节读取器。
///
/// 所有偏移计算都使用 `checked_add`，所有切片访问都通过 `get`，
/// 越界时返回 [`SacdError::InvalidData`]，不会 panic。
pub(crate) struct SliceReader<'a> {
    data: &'a [u8],
    position: usize,
}

impl<'a> SliceReader<'a> {
    /// 创建从起始位置读取的读取器。
    pub(crate) fn new(data: &'a [u8]) -> Self {
        Self { data, position: 0 }
    }

    /// 当前读取位置。
    pub(crate) fn position(&self) -> usize {
        self.position
    }

    /// 跳过指定字节数。
    pub(crate) fn skip(&mut self, len: usize) -> Result<(), SacdError> {
        let end = self
            .position
            .checked_add(len)
            .ok_or_else(|| SacdError::invalid("解析偏移溢出"))?;
        if end > self.data.len() {
            return Err(SacdError::invalid(format!(
                "数据在偏移 {} 处截断，无法跳过 {len} 字节",
                self.position
            )));
        }
        self.position = end;
        Ok(())
    }

    /// 读取指定长度的字节切片。
    pub(crate) fn read_bytes(&mut self, len: usize) -> Result<&'a [u8], SacdError> {
        let end = self
            .position
            .checked_add(len)
            .ok_or_else(|| SacdError::invalid("解析偏移溢出"))?;
        let data = self.data;
        let bytes = data.get(self.position..end).ok_or_else(|| {
            SacdError::invalid(format!(
                "数据在偏移 {} 处截断，需要 {len} 字节",
                self.position
            ))
        })?;
        self.position = end;
        Ok(bytes)
    }

    /// 读取 1 字节。
    pub(crate) fn read_u8(&mut self) -> Result<u8, SacdError> {
        let bytes = self.read_bytes(1)?;
        let value = bytes
            .first()
            .copied()
            .ok_or_else(|| SacdError::invalid("读取 u8 失败"))?;
        Ok(value)
    }

    /// 读取 2 字节大端无符号整数。
    pub(crate) fn read_u16(&mut self) -> Result<u16, SacdError> {
        let bytes = self.read_bytes(2)?;
        let array: [u8; 2] = bytes
            .try_into()
            .map_err(|_| SacdError::invalid("读取 u16 失败"))?;
        Ok(u16::from_be_bytes(array))
    }

    /// 读取 4 字节大端无符号整数。
    pub(crate) fn read_u32(&mut self) -> Result<u32, SacdError> {
        let bytes = self.read_bytes(4)?;
        let array: [u8; 4] = bytes
            .try_into()
            .map_err(|_| SacdError::invalid("读取 u32 失败"))?;
        Ok(u32::from_be_bytes(array))
    }
}
