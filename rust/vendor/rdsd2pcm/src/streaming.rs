/*
 Copyright (c) 2023 clone206

 This file is part of rdsd2pcm

 rdsd2pcm is free software: you can redistribute it and/or modify it
 under the terms of the GNU General Public License as published by the
 Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 rdsd2pcm is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with rdsd2pcm. If not, see <https://www.gnu.org/licenses/>.
*/

//! Streaming DSD to PCM conversion.
//!
//! Reuses the same filters, resamplers and quantizer as the whole-file
//! converter ([`crate::Rdsd2Pcm`]) but reads DSD bytes from memory and
//! writes PCM bytes to memory, so nothing touches the file system.
//!
//! Input layout matches what the SACD sector parser hands out: interleaved by
//! sample, MSB-first (bit 7 is the earliest sample of each byte). Blocks are
//! converted to the LSB-first order a DSF container carries before they reach
//! the filters, mirroring `write_channel_dsf` in the host crate.

use dsd_reader::DSD_64_RATE;
use log::{debug, warn};

use crate::byte_precalc_decimator::{select_precalc_taps, BytePrecalcDecimator};
use crate::dither::Dither;
use crate::lm_resampler::{compute_decim_and_upsample, LMResampler};
use crate::pcm_writer::PcmWriter;
use crate::{DitherType, FilterType};

/// Per-channel DSD bytes handled per conversion step, matching the DSF
/// block size the file converter uses.
const DSD_BLOCK_BYTES: usize = 4096;

/// Output sample rates this library can produce from a DSD64 stream.
const SUPPORTED_OUT_RATES: [u32; 5] = [44_100, 48_000, 88_200, 96_000, 192_000];

/// Output bit depths this library can produce as integer PCM.
const SUPPORTED_OUT_BITS: [usize; 2] = [16, 24];

/// Upper bound on channel count, matching the DST decoder limit.
const MAX_CHANNELS: usize = 6;

/// Incremental DSD to PCM converter that keeps no file handles.
pub struct StreamingPcm {
    channels: usize,
    /// DSD rate multiplier relative to DSD64 (1, 2, 4, 8).
    dsd_mult: i32,
    out_bits: usize,
    out_rate: u32,
    dither: DitherType,
    filter: FilterType,
    decim_ratio: i32,
    upsample_ratio: u32,
    out_capacity: usize,
    writer: PcmWriter,
    /// Rational resampler per channel, used when `upsample_ratio > 1`.
    lm: Option<Vec<LMResampler>>,
    /// Integer decimator per channel, used when `upsample_ratio == 1`.
    precalc: Option<Vec<BytePrecalcDecimator>>,
    /// Per-channel input accumulator (LSB-first bytes).
    channel_buffers: Vec<Vec<u8>>,
    /// Rotating channel index for the next input byte.
    channel_pos: usize,
}

