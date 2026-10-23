//! SACD 音频扇区解析。
//!
//! 音频扇区由扇区头、数据包信息表、帧信息表与若干数据包组成。本模块交付
//! 裸 DSD（3-in-14 / 3-in-16）负载；DST 压缩扇区按帧拼接压缩数据，交给
//! [`DstFrameDecoder`] 解码为相同排列的 DSD 字节。补充数据包与填充数据包
//! 跳过。

use super::types::SacdError;
use dst_decoder::decoder::DstDecoder;
use flutter_rust_bridge::frb;

/// 音频扇区固定长度（字节）。
const AUDIO_SECTOR_SIZE: usize = 2048;

/// 数据包类型：音频数据。
const DATA_TYPE_AUDIO: u8 = 2;

/// 单帧 DST 压缩数据的上限，与参考实现的最大帧缓冲区一致。
const MAX_DST_FRAME_BYTES: usize = 64 * 1024;

/// dst-decoder 支持的声道数上限。
const MAX_DST_CHANNELS: u8 = 6;

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

/// DST 帧解码器封装。
///
/// 把一帧 DST 压缩数据解码为按通道逐字节交织、MSB-first 的 DSD 数据，
/// 与裸 DSD 路径的输出排列一致。解码缓冲在构造时按帧长分配一次，后续帧
/// 复用同一缓冲。
struct DstFrameDecoder {
    /// 第三方 DST 解码器。
    decoder: DstDecoder,
    /// 单帧解码输出缓冲。
    scratch: Vec<u8>,
}

impl DstFrameDecoder {
    /// 按声道数与采样率创建解码器。
    ///
    /// `channel_count` 只接受 1..=6，`sample_rate` 只接受 dst-decoder 支持的
    /// DSD64 / DSD128 / DSD256 频率。
    fn new(channel_count: u8, sample_rate: u32) -> Result<Self, SacdError> {
        if channel_count == 0 || channel_count > MAX_DST_CHANNELS {
            return Err(SacdError::invalid(format!(
                "DST 解码声道数 {channel_count} 不在 1..={MAX_DST_CHANNELS} 范围内"
            )));
        }
        let decoder = DstDecoder::new(usize::from(channel_count), sample_rate as usize)
            .map_err(|error| {
                SacdError::invalid(format!(
                    "创建 DST 解码器失败: channels={channel_count}, sample_rate={sample_rate}: {error}"
                ))
            })?;
        let scratch = vec![0u8; decoder.dsd_frame_bytes()];
        Ok(Self { decoder, scratch })
    }

    /// 解码一帧 DST 压缩数据，返回交织后的 DSD 字节。
    ///
    /// `context` 用于错误消息定位（帧号与 LSN）。解码失败与解码器内部 panic
    /// 都转换为 [`SacdError::InvalidData`]，不会让 panic 穿透到调用方。
    fn decode<'a>(&'a mut self, frame: &[u8], context: &str) -> Result<&'a [u8], SacdError> {
        if frame.is_empty() {
            let message = format!("{context}: DST 帧数据为空");
            log::warn!("{message}");
            return Err(SacdError::invalid(message));
        }

        let decoder = &mut self.decoder;
        let scratch = &mut self.scratch;
        let scratch_len = scratch.len();
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            decoder.decode_frame(frame, scratch)
        }));

        let written = match result {
            Ok(Ok(written)) => written,
            Ok(Err(error)) => {
                let message =
                    format!("{context}: DST 解码失败（{} 字节）: {error:#}", frame.len());
                log::warn!("{message}");
                return Err(SacdError::invalid(message));
            }
            Err(payload) => {
                let message = format!(
                    "{context}: DST 解码触发内部 panic（{} 字节）: {}",
                    frame.len(),
                    panic_payload_message(payload.as_ref())
                );
                log::warn!("{message}");
                return Err(SacdError::invalid(message));
            }
        };

        if written == 0 || written > scratch_len {
            let message = format!(
                "{context}: DST 解码输出长度 {written} 不在 1..={scratch_len} 范围内"
            );
            log::warn!("{message}");
            return Err(SacdError::invalid(message));
        }
        Ok(&self.scratch[..written])
    }
}

/// 提取 panic 负载中的可读消息。
fn panic_payload_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        return (*message).to_owned();
    }
    if let Some(message) = payload.downcast_ref::<String>() {
        return message.clone();
    }
    "未知 panic 负载".to_owned()
}

