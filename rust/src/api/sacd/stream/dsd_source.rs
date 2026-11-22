//! 直解数据源：ISO → 虚拟 DSF 字节流。
//!
//! 顺序读时按 128 扇区一批读取镜像，交给 [`AudioSectorParser`] 还原交织、
//! MSB-first 的 DSD 字节，再由 [`DsfStreamEncoder`] 完成反位与 4096 字节块
//! 交织。seek 时按帧定位：SACD 的音频帧是 1/75 秒，一帧的字节数是声道数的
//! 整数倍，因此从帧起点重新解码就能得到与从头读取一致的通道相位，误差最多
//! 一帧。

use super::super::audio::{
    AudioFrameHeader, AudioPacketInfo, AudioSectorParser, DATA_TYPE_AUDIO,
};
use super::super::dsf::{DsfStreamEncoder, DSF_BLOCK_SIZE_PER_CHANNEL};
use super::super::extract::{apply_batch_pause, SECTORS_PER_BATCH};
use super::super::reader::ImageReader;
use super::super::types::{SacdFrameFormat, SACD_LSN_SIZE};
use super::layout::{dsf_block_position, frame_bytes_per_channel, frame_count};
use super::TrackInfo;

/// 扫描帧起点时最多检查的扇区数（裸 DSD 的回退窗口），避免异常镜像让扫描无限延伸。
const MAX_FRAME_SCAN_SECTORS: u32 = 64;

/// 扫描帧起点时单次读取的扇区数。
const FRAME_SCAN_BATCH: u16 = 64;

/// DST 定位窗口的单侧上限：按时间预算折算后不允许超过该扇区数。
const MAX_DST_WINDOW_SECTORS: u32 = 2_048;

/// 顺序读取：ISO → 交织、MSB-first 的 DSD 字节流。
pub(super) struct IsoDsfReader {
    image: ImageReader,
    parser: AudioSectorParser,
    track: TrackInfo,
    /// 下一个待读取的逻辑扇区号。
    next_lsn: u32,
    /// 剩余待读取的逻辑扇区数。
    remaining_lsn: u32,
    /// 已读取的批次数，用于让出线程时间片。
    batch_index: u32,
    /// 是否已经把解析器残留交付完毕。
    finished: bool,
    /// 还需要丢弃的交织字节数（seek 落在帧内时使用）。
    skip_bytes: usize,
}

impl IsoDsfReader {
    /// 从轨道起点打开数据源。
    pub(super) fn open(track: &TrackInfo) -> Result<Self, String> {
        if track.length_lsn == 0 {
            return Err(format!(
                "SACD 轨道长度为 0: iso={}, area={}, track={}",
                track.iso_path, track.area, track.track_number
            ));
        }
        let image =
            ImageReader::open(std::path::Path::new(&track.iso_path)).map_err(|error| {
                format!(
                    "打开 SACD 镜像失败: iso={}, area={}, track={}, error={error}",
                    track.iso_path, track.area, track.track_number
                )
            })?;
        let parser = Self::build_parser(track, track.start_lsn)?;
        Ok(Self {
            image,
            parser,
            track: track.clone(),
            next_lsn: track.start_lsn,
            remaining_lsn: track.length_lsn,
            batch_index: 0,
            finished: false,
            skip_bytes: 0,
        })
    }

    /// 回到轨道起点。
    pub(super) fn restart(&mut self) -> Result<(), String> {
        self.parser = Self::build_parser(&self.track, self.track.start_lsn)?;
        self.next_lsn = self.track.start_lsn;
        self.remaining_lsn = self.track.length_lsn;
        self.batch_index = 0;
        self.finished = false;
        self.skip_bytes = 0;
        Ok(())
    }