impl StreamingPcm {
    /// Create a converter.
    ///
    /// * `channels` - 1..=6 input channels.
    /// * `dsd_rate` - DSD sample rate in Hz (2822400 for DSD64, and so on).
    /// * `out_bits` - 16 or 24.
    /// * `out_rate` - 44100, 48000, 88200, 96000 or 192000.
    /// * `dither` - Dither type, applied the same way as the file converter.
    /// * `filter` - Decimation filter type.
    pub fn new(
        channels: usize,
        dsd_rate: u32,
        out_bits: usize,
        out_rate: u32,
        dither: DitherType,
        filter: FilterType,
    ) -> Result<Self, String> {
        if channels == 0 || channels > MAX_CHANNELS {
            return Err(format!(
                "DSD 声道数 {channels} 不在 1..={MAX_CHANNELS} 范围内"
            ));
        }
        if dsd_rate == 0 || dsd_rate % DSD_64_RATE != 0 {
            return Err(format!(
                "DSD 采样率 {dsd_rate} 不是 DSD64 基频 {DSD_64_RATE} 的整数倍"
            ));
        }
        let dsd_mult = (dsd_rate / DSD_64_RATE) as i32;
        if !(1..=8).contains(&dsd_mult) {
            return Err(format!("DSD 倍率 {dsd_mult} 不在 1..=8 范围内"));
        }
        if !SUPPORTED_OUT_BITS.contains(&out_bits) {
            return Err(format!("不支持的 PCM 位深 {out_bits}，仅支持 16/24"));
        }
        if !SUPPORTED_OUT_RATES.contains(&out_rate) {
            return Err(format!(
                "不支持的 PCM 采样率 {out_rate}，仅支持 44100/48000/88200/96000/192000"
            ));
        }

        let (decim_ratio, upsample_ratio) = compute_decim_and_upsample(dsd_mult, out_rate);
        if decim_ratio <= 0 {
            return Err(format!("无效的抽取比 {decim_ratio}"));
        }

        let out_capacity =
            crate::Rdsd2Pcm::calc_frames_cap(DSD_BLOCK_BYTES, decim_ratio, upsample_ratio);
        if out_capacity == 0 {
            return Err("PCM 输出帧容量为 0".to_string());
        }

        let writer =
            Self::build_writer(out_bits, out_rate, dither, out_capacity, channels, upsample_ratio)?;
        let (lm, precalc) = Self::build_resamplers(
            channels,
            dsd_mult,
            decim_ratio,
            upsample_ratio,
            out_rate,
            filter,
        )?;

        debug!(
            "流式 DSD 转 PCM 初始化: channels={channels}, dsd_rate={dsd_rate}, out_rate={out_rate}, out_bits={out_bits}, decim={decim_ratio}, upsample={upsample_ratio}, 帧容量={out_capacity}"
        );

        Ok(Self {
            channels,
            dsd_mult,
            out_bits,
            out_rate,
            dither,
            filter,
            decim_ratio,
            upsample_ratio,
            out_capacity,
            writer,
            lm,
            precalc,
            channel_buffers: vec![Vec::with_capacity(DSD_BLOCK_BYTES); channels],
            channel_pos: 0,
        })
    }

    /// Actual output sample rate. Equal to the requested rate for every
    /// supported combination; exposed so callers can build matching headers.
    pub fn out_rate(&self) -> u32 {
        self.out_rate
    }

    /// Output bytes per sample (2 for 16-bit, 3 for 24-bit).
    pub fn bytes_per_sample(&self) -> usize {
        self.writer.bytes_per_sample()
    }

    /// Number of channels.
    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Push interleaved DSD bytes and take whatever PCM became available.
    ///
    /// The input must be interleaved by sample and MSB-first, exactly as the
    /// SACD sector parser emits it; each byte is bit-reversed here so the
    /// filters see the LSB-first order used inside DSF containers. The
    /// returned bytes are interleaved integer PCM in the output bit depth. An
    /// empty vector is normal for short inputs because the filters need a full
    /// block of DSD before they can emit samples.
    pub fn push(&mut self, interleaved_msb: &[u8]) -> Result<Vec<u8>, String> {
        let channels = self.channels;
        if channels == 0 {
            return Err("流式 PCM 转换器声道数为 0".to_string());
        }

        let mut out: Vec<u8> = Vec::new();
        for &byte in interleaved_msb {
            // `channel_pos` 存的是"下一个字节所属通道"，取值恒在 0..channels，
            // 省掉每字节一次取模。
            let channel = self.channel_pos;
            match self.channel_buffers.get_mut(channel) {
                Some(buffer) => buffer.push(byte.reverse_bits()),
                None => {
                    return Err(format!("通道索引 {channel} 超出 {channels} 通道缓冲范围"));
                }
            }
            self.channel_pos += 1;
            if self.channel_pos == channels {
                self.channel_pos = 0;
                // 只有完成一整轮后所有通道才可能同时满一块。
                if self
                    .channel_buffers
                    .iter()
                    .all(|buffer| buffer.len() >= DSD_BLOCK_BYTES)
                {
                    self.process_blocks(&mut out)?;
                }
            }
        }
        Ok(out)
    }