/// DST 轨道解析状态。
///
/// 保存当前帧的压缩数据、帧序号与扇区计数。一个 DST 帧可以跨多个扇区，
/// 帧边界由数据包的 `frame_start` 标志给出，帧信息表的扇区计数用于校验。
struct DstState {
    /// 帧解码器。
    frame_decoder: DstFrameDecoder,
    /// 当前帧的压缩数据。
    frame_data: Vec<u8>,
    /// 帧信息表声明的音频包数量。
    expected_packets: u32,
    /// 当前帧已累积的音频包数量。
    packet_count: u32,
    /// 当前帧序号，从 0 开始。
    frame_index: u64,
    /// 当前帧起始扇区的逻辑扇区号。
    frame_start_lsn: u32,
    /// 下一个待解析扇区的逻辑扇区号。
    next_lsn: u32,
    /// 当前是否有帧正在累积。
    frame_active: bool,
}

impl DstState {
    /// 创建 DST 解析状态；`start_lsn` 是轨道首扇区的逻辑扇区号。
    fn new(channel_count: u8, sample_rate: u32, start_lsn: u32) -> Result<Self, SacdError> {
        Ok(Self {
            frame_decoder: DstFrameDecoder::new(channel_count, sample_rate)?,
            frame_data: Vec::with_capacity(MAX_DST_FRAME_BYTES),
            expected_packets: 0,
            packet_count: 0,
            frame_index: 0,
            frame_start_lsn: start_lsn,
            next_lsn: start_lsn,
            frame_active: false,
        })
    }

    /// 开始累积一个新帧。
    fn begin_frame(&mut self, sector_count: u8, lsn: u32) {
        self.frame_data.clear();
        self.expected_packets = u32::from(sector_count);
        self.packet_count = 0;
        self.frame_start_lsn = lsn;
        self.frame_active = true;
    }

    /// 追加一个音频数据包。
    fn push_packet(&mut self, data: &[u8]) -> Result<(), SacdError> {
        let next_len = self
            .frame_data
            .len()
            .checked_add(data.len())
            .ok_or_else(|| SacdError::invalid("DST 帧长度溢出"))?;
        if next_len > MAX_DST_FRAME_BYTES {
            return Err(SacdError::invalid(format!(
                "DST 帧 {}（起始 LSN {}）压缩数据 {next_len} 字节超过上限 {MAX_DST_FRAME_BYTES}",
                self.frame_index, self.frame_start_lsn
            )));
        }
        self.frame_data.extend_from_slice(data);
        self.packet_count = self.packet_count.saturating_add(1);
        Ok(())
    }

    /// 解码当前帧并追加到 `output`；没有活动帧时不做任何事。
    fn finish_frame(&mut self, lsn: u32, output: &mut Vec<u8>) -> Result<(), SacdError> {
        if !self.frame_active || self.frame_data.is_empty() {
            self.frame_active = false;
            return Ok(());
        }

        if self.expected_packets > 0 && self.packet_count != self.expected_packets {
            log::warn!(
                "DST 帧 {}（起始 LSN {}，结束 LSN {}）包含 {} 个音频包，帧信息声明 {} 个",
                self.frame_index,
                self.frame_start_lsn,
                lsn,
                self.packet_count,
                self.expected_packets
            );
        }

        let context = format!(
            "DST 帧 {}（起始 LSN {}，结束 LSN {}，{} 个音频包）",
            self.frame_index, self.frame_start_lsn, lsn, self.packet_count
        );
        let decoded_len = {
            let decoded = self.frame_decoder.decode(&self.frame_data, &context)?;
            output.extend_from_slice(decoded);
            decoded.len()
        };
        log::debug!("{context} 解码完成: {decoded_len} 字节 DSD");

        self.frame_data.clear();
        self.packet_count = 0;
        self.expected_packets = 0;
        self.frame_active = false;
        self.frame_index = self.frame_index.saturating_add(1);
        Ok(())
    }
}

/// 音频扇区解析器。
///
/// 维护跨扇区的音频缓冲；每次 [`parse_sector`](Self::parse_sector) 返回当前
/// 可交付的连续字节，剩余数据留待下一次调用或 [`flush`](Self::flush)。返回的
/// 字节保持原始字节交织顺序（MSB-first），由 DSF 写入器完成反位与分块。
#[derive(Default)]
#[frb(ignore)]
pub(crate) struct AudioSectorParser {
    /// 当前帧是否已经开始。
    frame_started: bool,
    /// 跨扇区累积的 DSD 音频数据。
    frame_buffer: Vec<u8>,
    /// 累计交付的音频字节数。
    total_bytes: u64,
    /// DST 解码状态；裸 DSD 轨道为 `None`。
    dst: Option<DstState>,
}

