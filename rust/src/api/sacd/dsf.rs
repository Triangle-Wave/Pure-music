//! DSF 文件写入。
//!
//! DSF 由 DSD chunk、fmt chunk 与 data chunk 组成。SACD 的音频数据按字节
//! 交织、MSB-first 排列，本模块负责按通道去交织、反位（MSB-first 转
//! LSB-first），并每通道累积 4096 字节后按通道顺序写出。

use std::fs::File;
use std::io::{BufWriter, Seek, SeekFrom, Write};
use std::path::Path;

use super::types::SacdError;
use flutter_rust_bridge::frb;

/// DSD chunk 标识。
const DSD_CHUNK_ID: &[u8; 4] = b"DSD ";

/// fmt chunk 标识。
const FMT_CHUNK_ID: &[u8; 4] = b"fmt ";

/// data chunk 标识。
const DATA_CHUNK_ID: &[u8; 4] = b"data";

/// DSD chunk 固定长度（字节）。
const DSD_CHUNK_SIZE: u64 = 28;

/// fmt chunk 固定长度（字节）。
const FMT_CHUNK_SIZE: u64 = 52;

/// data chunk 头长度（字节）。
const DATA_CHUNK_HEADER_SIZE: u64 = 12;

/// DSD chunk 中总文件大小字段的偏移。
const TOTAL_FILE_SIZE_OFFSET: u64 = 12;

/// fmt chunk 中每通道样本数字段的偏移。
const FMT_SAMPLE_COUNT_OFFSET: u64 = 64;

/// DSF 每通道块大小（字节），由规范固定为 4096。
pub(crate) const DSF_BLOCK_SIZE_PER_CHANNEL: usize = 4096;

/// DSF 文件写入器。
#[frb(ignore)]
pub(crate) struct DsfWriter {
    /// 带缓冲的文件写入器。
    writer: BufWriter<File>,
    /// 声道数。
    channel_count: u32,
    /// data chunk 头在文件中的偏移。
    data_chunk_offset: u64,
    /// 已写入的音频数据字节数（含补齐的块）。
    bytes_written: u64,
    /// 收到的实际音频字节数（不含补齐的块）。
    decoded_bytes_total: u64,
    /// 每通道的样本缓冲，每满 4096 字节写出一块。
    channel_buffers: Vec<Vec<u8>>,
    /// 下一个字节所属通道的轮转位置。
    channel_buffer_pos: usize,
}

impl DsfWriter {
    /// 创建 DSF 文件并写入 DSD / fmt / data 三个 chunk 头。
    ///
    /// `total_samples_per_channel` 是调用方按轨道长度估算的每通道样本数，
    /// 先写入 fmt chunk，[`finalize`](Self::finalize) 时按实际音频字节修正。
    pub(crate) fn create(
        path: &Path,
        channel_count: u32,
        sample_rate: u32,
        total_samples_per_channel: u64,
        extra_setting: u8,
    ) -> Result<Self, SacdError> {
        if channel_count == 0 {
            return Err(SacdError::invalid("DSF 声道数不能为 0"));
        }
        if sample_rate == 0 {
            return Err(SacdError::invalid("DSF 采样率不能为 0"));
        }

        let file = File::create(path).map_err(|error| {
            SacdError::Io(std::io::Error::new(
                error.kind(),
                format!("创建 DSF 文件 {} 失败: {error}", path.display()),
            ))
        })?;
        let mut writer = BufWriter::new(file);

        // DSD chunk：标识、块长度、总文件大小（占位）、metadata 指针。
        writer.write_all(DSD_CHUNK_ID)?;
        writer.write_all(&DSD_CHUNK_SIZE.to_le_bytes())?;
        writer.write_all(&0u64.to_le_bytes())?;
        writer.write_all(&0u64.to_le_bytes())?;

        // fmt chunk：版本、格式、声道类型、声道数、采样率、位深、样本数、
        // 块大小、保留字段。
        writer.write_all(FMT_CHUNK_ID)?;
        writer.write_all(&FMT_CHUNK_SIZE.to_le_bytes())?;
        writer.write_all(&1u32.to_le_bytes())?;
        writer.write_all(&0u32.to_le_bytes())?;
        writer.write_all(&channel_type(channel_count, extra_setting).to_le_bytes())?;
        writer.write_all(&channel_count.to_le_bytes())?;
        writer.write_all(&sample_rate.to_le_bytes())?;
        writer.write_all(&1u32.to_le_bytes())?;
        writer.write_all(&total_samples_per_channel.to_le_bytes())?;
        writer.write_all(&(DSF_BLOCK_SIZE_PER_CHANNEL as u32).to_le_bytes())?;
        writer.write_all(&0u32.to_le_bytes())?;

        // data chunk 头：标识与长度占位。
        let data_chunk_offset = writer.stream_position()?;
        writer.write_all(DATA_CHUNK_ID)?;
        writer.write_all(&0u64.to_le_bytes())?;

        let channel_buffers =
            vec![Vec::with_capacity(DSF_BLOCK_SIZE_PER_CHANNEL); channel_count as usize];

        Ok(Self {
            writer,
            channel_count,
            data_chunk_offset,
            bytes_written: 0,
            decoded_bytes_total: 0,
            channel_buffers,
            channel_buffer_pos: 0,
        })
    }