    /// 定位到指定的每通道 DSD 字节位置。
    ///
    /// 位置按帧向下对齐：先按恒定码率估算帧号对应的 LSN，回退若干扇区后扫描
    /// 到最近的帧起点，再从该帧重新解码，并丢弃帧内多余的字节。因此实际起点
    /// 与目标最多相差一帧。
    pub(super) fn seek_to(&mut self, target_per_channel: u64) -> Result<(), String> {
        let frame_bytes = frame_bytes_per_channel(self.track.sample_rate);
        if frame_bytes == 0 {
            return self.restart();
        }
        let frame_index = target_per_channel / frame_bytes;
        let within = target_per_channel % frame_bytes;

        let frame_lsn = self.locate_frame_lsn(frame_index)?;
        self.parser = Self::build_parser(&self.track, frame_lsn)?;
        self.next_lsn = frame_lsn;
        let end_lsn = self
            .track
            .start_lsn
            .saturating_add(self.track.length_lsn);
        self.remaining_lsn = end_lsn.saturating_sub(frame_lsn);
        self.finished = false;
        self.batch_index = 0;
        self.skip_bytes = usize::try_from(within)
            .unwrap_or(usize::MAX)
            .saturating_mul(self.track.channels as usize);

        log::debug!(
            "SACD 直解定位: iso={}, area={}, track={}, 目标每通道字节={target_per_channel}, 帧={frame_index}, 帧内偏移={within}, 帧起点 LSN={frame_lsn}, 剩余扇区={}",
            self.track.iso_path,
            self.track.area,
            self.track.track_number,
            self.remaining_lsn
        );
        Ok(())
    }

    /// 取下一批交织 DSD 字节；返回 `true` 表示轨道已完全交付。
    pub(super) fn next_batch(&mut self, out: &mut Vec<u8>) -> Result<bool, String> {
        if self.finished {
            return Ok(true);
        }

        if self.remaining_lsn == 0 {
            let rest = self.parser.flush().map_err(|error| {
                format!(
                    "刷新 SACD 音频解析器失败: iso={}, area={}, track={}, error={error}",
                    self.track.iso_path, self.track.area, self.track.track_number
                )
            })?;
            if let Some(rest) = rest {
                self.push_skipping(&rest, out);
            }
            self.finished = true;
            return Ok(true);
        }

        let batch = self.remaining_lsn.min(u32::from(SECTORS_PER_BATCH)) as u16;
        let sectors = self.image.read_sectors(self.next_lsn, batch).map_err(|error| {
            format!(
                "读取 SACD 音频扇区失败: iso={}, area={}, track={}, lsn={}, count={batch}, error={error}",
                self.track.iso_path, self.track.area, self.track.track_number, self.next_lsn
            )
        })?;
        let expected = usize::from(batch)
            .checked_mul(SACD_LSN_SIZE)
            .ok_or_else(|| "SACD 音频读取长度溢出".to_string())?;
        if sectors.len() != expected {
            return Err(format!(
                "LSN {} 起的 {batch} 个音频扇区读取长度 {} 与预期 {expected} 不一致: iso={}",
                self.next_lsn,
                sectors.len(),
                self.track.iso_path
            ));
        }

        for sector in sectors.chunks_exact(SACD_LSN_SIZE) {
            let audio = self.parser.parse_sector(sector).map_err(|error| {
                format!(
                    "解析 SACD 音频扇区失败: iso={}, area={}, track={}, lsn={}, error={error}",
                    self.track.iso_path, self.track.area, self.track.track_number, self.next_lsn
                )
            })?;
            if !audio.is_empty() {
                self.push_skipping(&audio, out);
            }
        }

        self.next_lsn = self.next_lsn.saturating_add(u32::from(batch));
        self.remaining_lsn = self.remaining_lsn.saturating_sub(u32::from(batch));
        self.batch_index = self.batch_index.saturating_add(1);
        apply_batch_pause(self.batch_index);

        Ok(false)
    }

    /// 追加字节，先扣掉 seek 后需要丢弃的帧内残留。
    fn push_skipping(&mut self, data: &[u8], out: &mut Vec<u8>) {
        if self.skip_bytes == 0 {
            out.extend_from_slice(data);
            return;
        }
        if self.skip_bytes >= data.len() {
            self.skip_bytes -= data.len();
            return;
        }
        out.extend_from_slice(&data[self.skip_bytes..]);
        self.skip_bytes = 0;
    }

    fn build_parser(track: &TrackInfo, start_lsn: u32) -> Result<AudioSectorParser, String> {
        match track.frame_format {
            SacdFrameFormat::Dst => {
                let channels = u8::try_from(track.channels)
                    .map_err(|_| format!("SACD 声道数 {} 超出 u8 范围", track.channels))?;
                AudioSectorParser::new_dst(channels, track.sample_rate, start_lsn).map_err(
                    |error| {
                        format!(
                            "创建 DST 解析器失败: iso={}, channels={}, sample_rate={}, error={error}",
                            track.iso_path, track.channels, track.sample_rate
                        )
                    },
                )
            }
            SacdFrameFormat::Dsd => Ok(AudioSectorParser::new()),
        }
    }