    /// Flush the converter at end of track.
    ///
    /// Feeds the per-channel remainder (less than one 4096-byte block) through
    /// the converters without zero padding, matching what the whole-file path
    /// does with the last partial DSF block: it converts `valid_bytes` only.
    /// Without this the tail of every track (up to ~11 ms) would be dropped and
    /// the streamed output would be shorter than a file conversion.
    pub fn flush(&mut self) -> Result<Vec<u8>, String> {
        let channels = self.channels;
        if channels == 0 {
            return Err("流式 PCM 转换器声道数为 0".to_string());
        }

        let leftover = self
            .channel_buffers
            .first()
            .map(|buffer| buffer.len())
            .unwrap_or(0);
        if leftover == 0 {
            return Ok(Vec::new());
        }

        // 输入按通道轮转，只有完整轮转才会触发块处理，因此各通道残余长度
        // 必须相同；不一致说明状态被破坏，直接报错而不是继续产出错位音频。
        if self
            .channel_buffers
            .iter()
            .any(|buffer| buffer.len() != leftover)
        {
            let lengths: Vec<usize> = self
                .channel_buffers
                .iter()
                .map(|buffer| buffer.len())
                .collect();
            return Err(format!(
                "流式 PCM 转换器各通道残余长度不一致: 期望 {leftover} 字节, 实际 {lengths:?}"
            ));
        }

        let mut out: Vec<u8> = Vec::new();
        let mut produced_min: Option<usize> = None;
        for channel in 0..channels {
            let produced = {
                let input = match self.channel_buffers.get(channel) {
                    Some(buffer) => buffer.as_slice(),
                    None => return Err(format!("通道索引 {channel} 越界")),
                };
                if let Some(resamplers) = self.lm.as_mut() {
                    let resampler = resamplers
                        .get_mut(channel)
                        .ok_or_else(|| format!("重采样器缺少通道 {channel}"))?;
                    let float_data = self.writer.float_data_mut();
                    resampler.process_bytes_lm(input, float_data)
                } else if let Some(decimators) = self.precalc.as_mut() {
                    let decimator = decimators
                        .get_mut(channel)
                        .ok_or_else(|| format!("抽取器缺少通道 {channel}"))?;
                    let float_data = self.writer.float_data_mut();
                    decimator.process_bytes(input, float_data)
                } else {
                    return Err("流式 PCM 转换器状态未初始化".to_string());
                }
            };

            produced_min = Some(match produced_min {
                Some(current) => current.min(produced),
                None => produced,
            });
            self.writer.write_to_buffer(produced, channel);
        }

        let frames = produced_min.unwrap_or(0);
        if frames > 0 {
            let pcm_bytes = frames * channels * self.writer.bytes_per_sample();
            out.extend_from_slice(&self.writer.take_memory(pcm_bytes));
        }

        for buffer in &mut self.channel_buffers {
            buffer.clear();
        }
        Ok(out)
    }

    /// Reset filter, dither and block state after a seek.
    ///
    /// The converter can then be fed from an arbitrary DSF block boundary
    /// again. A failure leaves the converter unusable; every later `push`
    /// reports the error instead of panicking.
    pub fn reset(&mut self) {
        if let Err(error) = self.rebuild() {
            warn!("重置流式 PCM 转换器失败: {error}");
            self.lm = None;
            self.precalc = None;
        }
    }

    /// Rebuild the writer and per-channel converters from the saved parameters.
    fn rebuild(&mut self) -> Result<(), String> {
        self.writer = Self::build_writer(
            self.out_bits,
            self.out_rate,
            self.dither,
            self.out_capacity,
            self.channels,
            self.upsample_ratio,
        )?;
        let (lm, precalc) = Self::build_resamplers(
            self.channels,
            self.dsd_mult,
            self.decim_ratio,
            self.upsample_ratio,
            self.out_rate,
            self.filter,
        )?;
        self.lm = lm;
        self.precalc = precalc;
        for buffer in &mut self.channel_buffers {
            buffer.clear();
        }
        self.channel_pos = 0;
        Ok(())
    }

    fn build_writer(
        out_bits: usize,
        out_rate: u32,
        dither: DitherType,
        out_capacity: usize,
        channels: usize,
        upsample_ratio: u32,
    ) -> Result<PcmWriter, String> {
        let dither =
            Dither::new(dither).map_err(|error| format!("初始化抖动器失败: {error}"))?;
        PcmWriter::new_memory(
            out_bits,
            out_rate,
            dither,
            out_capacity,
            channels,
            upsample_ratio,
        )
        .map_err(|error| format!("初始化 PCM 输出缓冲失败: {error}"))
    }