    /// 写入字节交织、MSB-first 的裸 DSD 数据。
    ///
    /// 数据按轮转顺序分派到各通道缓冲，每个字节反位为 LSB-first；当所有
    /// 通道都累积满 4096 字节时，按通道顺序写出一整块。
    pub(crate) fn write_samples(&mut self, data: &[u8]) -> Result<(), SacdError> {
        let channels = self.channel_count as usize;
        if channels == 0 {
            return Err(SacdError::invalid("DSF 声道数不能为 0"));
        }

        self.decoded_bytes_total = self
            .decoded_bytes_total
            .saturating_add(data.len() as u64);

        for &byte in data {
            let channel_index = self.channel_buffer_pos % channels;
            let buffer = self
                .channel_buffers
                .get_mut(channel_index)
                .ok_or_else(|| SacdError::invalid(format!("DSF 通道索引 {channel_index} 越界")))?;
            buffer.push(reverse_bits(byte));
            self.channel_buffer_pos = self.channel_buffer_pos.wrapping_add(1);

            if self
                .channel_buffers
                .iter()
                .all(|buffer| buffer.len() >= DSF_BLOCK_SIZE_PER_CHANNEL)
            {
                Self::drain_full_blocks(
                    &mut self.writer,
                    &mut self.channel_buffers,
                    &mut self.bytes_written,
                )?;
            }
        }

        Ok(())
    }

    /// 补齐最后一个不满的块并回填 chunk 长度，完成文件写入。
    pub(crate) fn finalize(mut self) -> Result<(), SacdError> {
        let has_partial = self
            .channel_buffers
            .iter()
            .any(|buffer| !buffer.is_empty());
        if has_partial {
            for buffer in &mut self.channel_buffers {
                if buffer.len() < DSF_BLOCK_SIZE_PER_CHANNEL {
                    buffer.resize(DSF_BLOCK_SIZE_PER_CHANNEL, 0);
                }
            }
            Self::drain_full_blocks(
                &mut self.writer,
                &mut self.channel_buffers,
                &mut self.bytes_written,
            )?;
        }

        let total_file_size = self.writer.stream_position()?;

        // 回填 DSD chunk 的总文件大小；metadata 指针保持 0（不写 ID3）。
        self.writer
            .seek(SeekFrom::Start(TOTAL_FILE_SIZE_OFFSET))?;
        self.writer.write_all(&total_file_size.to_le_bytes())?;

        // 按实际音频字节修正每通道样本数，避免估算值大于真实数据长度。
        let channels = u64::from(self.channel_count.max(1));
        let sample_count = self.decoded_bytes_total / channels * 8;
        self.writer
            .seek(SeekFrom::Start(FMT_SAMPLE_COUNT_OFFSET))?;
        self.writer.write_all(&sample_count.to_le_bytes())?;

        // 回填 data chunk 长度：12 字节头 + 音频数据。
        let data_chunk_size = DATA_CHUNK_HEADER_SIZE.saturating_add(self.bytes_written);
        self.writer
            .seek(SeekFrom::Start(self.data_chunk_offset.saturating_add(4)))?;
        self.writer.write_all(&data_chunk_size.to_le_bytes())?;

        self.writer.flush()?;
        Ok(())
    }

    /// 把所有已满的通道块按通道顺序写出，并清空对应缓冲。
    fn drain_full_blocks(
        writer: &mut BufWriter<File>,
        buffers: &mut [Vec<u8>],
        bytes_written: &mut u64,
    ) -> Result<(), SacdError> {
        if buffers.is_empty() {
            return Err(SacdError::invalid("DSF 通道缓冲区为空"));
        }
        for (index, buffer) in buffers.iter().enumerate() {
            if buffer.len() < DSF_BLOCK_SIZE_PER_CHANNEL {
                return Err(SacdError::invalid(format!(
                    "DSF 通道 {index} 的缓冲区只有 {} 字节，不足一个块",
                    buffer.len()
                )));
            }
        }

        let mut written = 0u64;
        for (index, buffer) in buffers.iter_mut().enumerate() {
            let block = buffer
                .get(..DSF_BLOCK_SIZE_PER_CHANNEL)
                .ok_or_else(|| SacdError::invalid(format!("DSF 通道 {index} 的块长度不足")))?;
            writer.write_all(block)?;
            buffer.drain(..DSF_BLOCK_SIZE_PER_CHANNEL);
            written = written.saturating_add(DSF_BLOCK_SIZE_PER_CHANNEL as u64);
        }

        *bytes_written = bytes_written.saturating_add(written);
        Ok(())
    }
}

/// 反转字节位序（SACD 的 MSB-first 转 DSF 的 LSB-first）。
#[inline]
fn reverse_bits(byte: u8) -> u8 {
    byte.reverse_bits()
}