    /// 估算帧号对应的 LSN，并按帧格式选择定位策略。
    ///
    /// 裸 DSD 的帧长固定，按平均扇区数回退后取最近帧起点即可；DST 是变码率，
    /// 平均扇区数的误差可达数秒，因此按时间预算放宽扫描窗口，并且必须找到
    /// 帧起点——从帧中间解码会让 `AudioSectorParser` 丢弃半帧数据，通道相位
    /// 从此永久错位。
    fn locate_frame_lsn(&mut self, frame_index: u64) -> Result<u32, String> {
        let start_lsn = self.track.start_lsn;
        let end_lsn = start_lsn.saturating_add(self.track.length_lsn);
        if self.track.length_lsn == 0 {
            return Ok(start_lsn);
        }

        let total_frames = frame_count(self.track.duration_ms).max(1);
        let per_frame_lsn = f64::from(self.track.length_lsn) / total_frames as f64;
        let offset = (frame_index as f64 * per_frame_lsn).round();
        let offset = if offset.is_finite() && offset >= 0.0 {
            offset.min(f64::from(u32::MAX)) as u32
        } else {
            0
        };
        let last_lsn = end_lsn.saturating_sub(1);
        let estimated = start_lsn.saturating_add(offset).min(last_lsn);

        let frame_bytes = frame_bytes_per_channel(self.track.sample_rate)
            .saturating_mul(u64::from(self.track.channels));
        let frame_sectors = frame_bytes.div_ceil(SACD_LSN_SIZE as u64).max(1) as u32;

        match self.track.frame_format {
            SacdFrameFormat::Dst => {
                let window = self.dst_window_sectors();
                let probe = estimated.saturating_sub(window).max(start_lsn);
                let scan_end = estimated
                    .saturating_add(window)
                    .saturating_add(frame_sectors)
                    .min(end_lsn);
                let candidates = self.scan_frame_starts(probe, scan_end)?;
                if candidates.is_empty() {
                    return Err(format!(
                        "无法在 LSN {probe}..{scan_end} 内定位 DST 帧起点: iso={}, area={}, track={}, 帧={frame_index}, 估算 LSN={estimated}",
                        self.track.iso_path, self.track.area, self.track.track_number
                    ));
                }
                let chosen = candidates
                    .iter()
                    .copied()
                    .min_by_key(|lsn| lsn.abs_diff(estimated))
                    .unwrap_or(estimated);
                log::debug!(
                    "DST 帧定位: 帧={frame_index}, 估算 LSN={estimated}, 窗口={probe}..{scan_end}, 选中 LSN={chosen}, 候选={}",
                    candidates.len()
                );
                Ok(chosen)
            }
            SacdFrameFormat::Dsd => {
                let back_off = frame_sectors.saturating_add(2);
                let probe = estimated
                    .saturating_sub(back_off)
                    .max(start_lsn)
                    .min(last_lsn);
                let scan_end = estimated
                    .saturating_add(frame_sectors)
                    .saturating_add(2)
                    .min(end_lsn)
                    .min(probe.saturating_add(MAX_FRAME_SCAN_SECTORS))
                    .max(probe.saturating_add(1));
                let candidates = match self.scan_frame_starts(probe, scan_end) {
                    Ok(list) => list,
                    Err(error) => {
                        log::warn!(
                            "裸 DSD 帧起点扫描失败，退化为从 LSN {probe} 直接解码: iso={}, error={error}",
                            self.track.iso_path
                        );
                        Vec::new()
                    }
                };
                if candidates.is_empty() {
                    log::warn!(
                        "裸 DSD 轨道在 LSN {probe}..{scan_end} 内未找到帧起点，退化为从该位置直接解码: iso={}, area={}, track={}",
                        self.track.iso_path, self.track.area, self.track.track_number
                    );
                    return Ok(probe);
                }
                Ok(candidates
                    .iter()
                    .copied()
                    .min_by_key(|lsn| lsn.abs_diff(estimated))
                    .unwrap_or(probe))
            }
        }
    }