impl AudioSectorParser {
    /// 创建裸 DSD 解析器。
    pub(crate) fn new() -> Self {
        Self::default()
    }

    /// 创建 DST 解析器。
    ///
    /// `start_lsn` 是轨道首扇区的逻辑扇区号，用于错误日志定位。
    pub(crate) fn new_dst(
        channel_count: u8,
        sample_rate: u32,
        start_lsn: u32,
    ) -> Result<Self, SacdError> {
        Ok(Self {
            dst: Some(DstState::new(channel_count, sample_rate, start_lsn)?),
            ..Self::default()
        })
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
            let output = match self.dst.as_mut() {
                Some(state) => parse_dst_sector(state, sector, header)?,
                None => return Err(SacdError::Unsupported),
            };
            self.total_bytes = self.total_bytes.saturating_add(output.len() as u64);
            return Ok(output);
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
    ///
    /// DST 轨道会在这一步解码最后一个未交付的帧，解码失败返回
    /// [`SacdError::InvalidData`]。
    pub(crate) fn flush(&mut self) -> Result<Option<Vec<u8>>, SacdError> {
        self.frame_started = false;

        if let Some(state) = self.dst.as_mut() {
            let lsn = state.next_lsn;
            let mut output = Vec::new();
            state.finish_frame(lsn, &mut output)?;
            if !output.is_empty() {
                self.total_bytes = self.total_bytes.saturating_add(output.len() as u64);
                return Ok(Some(output));
            }
        }

        if self.frame_buffer.is_empty() {
            return Ok(None);
        }

        let data = std::mem::take(&mut self.frame_buffer);
        self.total_bytes = self.total_bytes.saturating_add(data.len() as u64);
        Ok(Some(data))
    }
}

/// 解析一个 DST 压缩音频扇区，返回本扇区可交付的解码后 DSD 字节。
///
/// 帧边界由音频数据包的 `frame_start` 标志给出：遇到新帧起点时先解码上一
/// 帧。帧信息表的扇区计数用于校验帧包含的音频包数量，不匹配只记录警告，
/// 最终完整性由 DST 解码器校验。
fn parse_dst_sector(
    state: &mut DstState,
    sector: &[u8],
    header: AudioFrameHeader,
) -> Result<Vec<u8>, SacdError> {
    let lsn = state.next_lsn;
    let mut offset = 1usize;

    let mut packets = Vec::with_capacity(usize::from(header.packet_info_count));
    for _ in 0..header.packet_info_count {
        let bytes = slice_at(sector, offset, 2)?;
        packets.push(AudioPacketInfo::from_bytes(bytes)?);
        offset = offset
            .checked_add(2)
            .ok_or_else(|| SacdError::invalid("音频扇区偏移溢出"))?;
    }

    // DST 的帧信息固定 4 字节，第 4 字节包含剩余扇区数与声道提示位。
    let mut frame_sectors = Vec::with_capacity(usize::from(header.frame_info_count));
    for _ in 0..header.frame_info_count {
        let bytes = slice_at(sector, offset, 4)?;
        let frame_info = AudioFrameInfo::from_bytes(bytes, true)?;
        frame_sectors.push(frame_info.sector_count);
        offset = offset
            .checked_add(4)
            .ok_or_else(|| SacdError::invalid("音频扇区偏移溢出"))?;
    }

    let mut output: Vec<u8> = Vec::new();
    let mut frame_info_index = 0usize;
    for packet in packets {
        let packet_length = usize::from(packet.packet_length);
        let packet_data = slice_at(sector, offset, packet_length)?;
        offset = offset
            .checked_add(packet_length)
            .ok_or_else(|| SacdError::invalid("音频扇区偏移溢出"))?;

        if packet.data_type != DATA_TYPE_AUDIO {
            continue;
        }

        if packet.frame_start {
            state.finish_frame(lsn, &mut output)?;
            let sector_count = frame_sectors.get(frame_info_index).copied().ok_or_else(|| {
                SacdError::invalid(format!(
                    "LSN {lsn} 的 DST 帧起点缺少对应帧信息（已有 {} 条）",
                    frame_sectors.len()
                ))
            })?;
            frame_info_index = frame_info_index.saturating_add(1);
            state.begin_frame(sector_count, lsn);
        }

        if !state.frame_active {
            log::warn!(
                "LSN {lsn} 的 DST 音频包没有帧起点，忽略 {packet_length} 字节"
            );
            continue;
        }
        state.push_packet(packet_data)?;
    }

    if frame_info_index != frame_sectors.len() {
        return Err(SacdError::invalid(format!(
            "LSN {lsn} 的 DST 帧信息 {} 条与音频帧起点 {frame_info_index} 个不一致",
            frame_sectors.len()
        )));
    }

    state.next_lsn = state.next_lsn.saturating_add(1);
    Ok(output)
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
        assert!(parser.flush().expect("刷新解析器").is_none());
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
        let second = parser
            .flush()
            .expect("刷新解析器")
            .expect("剩余的第二个帧");

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

    /// DST 测试向量：dst-decoder 仓库的 stereo frame_001。参考 DSD 输出由
    /// sacd-ripper 的 C 解码器逐字节校验。
    const DST_FIXTURE: &[u8] = include_bytes!("testdata/frame_001.dst");
    const DSD_FIXTURE: &[u8] = include_bytes!("testdata/frame_001.dsd");

    /// 构造一个只含一个 DST 音频包的最小扇区。
    fn build_dst_sector(
        payload: &[u8],
        frame_start: bool,
        sector_count: u8,
        frame_info_count: u8,
    ) -> Vec<u8> {
        let header_len = 1 + 2 + 4 * usize::from(frame_info_count);
        let end = header_len + payload.len();
        assert!(end <= SECTOR_SIZE, "测试 DST 负载超出扇区");

        let mut sector = vec![0u8; SECTOR_SIZE];
        sector[0] = 0x01 | ((frame_info_count & 0x07) << 2) | (1 << 5);
        let info = packet_info(frame_start, DATA_TYPE_AUDIO, payload.len() as u16);
        sector[1] = info[0];
        sector[2] = info[1];
        if frame_info_count > 0 {
            // 帧信息 4 字节：时间码 3 字节 + 扇区计数与声道提示位。
            sector[6] = (sector_count & 0x1F) << 2;
        }
        sector[header_len..end].copy_from_slice(payload);
        sector
    }

    #[test]
    fn dst_frame_decoder_matches_reference_fixture() {
        let mut decoder = DstFrameDecoder::new(2, 2_822_400).expect("创建 DST 帧解码器");
        let decoded = decoder.decode(DST_FIXTURE, "测试向量").expect("解码 DST 帧");

        assert_eq!(decoded.len(), DSD_FIXTURE.len());
        assert_eq!(decoded, DSD_FIXTURE);
    }

    #[test]
    fn dst_sector_assembles_frame_across_sectors() {
        let split = DST_FIXTURE.len() / 2;
        let first = build_dst_sector(&DST_FIXTURE[..split], true, 2, 1);
        let second = build_dst_sector(&DST_FIXTURE[split..], false, 0, 0);

        let mut parser = AudioSectorParser::new_dst(2, 2_822_400, 581).expect("创建 DST 解析器");
        let mut decoded = parser.parse_sector(&first).expect("解析首扇区");
        assert!(decoded.is_empty(), "帧未完整时不应交付");
        decoded.extend_from_slice(&parser.parse_sector(&second).expect("解析续扇区"));
        if let Some(rest) = parser.flush().expect("刷新 DST 解析器") {
            decoded.extend_from_slice(&rest);
        }

        assert_eq!(decoded, DSD_FIXTURE);
        assert_eq!(parser.total_bytes(), DSD_FIXTURE.len() as u64);
    }

    #[test]
    fn dst_frame_start_without_frame_info_returns_invalid_data() {
        let sector = build_dst_sector(&DST_FIXTURE[..64], true, 0, 0);
        let mut parser = AudioSectorParser::new_dst(2, 2_822_400, 0).expect("创建 DST 解析器");

        assert!(matches!(
            parser.parse_sector(&sector),
            Err(SacdError::InvalidData(_))
        ));
    }

    #[test]
    fn dst_frame_info_without_frame_start_returns_invalid_data() {
        let sector = build_dst_sector(&DST_FIXTURE[..64], false, 1, 1);
        let mut parser = AudioSectorParser::new_dst(2, 2_822_400, 0).expect("创建 DST 解析器");

        assert!(matches!(
            parser.parse_sector(&sector),
            Err(SacdError::InvalidData(_))
        ));
    }

    #[test]
    fn dst_decoder_rejects_unsupported_sample_rate() {
        assert!(matches!(
            DstFrameDecoder::new(2, 48_000),
            Err(SacdError::InvalidData(_))
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
