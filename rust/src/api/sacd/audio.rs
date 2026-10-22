//! SACD 音频扇区解析。
//!
//! 音频扇区由扇区头、数据包信息表、帧信息表与若干数据包组成。本模块只交付
//! 裸 DSD（3-in-14 / 3-in-16）负载：DST 压缩扇区直接返回
//! [`SacdError::Unsupported`]，补充数据包与填充数据包跳过。

use super::types::SacdError;
use flutter_rust_bridge::frb;

/// 音频扇区固定长度（字节）。
const AUDIO_SECTOR_SIZE: usize = 2048;

/// 数据包类型：音频数据。
const DATA_TYPE_AUDIO: u8 = 2;

/// SACD 音频扇区头（每个音频扇区的第 1 个字节）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[frb(ignore)]
pub(crate) struct AudioFrameHeader {
    /// DST 压缩标志。
    pub(crate) dst_encoded: bool,
    /// 帧起始数量（N_Frame_Starts）。
    pub(crate) frame_info_count: u8,
    /// 数据包数量（N_Packets）。
    pub(crate) packet_info_count: u8,
}

impl AudioFrameHeader {
    /// 从扇区首字节解析音频扇区头。
    pub(crate) fn from_byte(byte: u8) -> Self {
        Self {
            dst_encoded: (byte & 0x01) != 0,
            frame_info_count: (byte >> 2) & 0x07,
            packet_info_count: (byte >> 5) & 0x07,
        }
    }
}

/// 音频数据包信息（2 字节）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[frb(ignore)]
pub(crate) struct AudioPacketInfo {
    /// 该包是否为一个新帧的起点。
    pub(crate) frame_start: bool,
    /// 包数据类型：2 为音频，3 为补充数据，7 为填充。
    pub(crate) data_type: u8,
    /// 包负载长度（字节）。
    pub(crate) packet_length: u16,
}

impl AudioPacketInfo {
    /// 从 2 字节数据包信息解析。
    pub(crate) fn from_bytes(bytes: &[u8]) -> Result<Self, SacdError> {
        let first = bytes
            .first()
            .copied()
            .ok_or_else(|| SacdError::invalid("数据包信息缺少第 1 个字节"))?;
        let second = bytes
            .get(1)
            .copied()
            .ok_or_else(|| SacdError::invalid("数据包信息缺少第 2 个字节"))?;

        Ok(Self {
            frame_start: (first & 0x80) != 0,
            data_type: (first >> 3) & 0x07,
            packet_length: (u16::from(first & 0x07) << 8) | u16::from(second),
        })
    }
}

/// 音频帧信息。
///
/// 裸 DSD 的帧信息固定 3 字节（分、秒、帧号）；DST 帧额外带 1 字节，
/// 其中包含剩余扇区数与声道提示位。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[frb(ignore)]
pub(crate) struct AudioFrameInfo {
    /// 时间码分钟。
    pub(crate) minutes: u8,
    /// 时间码秒。
    pub(crate) seconds: u8,
    /// 时间码帧号（每秒 75 帧）。
    pub(crate) frames: u8,
    /// DST 帧剩余扇区数；裸 DSD 恒为 0。
    pub(crate) sector_count: u8,
}

impl AudioFrameInfo {
    /// 从帧信息字节解析；`dst_encoded` 决定帧信息是 4 字节还是 3 字节。
    pub(crate) fn from_bytes(bytes: &[u8], dst_encoded: bool) -> Result<Self, SacdError> {
        let required = if dst_encoded { 4 } else { 3 };
        if bytes.len() < required {
            return Err(SacdError::invalid(format!(
                "帧信息长度 {} 小于所需的 {required} 字节",
                bytes.len()
            )));
        }

        let minutes = bytes
            .first()
            .copied()
            .ok_or_else(|| SacdError::invalid("帧信息缺少分钟字节"))?;
        let seconds = bytes
            .get(1)
            .copied()
            .ok_or_else(|| SacdError::invalid("帧信息缺少秒字节"))?;
        let frames = bytes
            .get(2)
            .copied()
            .ok_or_else(|| SacdError::invalid("帧信息缺少帧号字节"))?;

        let sector_count = if dst_encoded {
            let extra = bytes
                .get(3)
                .copied()
                .ok_or_else(|| SacdError::invalid("DST 帧信息缺少扩展字节"))?;
            (extra >> 2) & 0x1F
        } else {
            0
        };

        Ok(Self {
            minutes,
            seconds,
            frames,
            sector_count,
        })
    }
}