    /// DST 定位窗口：按轨道平均码率折算约 ±3 秒的扇区数，限制在 64..=2048。
    fn dst_window_sectors(&self) -> u32 {
        let seconds = (self.track.duration_ms as f64 / 1_000.0).max(1.0);
        let sectors_per_second = f64::from(self.track.length_lsn) / seconds;
        let window = (sectors_per_second * 3.0).round();
        let window = if window.is_finite() && window > 0.0 {
            window.min(f64::from(u32::MAX)) as u32
        } else {
            64
        };
        window.max(64).min(MAX_DST_WINDOW_SECTORS)
    }

    /// 在 `from_lsn..to_lsn` 范围内收集带 `frame_start` 音频包的扇区号。
    ///
    /// 一次读取 [`FRAME_SCAN_BATCH`] 个扇区再逐扇区检查，降低拖动时的读盘次数。
    /// 读取失败直接返回错误，由调用方决定是否退化。
    fn scan_frame_starts(&mut self, from_lsn: u32, to_lsn: u32) -> Result<Vec<u32>, String> {
        let mut found = Vec::new();
        let mut lsn = from_lsn;
        while lsn < to_lsn {
            let count = (to_lsn - lsn).min(u32::from(FRAME_SCAN_BATCH)) as u16;
            if count == 0 {
                break;
            }
            let sectors = self.image.read_sectors(lsn, count).map_err(|error| {
                format!(
                    "扫描 SACD 帧起点读取失败: iso={}, lsn={lsn}, count={count}, error={error}",
                    self.track.iso_path
                )
            })?;
            let expected = usize::from(count)
                .checked_mul(SACD_LSN_SIZE)
                .ok_or_else(|| "扫描 SACD 帧起点长度溢出".to_string())?;
            if sectors.len() != expected {
                return Err(format!(
                    "扫描 SACD 帧起点读取长度 {} 与预期 {expected} 不一致: iso={}, lsn={lsn}, count={count}",
                    sectors.len(),
                    self.track.iso_path
                ));
            }
            for (index, sector) in sectors.chunks_exact(SACD_LSN_SIZE).enumerate() {
                if sector_has_frame_start(sector) {
                    found.push(lsn.saturating_add(index as u32));
                }
            }
            lsn = lsn.saturating_add(u32::from(count));
        }
        Ok(found)
    }
}

/// 判断一个音频扇区是否包含带帧起点标志的音频包。
pub(super) fn sector_has_frame_start(sector: &[u8]) -> bool {
    let first = match sector.first() {
        Some(first) => *first,
        None => return false,
    };
    let header = AudioFrameHeader::from_byte(first);
    let mut offset = 1usize;
    for _ in 0..header.packet_info_count {
        let end = offset.saturating_add(2);
        let bytes = match sector.get(offset..end) {
            Some(bytes) => bytes,
            None => return false,
        };
        let info = match AudioPacketInfo::from_bytes(bytes) {
            Ok(info) => info,
            Err(_) => return false,
        };
        if info.frame_start && info.data_type == DATA_TYPE_AUDIO {
            return true;
        }
        offset = end;
    }
    false
}

/// 直解数据源：交付虚拟 DSF 的完整字节流（92 字节头 + 编码后的 data）。
pub(super) struct DsdSource {
    feed: IsoDsfReader,
    encoder: DsfStreamEncoder,
    header: [u8; 92],
    header_len: u64,
    length: u64,
    position: u64,
    /// 已编码、尚未交付的字节。
    pending: Vec<u8>,
    pending_pos: usize,
    /// 复用给 `next_batch` 的 DSD 缓冲。
    dsd_scratch: Vec<u8>,
    /// 复用给编码器的输出缓冲。
    encode_scratch: Vec<u8>,
    /// seek 落在块内时需要丢弃的字节数。
    skip_block_bytes: usize,
    /// 数据源已完全解码。
    feed_done: bool,
    channels: usize,
}

impl DsdSource {
    /// 按轨道元数据和虚拟 data 长度构造直解数据源。
    pub(super) fn create(track: &TrackInfo, data_bytes: u64) -> Result<Self, String> {
        if track.channels == 0 {
            return Err(format!("SACD 声道数不能为 0: track={}", track.track_number));
        }
        let channels = track.channels as usize;
        // fmt chunk 的每通道样本数用有效字节（不含块补齐的静音），与
        // `extract_track_to_dsf` 的产物一致；data chunk 长度仍按块对齐。
        let valid_per_channel = super::layout::dsf_valid_bytes_per_channel(
            track.duration_ms,
            track.sample_rate,
        );
        let sample_count = valid_per_channel.saturating_mul(8);
        let header = super::layout::dsf_header(
            track.channels,
            track.sample_rate,
            sample_count,
            data_bytes,
        );
        let feed = IsoDsfReader::open(track)?;
        Ok(Self {
            feed,
            encoder: DsfStreamEncoder::new(channels),
            header,
            header_len: super::layout::DSF_HEADER_LEN,
            length: super::layout::DSF_HEADER_LEN.saturating_add(data_bytes),
            position: 0,
            pending: Vec::new(),
            pending_pos: 0,
            dsd_scratch: Vec::new(),
            encode_scratch: Vec::new(),
            skip_block_bytes: 0,
            feed_done: false,
            channels,
        })
    }