/// 按声道数与区附加设置确定 DSF 声道类型。
fn channel_type(channel_count: u32, extra_setting: u8) -> u32 {
    if channel_count == 2 && extra_setting == 0 {
        return 2;
    }
    if channel_count == 5 && extra_setting == 3 {
        return 6;
    }
    if channel_count == 6 && extra_setting == 4 {
        return 7;
    }

    match channel_count {
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        5 => 6,
        6 => 7,
        _ => 2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    /// 测试结束后自动删除的临时文件。
    struct TempFile {
        path: PathBuf,
    }

    impl TempFile {
        fn new(suffix: &str) -> Self {
            let path = unique_temp_path(suffix);
            Self { path }
        }
    }

    impl Drop for TempFile {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.path);
        }
    }

    fn unique_temp_path(suffix: &str) -> PathBuf {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let sequence = COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "pure_music_dsf_{}_{}_{}_{}.dsf",
            std::process::id(),
            nanos,
            sequence,
            suffix
        ))
    }

    fn read_u32(bytes: &[u8], offset: usize) -> u32 {
        let target = bytes
            .get(offset..offset + 4)
            .expect("读取 u32 越界");
        u32::from_le_bytes(target.try_into().expect("u32 长度错误"))
    }

    fn read_u64(bytes: &[u8], offset: usize) -> u64 {
        let target = bytes
            .get(offset..offset + 8)
            .expect("读取 u64 越界");
        u64::from_le_bytes(target.try_into().expect("u64 长度错误"))
    }

    #[test]
    fn reverse_bits_matches_dsf_order() {
        assert_eq!(reverse_bits(0b0000_0000), 0b0000_0000);
        assert_eq!(reverse_bits(0b1111_1111), 0b1111_1111);
        assert_eq!(reverse_bits(0b1000_0000), 0b0000_0001);
        assert_eq!(reverse_bits(0b0000_0001), 0b1000_0000);
        assert_eq!(reverse_bits(0b1011_0010), 0b0100_1101);
    }

    #[test]
    fn writer_produces_valid_header_and_padded_data() {
        let output = TempFile::new("stereo");
        let mut writer =
            DsfWriter::create(&output.path, 2, 2_822_400, 16_384, 0).expect("创建 DSF 文件");
        writer.write_samples(&[0x01, 0x80]).expect("写入样本");
        writer.finalize().expect("完成 DSF 文件");

        let bytes = fs::read(&output.path).expect("读取 DSF 文件");
        assert_eq!(&bytes[0..4], b"DSD ");
        assert_eq!(&bytes[28..32], b"fmt ");
        assert_eq!(&bytes[80..84], b"data");

        assert_eq!(read_u32(&bytes, 40), 1); // 格式版本
        assert_eq!(read_u32(&bytes, 44), 0); // 格式 ID：裸 DSD
        assert_eq!(read_u32(&bytes, 48), 2); // 声道类型：立体声
        assert_eq!(read_u32(&bytes, 52), 2); // 声道数
        assert_eq!(read_u32(&bytes, 56), 2_822_400); // 采样率
        assert_eq!(read_u32(&bytes, 60), 1); // 位深
        assert_eq!(read_u32(&bytes, 72), 4096); // 每通道块大小
        assert_eq!(read_u32(&bytes, 76), 0); // 保留字段
        assert_eq!(read_u64(&bytes, 64), 8); // 每通道 1 字节 * 8 bit

        assert_eq!(read_u64(&bytes, 12), bytes.len() as u64);
        assert_eq!(read_u64(&bytes, 84), 12 + 2 * 4096);
        assert_eq!(bytes.len(), 92 + 2 * DSF_BLOCK_SIZE_PER_CHANNEL);

        let data = &bytes[92..];
        assert_eq!(data[0], 0x80); // ch0：0x01 反位
        assert_eq!(data[DSF_BLOCK_SIZE_PER_CHANNEL], 0x01); // ch1：0x80 反位
        assert!(data[1..DSF_BLOCK_SIZE_PER_CHANNEL].iter().all(|&byte| byte == 0));
        assert!(data[DSF_BLOCK_SIZE_PER_CHANNEL + 1..]
            .iter()
            .all(|&byte| byte == 0));
    }

    #[test]
    fn writer_maps_six_channel_extra_setting() {
        let output = TempFile::new("six_channel");
        let writer = DsfWriter::create(&output.path, 6, 2_822_400, 0, 4).expect("创建 DSF 文件");
        writer.finalize().expect("完成 DSF 文件");

        let bytes = fs::read(&output.path).expect("读取 DSF 文件");
        assert_eq!(read_u32(&bytes, 48), 7); // 5.1 声道
        assert_eq!(read_u32(&bytes, 52), 6);
        assert_eq!(read_u64(&bytes, 84), 12);
        assert_eq!(read_u64(&bytes, 12), 92);
        assert_eq!(bytes.len(), 92);
    }

    #[test]
    fn writer_rejects_zero_channel_count() {
        let output = TempFile::new("zero_channel");
        assert!(matches!(
            DsfWriter::create(&output.path, 0, 2_822_400, 0, 0),
            Err(SacdError::InvalidData(_))
        ));
    }
}