/// 音频扇区解析器。
///
/// 维护跨扇区的音频缓冲；每次 [`parse_sector`](Self::parse_sector) 返回当前
/// 可交付的连续字节，剩余数据留待下一次调用或 [`flush`](Self::flush)。返回的
/// 字节保持原始字节交织顺序（MSB-first），由 DSF 写入器完成反位与分块。
#[derive(Debug, Default)]
#[frb(ignore)]
pub(crate) struct AudioSectorParser {
    /// 当前帧是否已经开始。
    frame_started: bool,
    /// 跨扇区累积的音频数据。
    frame_buffer: Vec<u8>,
    /// 累计交付的音频字节数。
    total_bytes: u64,
}

impl AudioSectorParser {
    /// 创建空解析器。
    pub(crate) fn new() -> Self {
        Self::default()
    }

    /// 累计交付的音频字节数。
    pub(crate) fn total_bytes(&self) -> u64 {
        self.total_bytes
    }

    /// 解析一个音频扇区，返回可交付的裸 DSD 字节。
    ///
    /// 遇到新帧起点时先交付上一帧已累积的数据；扇区结束时交付剩余数据。
    /// 同一扇区的后续帧数据留在缓冲区，等下一次调用交付，保证字节顺序完整。
    pub(crate) fn parse_sector(&mut self, sector: &[u8]) -> Result<Vec<u8>, SacdError> {
        if sector.len() < AUDIO_SECTOR_SIZE {
            return Err(SacdError::invalid(format!(
                "音频扇区长度 {} 小于 {AUDIO_SECTOR_SIZE} 字节",
                sector.len()
            )));
        }

        let first = sector
            .first()
            .copied()
            .ok_or_else(|| SacdError::invalid("音频扇区为空"))?;
        let header = AudioFrameHeader::from_byte(first);
        if header.dst_encoded {
            return Err(SacdError::Unsupported);
        }

        let mut offset = 1usize;

        let mut packets = Vec::with_capacity(usize::from(header.packet_info_count));
        for _ in 0..header.packet_info_count {
            let bytes = slice_at(sector, offset, 2)?;
            packets.push(AudioPacketInfo::from_bytes(bytes)?);
            offset = offset
                .checked_add(2)
                .ok_or_else(|| SacdError::invalid("音频扇区偏移溢出"))?;
        }

        // 裸 DSD 的帧信息固定 3 字节；时间码不参与提取，只校验结构完整。
        for _ in 0..header.frame_info_count {
            let bytes = slice_at(sector, offset, 3)?;
            let _frame_info = AudioFrameInfo::from_bytes(bytes, false)?;
            offset = offset
                .checked_add(3)
                .ok_or_else(|| SacdError::invalid("音频扇区偏移溢出"))?;
        }

        let mut output: Vec<u8> = Vec::new();
        for packet in packets {
            let packet_length = usize::from(packet.packet_length);
            let packet_data = slice_at(sector, offset, packet_length)?;
            offset = offset
                .checked_add(packet_length)
                .ok_or_else(|| SacdError::invalid("音频扇区偏移溢出"))?;

            if packet.data_type != DATA_TYPE_AUDIO {
                continue;
            }

            if packet.frame_start
                && self.frame_started
                && !self.frame_buffer.is_empty()
                && output.is_empty()
            {
                output = std::mem::take(&mut self.frame_buffer);
            }

            self.frame_started = true;
            self.frame_buffer.extend_from_slice(packet_data);
        }

        if output.is_empty() && !self.frame_buffer.is_empty() {
            output = std::mem::take(&mut self.frame_buffer);
        }

        self.total_bytes = self
            .total_bytes
            .saturating_add(output.len() as u64);
        Ok(output)
    }

    /// 交付缓冲区中剩余的音频数据；没有剩余时返回 `None`。
    pub(crate) fn flush(&mut self) -> Option<Vec<u8>> {
        self.frame_started = false;
        if self.frame_buffer.is_empty() {
            return None;
        }

        let data = std::mem::take(&mut self.frame_buffer);
        self.total_bytes = self.total_bytes.saturating_add(data.len() as u64);
        Some(data)
    }
}