    /// 虚拟文件总字节数。
    pub(super) fn length(&self) -> u64 {
        self.length
    }

    /// 虚拟文件头长度。
    pub(super) fn header_len(&self) -> u64 {
        self.header_len
    }

    /// 从绝对偏移重新定位。
    pub(super) fn seek(&mut self, offset: u64) -> Result<(), String> {
        self.pending.clear();
        self.pending_pos = 0;
        self.skip_block_bytes = 0;
        self.feed_done = false;

        if offset < self.header_len {
            self.feed.restart()?;
            self.encoder = DsfStreamEncoder::new(self.channels);
            self.position = offset;
            return Ok(());
        }

        let data_offset = offset - self.header_len;
        let (block, within) = dsf_block_position(data_offset, self.channels as u32);
        let target = block.saturating_mul(DSF_BLOCK_SIZE_PER_CHANNEL as u64);
        self.feed.seek_to(target)?;
        self.encoder = DsfStreamEncoder::new(self.channels);
        self.skip_block_bytes = usize::try_from(within).unwrap_or(usize::MAX);
        self.position = offset;

        log::debug!(
            "SACD 直解 seek: 目标偏移={offset}, 块={block}, 块内偏移={within}, 每通道目标字节={target}, 通道数={}",
            self.channels
        );
        Ok(())
    }

    /// 产出至多 `max_bytes` 字节，返回是否已到真实结尾。
    pub(super) fn produce(
        &mut self,
        max_bytes: usize,
        out: &mut Vec<u8>,
    ) -> Result<bool, String> {
        if max_bytes == 0 {
            return Ok(self.feed_done);
        }

        if self.position < self.header_len {
            let start = self.position as usize;
            let available = (self.header_len - self.position) as usize;
            let take = available.min(max_bytes);
            let bytes = self
                .header
                .get(start..start.saturating_add(take))
                .ok_or_else(|| format!("虚拟 DSF 头偏移 {start} 越界"))?;
            out.extend_from_slice(bytes);
            self.position = self.position.saturating_add(take as u64);
            return Ok(false);
        }

        if self.pending_pos < self.pending.len() {
            let available = self.pending.len() - self.pending_pos;
            let take = available.min(max_bytes);
            out.extend_from_slice(&self.pending[self.pending_pos..self.pending_pos + take]);
            self.pending_pos += take;
            if self.pending_pos >= self.pending.len() {
                self.pending.clear();
                self.pending_pos = 0;
            }
            self.position = self.position.saturating_add(take as u64);
            return Ok(false);
        }

        if self.feed_done {
            return Ok(true);
        }

        let mut dsd = std::mem::take(&mut self.dsd_scratch);
        dsd.clear();
        let eof = self.feed.next_batch(&mut dsd)?;
        self.pending.clear();
        self.pending_pos = 0;
        let mut encoded = std::mem::take(&mut self.encode_scratch);
        encoded.clear();
        self.encoder.push(&dsd, &mut encoded);
        if eof {
            self.encoder.finish(&mut encoded);
            self.feed_done = true;
        }
        self.dsd_scratch = dsd;
        self.append_encoded(&encoded);
        self.encode_scratch = encoded;

        Ok(self.feed_done && self.pending.is_empty())
    }

    /// 追加编码后的字节，先扣掉 seek 落在块内时需要丢弃的字节。
    fn append_encoded(&mut self, encoded: &[u8]) {
        if self.skip_block_bytes == 0 {
            self.pending.extend_from_slice(encoded);
            return;
        }
        if self.skip_block_bytes >= encoded.len() {
            self.skip_block_bytes -= encoded.len();
            return;
        }
        self.pending
            .extend_from_slice(&encoded[self.skip_block_bytes..]);
        self.skip_block_bytes = 0;
    }
}