    fn build_resamplers(
        channels: usize,
        dsd_mult: i32,
        decim_ratio: i32,
        upsample_ratio: u32,
        out_rate: u32,
        filter: FilterType,
    ) -> Result<(Option<Vec<LMResampler>>, Option<Vec<BytePrecalcDecimator>>), String> {
        if upsample_ratio > 1 {
            let mut resamplers = Vec::with_capacity(channels);
            for channel in 0..channels {
                let resampler = LMResampler::new(upsample_ratio, decim_ratio, out_rate)
                    .map_err(|error| {
                        format!(
                            "初始化有理重采样器失败: 通道 {channel}, L={upsample_ratio}, M={decim_ratio}: {error}"
                        )
                    })?;
                resamplers.push(resampler);
            }
            return Ok((Some(resamplers), None));
        }

        let taps = select_precalc_taps(filter, dsd_mult, decim_ratio).ok_or_else(|| {
            format!(
                "缺少可用的抽取滤波器: ratio={decim_ratio}, filter={filter:?}, dsd_mult={dsd_mult}"
            )
        })?;
        let decim = u32::try_from(decim_ratio)
            .map_err(|_| format!("抽取比 {decim_ratio} 无法转换为无符号整数"))?;
        let mut decimators = Vec::with_capacity(channels);
        for channel in 0..channels {
            let decimator = BytePrecalcDecimator::new(taps, decim).ok_or_else(|| {
                format!("初始化整数抽取器失败: 通道 {channel}, ratio={decim}")
            })?;
            decimators.push(decimator);
        }
        Ok((None, Some(decimators)))
    }

    /// Convert one full block from every channel and append the packed PCM.
    fn process_blocks(&mut self, out: &mut Vec<u8>) -> Result<(), String> {
        let channels = self.channels;
        let writer_channels = self.writer.channels_num();
        if writer_channels != channels {
            return Err(format!(
                "PCM 输出缓冲声道数 {writer_channels} 与转换器声道数 {channels} 不一致"
            ));
        }

        let mut produced_min: Option<usize> = None;
        for channel in 0..channels {
            let produced = {
                let input = match self.channel_buffers.get(channel) {
                    Some(buffer) => buffer.get(..DSD_BLOCK_BYTES).ok_or_else(|| {
                        format!(
                            "通道 {channel} 的 DSD 缓冲只有 {} 字节，不足一个 {DSD_BLOCK_BYTES} 字节块",
                            buffer.len()
                        )
                    })?,
                    None => return Err(format!("通道索引 {channel} 越界")),
                };
                if let Some(resamplers) = self.lm.as_mut() {
                    let resampler = resamplers
                        .get_mut(channel)
                        .ok_or_else(|| format!("重采样器缺少通道 {channel}"))?;
                    let float_data = self.writer.float_data_mut();
                    resampler.process_bytes_lm(input, float_data)
                } else if let Some(decimators) = self.precalc.as_mut() {
                    let decimator = decimators
                        .get_mut(channel)
                        .ok_or_else(|| format!("抽取器缺少通道 {channel}"))?;
                    let float_data = self.writer.float_data_mut();
                    decimator.process_bytes(input, float_data)
                } else {
                    return Err("流式 PCM 转换器状态未初始化".to_string());
                }
            };

            produced_min = Some(match produced_min {
                Some(current) => current.min(produced),
                None => produced,
            });
            self.writer.write_to_buffer(produced, channel);
        }

        // 只取各通道共同产出的最小帧数：write_to_buffer 每批都从缓冲起点开写，
        // 多出的帧会在下一批被覆盖，且不会被 take_memory 取走，因此不会污染输出。
        let frames = produced_min.unwrap_or(0);
        if frames > 0 {
            let pcm_bytes = frames * writer_channels * self.writer.bytes_per_sample();
            out.extend_from_slice(&self.writer.take_memory(pcm_bytes));
        }

        for buffer in &mut self.channel_buffers {
            // 只移除已处理的前 DSD_BLOCK_BYTES 字节。必须保留超出块长的部分：
            // 一次 push 的输入长度不受块长整除时，多出来的字节若被丢弃，
            // 通道轮转位置就会与数据流错位，后续音频全部失真。
            let consumed = buffer.len().min(DSD_BLOCK_BYTES);
            buffer.drain(..consumed);
        }
        Ok(())
    }
}
