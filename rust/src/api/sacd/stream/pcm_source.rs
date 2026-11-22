//! 实时 PCM 数据源：ISO → 虚拟 WAV 字节流。
//!
//! 与直解共用 [`IsoDsfReader`] 的读取与帧定位逻辑，区别是解码出的交织 DSD
//! 字节直接送 [`StreamingPcm`] 转成 PCM，而非编码成 DSF。seek 后必须重置
//! 转换器并丢弃 0.2 秒预滚，避免滤波器起始瞬态被听到。

use flutter_rust_bridge::frb;

use rdsd2pcm::{DitherType, FilterType, StreamingPcm};

use super::dsd_source::IsoDsfReader;
use super::layout::{
    preroll_dsd_bytes, preroll_pcm_frames, pcm_offset_to_dsd_bytes, wav_data_bytes, wav_header,
    WAV_HEADER_LEN,
};
use super::TrackInfo;

/// 预滚时长对应的 DSD 字节在 seek 时从目标位置向前多解，保证丢弃预滚后正好
/// 落在目标附近。
#[frb(ignore)]
pub(super) struct PcmSource {
    feed: IsoDsfReader,
    converter: StreamingPcm,
    header: [u8; 44],
    header_len: u64,
    length: u64,
    position: u64,
    pending: Vec<u8>,
    pending_pos: usize,
    dsd_scratch: Vec<u8>,
    /// seek 后需要丢弃的 PCM 输出字节（预滚帧与帧内偏移之和）。
    skip_pcm_bytes: usize,
    feed_done: bool,
    channels: u32,
    out_rate: u32,
    bit_depth: u16,
    dsd_rate: u32,
    bytes_per_sample: u16,
}

impl PcmSource {
    /// 按轨道元数据与输出参数构造实时 PCM 数据源。
    pub(super) fn create(
        track: &TrackInfo,
        out_rate: u32,
        bit_depth: u16,
    ) -> Result<Self, String> {
        if track.channels == 0 {
            return Err(format!("SACD 声道数不能为 0: track={}", track.track_number));
        }
        let bytes_per_sample = bit_depth / 8;
        if bytes_per_sample == 0 {
            return Err(format!("不支持的 PCM 位深 {bit_depth}"));
        }

        // WAV 的 RIFF 与 data 长度字段是 32 位；超限时按上限截断，保证虚拟
        // 头声明的长度与 length 回调一致。
        let data_bytes = wav_data_bytes(track.duration_ms, out_rate, track.channels, bit_depth)
            .min(u64::from(u32::MAX) - 36);
        let header = wav_header(track.channels, out_rate, bit_depth, data_bytes);
        let converter = StreamingPcm::new(
            track.channels as usize,
            track.sample_rate,
            bit_depth as usize,
            out_rate,
            DitherType::TPDF,
            FilterType::Equiripple,
        )
        .map_err(|error| {
            format!(
                "创建实时 PCM 转换器失败: iso={}, channels={}, dsd_rate={}, out_rate={out_rate}, bits={bit_depth}, error={error}",
                track.iso_path, track.channels, track.sample_rate
            )
        })?;
        let feed = IsoDsfReader::open(track)?;

        Ok(Self {
            feed,
            converter,
            header,
            header_len: WAV_HEADER_LEN,
            length: WAV_HEADER_LEN.saturating_add(data_bytes),
            position: 0,
            pending: Vec::new(),
            pending_pos: 0,
            dsd_scratch: Vec::new(),
            skip_pcm_bytes: 0,
            feed_done: false,
            channels: track.channels,
            out_rate,
            bit_depth,
            dsd_rate: track.sample_rate,
            bytes_per_sample,
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
    ///
    /// 目标偏移先换算成每通道 DSD 字节位置，再向前多解 0.2 秒用于滤波器预热；
    /// 这段预热与帧内偏移都会在 PCM 输出上丢弃，使交付首字节对应目标偏移。
    pub(super) fn seek(&mut self, offset: u64) -> Result<(), String> {
        self.pending.clear();
        self.pending_pos = 0;
        self.skip_pcm_bytes = 0;
        self.feed_done = false;

        if offset < self.header_len {
            self.feed.restart()?;
            self.converter.reset();
            self.position = offset;
            return Ok(());
        }

        let data_offset = offset - self.header_len;
        let frame_stride = u64::from(self.channels).saturating_mul(u64::from(self.bytes_per_sample));
        let within = if frame_stride == 0 {
            0
        } else {
            data_offset % frame_stride
        };
        let target_dsd = pcm_offset_to_dsd_bytes(
            data_offset,
            self.channels,
            self.bytes_per_sample,
            self.dsd_rate,
            self.out_rate,
        );
        let preroll_dsd = preroll_dsd_bytes(self.dsd_rate);
        let start_dsd = target_dsd.saturating_sub(preroll_dsd);

        self.feed.seek_to(start_dsd)?;
        self.converter.reset();
        let preroll_frames = preroll_pcm_frames(self.out_rate);
        let preroll_bytes = preroll_frames
            .saturating_mul(u64::from(self.channels))
            .saturating_mul(u64::from(self.bytes_per_sample));
        self.skip_pcm_bytes = usize::try_from(preroll_bytes.saturating_add(within))
            .unwrap_or(usize::MAX);
        self.position = offset;

        log::debug!(
            "SACD 实时 PCM seek: 目标偏移={offset}, 数据偏移={data_offset}, 帧内偏移={within}, 目标 DSD 字节={target_dsd}, 解码起点 DSD 字节={start_dsd}, 丢弃 PCM 字节={}",
            self.skip_pcm_bytes
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
                .ok_or_else(|| format!("虚拟 WAV 头偏移 {start} 越界"))?;
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
        let mut pcm = self.converter.push(&dsd)?;
        if eof {
            let mut tail = self.converter.flush()?;
            pcm.append(&mut tail);
            self.feed_done = true;
        }
        self.dsd_scratch = dsd;
        if !pcm.is_empty() {
            self.append_skipping(&pcm);
        }

        Ok(self.feed_done && self.pending.is_empty())
    }

    /// 追加 PCM 字节，先扣掉 seek 后需要丢弃的预滚与帧内偏移。
    fn append_skipping(&mut self, data: &[u8]) {
        if self.skip_pcm_bytes == 0 {
            self.pending.extend_from_slice(data);
            return;
        }
        if self.skip_pcm_bytes >= data.len() {
            self.skip_pcm_bytes -= data.len();
            return;
        }
        self.pending.extend_from_slice(&data[self.skip_pcm_bytes..]);
        self.skip_pcm_bytes = 0;
    }
}