/// 从 `data` 中取出 `offset` 起 `len` 字节，越界时返回错误。
fn slice_at(data: &[u8], offset: usize, len: usize) -> Result<&[u8], SacdError> {
    let end = offset
        .checked_add(len)
        .ok_or_else(|| SacdError::invalid("音频扇区偏移溢出"))?;
    data.get(offset..end).ok_or_else(|| {
        SacdError::invalid(format!(
            "音频扇区在偏移 {offset} 处截断，需要 {len} 字节"
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECTOR_SIZE: usize = 2048;

    /// 构造扇区头字节：裸 DSD + 指定帧信息数/数据包数。
    fn sector_header(frame_info_count: u8, packet_info_count: u8) -> u8 {
        ((frame_info_count & 0x07) << 2) | ((packet_info_count & 0x07) << 5)
    }

    /// 构造 2 字节数据包信息。
    fn packet_info(frame_start: bool, data_type: u8, len: u16) -> [u8; 2] {
        let first = (u8::from(frame_start) << 7)
            | ((data_type & 0x07) << 3)
            | ((len >> 8) as u8 & 0x07);
        [first, (len & 0xFF) as u8]
    }

    /// 构造只含一个音频包的最小扇区。
    fn build_sector(payload: &[u8], frame_start: bool) -> Vec<u8> {
        let mut sector = vec![0u8; SECTOR_SIZE];
        sector[0] = sector_header(1, 1);
        let info = packet_info(frame_start, DATA_TYPE_AUDIO, payload.len() as u16);
        sector[1] = info[0];
        sector[2] = info[1];
        // 帧信息位于 3..6，时间码全 0。
        let start = 6;
        let end = start + payload.len();
        assert!(end <= SECTOR_SIZE, "测试音频负载超出扇区");
        sector[start..end].copy_from_slice(payload);
        sector
    }

    #[test]
    fn frame_header_decodes_flags_and_counts() {
        let header = AudioFrameHeader::from_byte(0x24);
        assert!(!header.dst_encoded);
        assert_eq!(header.frame_info_count, 1);
        assert_eq!(header.packet_info_count, 1);

        let header = AudioFrameHeader::from_byte(0x25);
        assert!(header.dst_encoded);
        assert_eq!(header.frame_info_count, 1);
        assert_eq!(header.packet_info_count, 1);

        let header = AudioFrameHeader::from_byte(0xFC);
        assert!(!header.dst_encoded);
        assert_eq!(header.frame_info_count, 7);
        assert_eq!(header.packet_info_count, 7);
    }

    #[test]
    fn packet_info_decodes_frame_start_type_and_length() {
        let info = AudioPacketInfo::from_bytes(&[0x97, 0xF9]).expect("解析数据包信息");
        assert!(info.frame_start);
        assert_eq!(info.data_type, DATA_TYPE_AUDIO);
        assert_eq!(info.packet_length, 2041);

        let info = AudioPacketInfo::from_bytes(&[0x10, 0x00]).expect("解析数据包信息");
        assert!(!info.frame_start);
        assert_eq!(info.data_type, DATA_TYPE_AUDIO);
        assert_eq!(info.packet_length, 0);

        assert!(AudioPacketInfo::from_bytes(&[0x80]).is_err());
    }

    #[test]
    fn frame_info_decodes_dsd_and_dst_layouts() {
        let dsd = AudioFrameInfo::from_bytes(&[1, 2, 3], false).expect("解析 DSD 帧信息");
        assert_eq!((dsd.minutes, dsd.seconds, dsd.frames), (1, 2, 3));
        assert_eq!(dsd.sector_count, 0);

        let dst = AudioFrameInfo::from_bytes(&[4, 5, 6, 0xA6], true).expect("解析 DST 帧信息");
        assert_eq!((dst.minutes, dst.seconds, dst.frames), (4, 5, 6));
        // 0xA6 >> 2 & 0x1F = 9；低两位是声道提示位。
        assert_eq!(dst.sector_count, 9);

        assert!(AudioFrameInfo::from_bytes(&[1, 2], false).is_err());
        assert!(AudioFrameInfo::from_bytes(&[1, 2, 3], true).is_err());
    }

    #[test]
    fn parse_sector_returns_audio_payload() {
        let payload: Vec<u8> = (0..1024).map(|index| (index % 251) as u8).collect();
        let sector = build_sector(&payload, true);

        let mut parser = AudioSectorParser::new();
        let audio = parser.parse_sector(&sector).expect("解析音频扇区");
        assert_eq!(audio, payload);
        assert_eq!(parser.total_bytes(), payload.len() as u64);
    }

    #[test]
    fn parse_sector_joins_across_sectors() {
        let first: Vec<u8> = (0..1000).map(|index| (index % 199) as u8).collect();
        let second: Vec<u8> = (0..900).map(|index| (index % 173) as u8).collect();

        let mut parser = AudioSectorParser::new();
        let mut joined = parser
            .parse_sector(&build_sector(&first, true))
            .expect("解析首扇区");
        joined.extend_from_slice(
            &parser
                .parse_sector(&build_sector(&second, false))
                .expect("解析次扇区"),
        );

        let mut expected = first;
        expected.extend_from_slice(&second);
        assert_eq!(joined, expected);
        assert_eq!(parser.flush(), None);
    }

    #[test]
    fn multiple_frames_in_one_sector_do_not_drop_bytes() {
        let payload_a = vec![0xAAu8; 8];
        let payload_b = vec![0x55u8; 7];

        let mut sector = vec![0u8; SECTOR_SIZE];
        sector[0] = sector_header(2, 2);
        let info_a = packet_info(true, DATA_TYPE_AUDIO, payload_a.len() as u16);
        let info_b = packet_info(true, DATA_TYPE_AUDIO, payload_b.len() as u16);
        sector[1] = info_a[0];
        sector[2] = info_a[1];
        sector[3] = info_b[0];
        sector[4] = info_b[1];

        let payload_start = 5 + 2 * 3;
        let second_start = payload_start + payload_a.len();
        sector[payload_start..second_start].copy_from_slice(&payload_a);
        sector[second_start..second_start + payload_b.len()].copy_from_slice(&payload_b);

        let mut parser = AudioSectorParser::new();
        let first = parser.parse_sector(&sector).expect("解析多帧扇区");
        let second = parser.flush().expect("剩余的第二个帧");

        assert_eq!(first, payload_a);
        assert_eq!(second, payload_b);
        assert_eq!(parser.total_bytes(), (payload_a.len() + payload_b.len()) as u64);
    }

    #[test]
    fn non_audio_packets_are_skipped() {
        let payload = vec![0x3Cu8; 128];
        let mut sector = vec![0u8; SECTOR_SIZE];
        sector[0] = sector_header(0, 2);
        let supplementary = packet_info(false, 3, 16);
        let audio = packet_info(true, DATA_TYPE_AUDIO, payload.len() as u16);
        sector[1] = supplementary[0];
        sector[2] = supplementary[1];
        sector[3] = audio[0];
        sector[4] = audio[1];
        let padding_start = 5;
        let audio_start = padding_start + 16;
        sector[audio_start..audio_start + payload.len()].copy_from_slice(&payload);

        let mut parser = AudioSectorParser::new();
        let audio = parser.parse_sector(&sector).expect("跳过非音频包");
        assert_eq!(audio, payload);
    }

    #[test]
    fn dst_sector_returns_unsupported() {
        let mut sector = build_sector(&[0x11u8; 16], true);
        sector[0] |= 0x01;

        let mut parser = AudioSectorParser::new();
        assert!(matches!(
            parser.parse_sector(&sector),
            Err(SacdError::Unsupported)
        ));
    }

    #[test]
    fn truncated_sector_returns_invalid_data() {
        let mut parser = AudioSectorParser::new();
        assert!(matches!(
            parser.parse_sector(&[0u8; 32]),
            Err(SacdError::InvalidData(_))
        ));
    }

    #[test]
    fn packet_beyond_sector_returns_invalid_data() {
        let mut sector = vec![0u8; SECTOR_SIZE];
        sector[0] = sector_header(0, 1);
        let info = packet_info(false, DATA_TYPE_AUDIO, 2046);
        sector[1] = info[0];
        sector[2] = info[1];

        let mut parser = AudioSectorParser::new();
        assert!(matches!(
            parser.parse_sector(&sector),
            Err(SacdError::InvalidData(_))
        ));
    }
}
