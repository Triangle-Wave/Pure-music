//! SACD 轨道提取入口。
//!
//! 从 ISO 镜像按逻辑扇区读取音频轨道，解析音频扇区后写成 DSF 文件。
//! 裸 DSD（3-in-14 / 3-in-16）直接交付；DST 压缩轨道先解码为交织的 DSD
//! 字节，再交给同一个 [`DsfWriter`]。

use std::path::Path;

use super::audio::AudioSectorParser;
use super::dsf::DsfWriter;
use super::reader::ImageReader;
use super::types::{SacdAreaKind, SacdError, SacdFrameFormat, SACD_LSN_SIZE};

/// 单批读取的逻辑扇区数，与镜像读取器的单次读取上限一致。
const SECTORS_PER_BATCH: u16 = 128;

/// 把一条音频轨道从 SACD ISO 提取为 DSF 文件。
///
/// `track_length_lsn` 是轨道占用的逻辑扇区数。每通道样本数先按
/// `track_length_lsn * 2048 * 8 / channel_count` 估算写入 fmt chunk，
/// [`DsfWriter::finalize`] 会按实际音频字节修正。DST 轨道按帧解码后写入，
/// 输出字节排列与裸 DSD 路径一致。
#[allow(clippy::too_many_arguments)]
pub(crate) fn extract_track_to_dsf(
    iso_path: &Path,
    area_kind: SacdAreaKind,
    track_start_lsn: u32,
    track_length_lsn: u32,
    channel_count: u8,
    sample_rate: u32,
    frame_format: SacdFrameFormat,
    output_path: &Path,
) -> Result<(), SacdError> {
    if channel_count == 0 {
        return Err(SacdError::invalid("声道数不能为 0"));
    }
    if sample_rate == 0 {
        return Err(SacdError::invalid("采样率不能为 0"));
    }
    if track_length_lsn == 0 {
        return Err(SacdError::invalid("轨道长度不能为 0"));
    }

    match (area_kind, channel_count) {
        (SacdAreaKind::TwoChannel, count) if count != 2 => {
            log::warn!("双声道区的声道数为 {count}，与预期的 2 不一致");
        }
        (SacdAreaKind::MultiChannel, count) if count <= 2 => {
            log::warn!("多声道区的声道数为 {count}，与预期的 2 以上不一致");
        }
        _ => {}
    }

    let estimated_bytes = u64::from(track_length_lsn) * SACD_LSN_SIZE as u64;
    let total_samples_per_channel = estimated_bytes * 8 / u64::from(channel_count);
    let extra_setting = match channel_count {
        2 => 0,
        6 => 4,
        _ => 0,
    };

    log::info!(
        "开始提取 SACD 轨道: area={area_kind:?}, iso={}, start_lsn={track_start_lsn}, length_lsn={track_length_lsn}, channels={channel_count}, sample_rate={sample_rate}",
        iso_path.display()
    );

    let mut image = ImageReader::open(iso_path)?;
    let mut parser = match frame_format {
        SacdFrameFormat::Dst => {
            log::info!(
                "轨道使用 DST 压缩，启用 DST 解码: start_lsn={track_start_lsn}, channels={channel_count}, sample_rate={sample_rate}"
            );
            AudioSectorParser::new_dst(channel_count, sample_rate, track_start_lsn)?
        }
        SacdFrameFormat::Dsd => AudioSectorParser::new(),
    };
    let mut writer = DsfWriter::create(
        output_path,
        u32::from(channel_count),
        sample_rate,
        total_samples_per_channel,
        extra_setting,
    )?;

    let mut lsn = track_start_lsn;
    let mut remaining = track_length_lsn;
    let mut written_bytes: u64 = 0;

    while remaining > 0 {
        let batch = remaining.min(u32::from(SECTORS_PER_BATCH)) as u16;
        let sectors = image.read_sectors(lsn, batch)?;
        let expected = usize::from(batch)
            .checked_mul(SACD_LSN_SIZE)
            .ok_or_else(|| SacdError::invalid("音频读取长度溢出"))?;
        if sectors.len() != expected {
            return Err(SacdError::invalid(format!(
                "LSN {lsn} 起的 {batch} 个音频扇区读取长度 {} 与预期 {expected} 不一致",
                sectors.len()
            )));
        }

        for sector in sectors.chunks_exact(SACD_LSN_SIZE) {
            let audio = parser.parse_sector(sector)?;
            if audio.is_empty() {
                continue;
            }
            writer.write_samples(&audio)?;
            written_bytes = written_bytes.saturating_add(audio.len() as u64);
        }

        lsn = lsn
            .checked_add(u32::from(batch))
            .ok_or_else(|| SacdError::invalid("轨道逻辑扇区号溢出"))?;
        remaining -= u32::from(batch);
    }

    if let Some(rest) = parser.flush()? {
        writer.write_samples(&rest)?;
        written_bytes = written_bytes.saturating_add(rest.len() as u64);
    }

    writer.finalize()?;

    log::info!(
        "SACD 轨道提取完成: start_lsn={track_start_lsn}, length_lsn={track_length_lsn}, 音频字节={written_bytes}, 输出={}",
        output_path.display()
    );

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    const PLAIN_SECTOR_SIZE: usize = 2048;
    const HEADERED_SECTOR_SIZE: usize = 2064;
    const HEADERED_SECTOR_HEADER: usize = 12;
    const MASTER_TOC_LSN: usize = 510;
    const AUDIO_START_LSN: usize = 512;
    const IMAGE_SECTORS: usize = 520;

    /// 单扇区音频负载：2048 - 1 字节扇区头 - 2 字节包信息 - 3 字节帧信息。
    const AUDIO_PAYLOAD_SIZE: usize = PLAIN_SECTOR_SIZE - 6;

    /// 测试结束后自动删除的临时文件。
    struct TempFile {
        path: PathBuf,
    }

    impl TempFile {
        fn create(suffix: &str, data: &[u8]) -> Self {
            let path = unique_temp_path(suffix);
            fs::write(&path, data).expect("写入临时文件失败");
            Self { path }
        }

        fn unused(suffix: &str) -> Self {
            Self {
                path: unique_temp_path(suffix),
            }
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
            "pure_music_extract_{}_{}_{}_{}.{}",
            std::process::id(),
            nanos,
            sequence,
            suffix,
            suffix
        ))
    }

    /// 构造一个只含扇区头的裸 DSD 音频扇区。
    fn write_audio_sector(target: &mut [u8], payload: &[u8], frame_start: bool) {
        let needed = 6 + payload.len();
        assert!(needed <= target.len(), "测试音频负载超出扇区");
        target.fill(0);
        target[0] = (1 << 2) | (1 << 5); // 裸 DSD，1 帧信息，1 数据包
        let length = payload.len() as u16;
        target[1] = (u8::from(frame_start) << 7) | (2 << 3) | ((length >> 8) as u8 & 0x07);
        target[2] = (length & 0xFF) as u8;
        // 帧信息位于 3..6，时间码全 0。
        target[6..needed].copy_from_slice(payload);
    }

    /// 构造最小 ISO：Master TOC 签名 + 两个裸 DSD 音频扇区。
    fn build_image(headered: bool) -> Vec<u8> {
        let (stride, header_len) = if headered {
            (HEADERED_SECTOR_SIZE, HEADERED_SECTOR_HEADER)
        } else {
            (PLAIN_SECTOR_SIZE, 0)
        };
        let mut image = vec![0u8; IMAGE_SECTORS * stride];

        let master_offset = MASTER_TOC_LSN * stride + header_len;
        image[master_offset..master_offset + 8].copy_from_slice(b"SACDMTOC");

        let payloads = [
            vec![0xA5u8; AUDIO_PAYLOAD_SIZE],
            vec![0x5Au8; AUDIO_PAYLOAD_SIZE],
        ];
        for (index, payload) in payloads.iter().enumerate() {
            let start = (AUDIO_START_LSN + index) * stride + header_len;
            let end = start + PLAIN_SECTOR_SIZE;
            write_audio_sector(&mut image[start..end], payload, index == 0);
        }

        image
    }

    fn read_u32(bytes: &[u8], offset: usize) -> u32 {
        let target = bytes.get(offset..offset + 4).expect("读取 u32 越界");
        u32::from_le_bytes(target.try_into().expect("u32 长度错误"))
    }

    fn read_u64(bytes: &[u8], offset: usize) -> u64 {
        let target = bytes.get(offset..offset + 8).expect("读取 u64 越界");
        u64::from_le_bytes(target.try_into().expect("u64 长度错误"))
    }

    #[test]
    fn extracts_plain_image_to_dsf() {
        let iso = TempFile::create("iso", &build_image(false));
        let output = TempFile::unused("dsf");

        extract_track_to_dsf(
            &iso.path,
            SacdAreaKind::TwoChannel,
            AUDIO_START_LSN as u32,
            2,
            2,
            2_822_400,
            SacdFrameFormat::Dsd,
            &output.path,
        )
        .expect("提取裸 DSD 轨道");

        let bytes = fs::read(&output.path).expect("读取 DSF 文件");
        assert_eq!(&bytes[0..4], b"DSD ");
        assert_eq!(read_u32(&bytes, 48), 2); // 声道类型：立体声
        assert_eq!(read_u32(&bytes, 52), 2); // 声道数
        assert_eq!(read_u32(&bytes, 56), 2_822_400); // 采样率
        assert_eq!(read_u32(&bytes, 60), 1); // 位深

        let audio_bytes = (AUDIO_PAYLOAD_SIZE * 2) as u64;
        assert_eq!(read_u64(&bytes, 64), audio_bytes / 2 * 8);
        assert_eq!(read_u64(&bytes, 84), 12 + 2 * 4096);
        assert_eq!(read_u64(&bytes, 12), bytes.len() as u64);
    }

    #[test]
    fn extracts_headered_image_to_dsf() {
        let iso = TempFile::create("iso", &build_image(true));
        let output = TempFile::unused("dsf");

        extract_track_to_dsf(
            &iso.path,
            SacdAreaKind::TwoChannel,
            AUDIO_START_LSN as u32,
            1,
            2,
            2_822_400,
            SacdFrameFormat::Dsd,
            &output.path,
        )
        .expect("从 2064 字节布局提取裸 DSD 轨道");

        let bytes = fs::read(&output.path).expect("读取 DSF 文件");
        assert_eq!(&bytes[0..4], b"DSD ");
        assert_eq!(read_u64(&bytes, 64), AUDIO_PAYLOAD_SIZE as u64 / 2 * 8);
        assert_eq!(read_u64(&bytes, 84), 12 + 2 * 4096);
    }

    /// dst-decoder 仓库的 stereo frame_001 测试向量。
    const DST_FIXTURE: &[u8] = include_bytes!("testdata/frame_001.dst");
    const DST_DSD_BYTES: u64 = 9_408;

    /// 构造一个只含一个 DST 音频包的扇区。
    fn write_dst_audio_sector(target: &mut [u8], payload: &[u8], sector_count: u8) {
        let needed = 7 + payload.len();
        assert!(needed <= target.len(), "测试 DST 负载超出扇区");
        target.fill(0);
        target[0] = 0x01 | (1 << 2) | (1 << 5); // DST，1 帧信息，1 数据包
        let length = payload.len() as u16;
        target[1] = (1 << 7) | (2 << 3) | ((length >> 8) as u8 & 0x07);
        target[2] = (length & 0xFF) as u8;
        target[6] = (sector_count & 0x1F) << 2;
        target[7..needed].copy_from_slice(payload);
    }

    /// 构造最小 DST ISO：Master TOC 签名 + 一个 DST 音频扇区。
    fn build_dst_image() -> Vec<u8> {
        let mut image = vec![0u8; IMAGE_SECTORS * PLAIN_SECTOR_SIZE];

        let master_offset = MASTER_TOC_LSN * PLAIN_SECTOR_SIZE;
        image[master_offset..master_offset + 8].copy_from_slice(b"SACDMTOC");

        let start = AUDIO_START_LSN * PLAIN_SECTOR_SIZE;
        let end = start + PLAIN_SECTOR_SIZE;
        write_dst_audio_sector(&mut image[start..end], DST_FIXTURE, 1);

        image
    }

    #[test]
    fn extracts_dst_image_to_dsf() {
        let iso = TempFile::create("iso", &build_dst_image());
        let output = TempFile::unused("dsf");

        extract_track_to_dsf(
            &iso.path,
            SacdAreaKind::TwoChannel,
            AUDIO_START_LSN as u32,
            1,
            2,
            2_822_400,
            SacdFrameFormat::Dst,
            &output.path,
        )
        .expect("提取 DST 轨道");

        let bytes = fs::read(&output.path).expect("读取 DSF 文件");
        assert_eq!(&bytes[0..4], b"DSD ");
        assert_eq!(read_u32(&bytes, 52), 2);
        assert_eq!(read_u64(&bytes, 64), DST_DSD_BYTES / 2 * 8);
        assert_eq!(read_u64(&bytes, 84), 12 + 2 * 4096);
        assert_eq!(read_u64(&bytes, 12), bytes.len() as u64);
    }

    #[test]
    fn rejects_dst_decoder_configuration_failure() {
        let iso = TempFile::create("iso", &build_image(false));
        let output = TempFile::unused("dsf");

        let result = extract_track_to_dsf(
            &iso.path,
            SacdAreaKind::TwoChannel,
            AUDIO_START_LSN as u32,
            1,
            2,
            48_000,
            SacdFrameFormat::Dst,
            &output.path,
        );

        assert!(matches!(result, Err(SacdError::InvalidData(_))));
        assert!(!output.path.exists());
    }

    #[test]
    fn rejects_non_sacd_image() {
        let iso = TempFile::create("iso", &[0u8; PLAIN_SECTOR_SIZE * 4]);
        let output = TempFile::unused("dsf");

        let result = extract_track_to_dsf(
            &iso.path,
            SacdAreaKind::TwoChannel,
            AUDIO_START_LSN as u32,
            1,
            2,
            2_822_400,
            SacdFrameFormat::Dsd,
            &output.path,
        );

        assert!(matches!(result, Err(SacdError::NotSacd)));
        assert!(!output.path.exists());
    }
}
