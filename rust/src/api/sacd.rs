//! SACD ISO 只读 TOC 解析模块。
//!
//! 当前阶段只解析镜像的目录结构（Master TOC、Area TOC、TrackList），
//! 不处理 DST 解码，也不接入扫描、播放或 FFI。

#![allow(dead_code)]

mod area_toc;
mod master_toc;
mod reader;
mod tracklist;
mod types;

pub(crate) use reader::{is_sacd_iso, read_sacd_toc};
pub(crate) use types::{SacdArea, SacdAreaKind, SacdError, SacdFrameFormat, SacdToc, SacdTrack};

#[cfg(test)]
mod tests {
    use super::types::SACD_LSN_SIZE;
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    const PLAIN_SECTOR_SIZE: usize = 2048;
    const HEADERED_SECTOR_SIZE: usize = 2064;
    const HEADERED_SECTOR_HEADER: usize = 12;
    const IMAGE_SECTOR_COUNT: usize = 640;
    const MASTER_TOC_LSN: usize = 510;
    const AREA_TOC_LSN: usize = 544;
    const AREA_TOC_FALLBACK_LSN: usize = 560;
    const AREA_TOC_SECTORS: u16 = 5;

    /// 测试结束后自动删除的临时镜像文件。
    struct TempImage {
        path: PathBuf,
    }

    impl TempImage {
        fn create(data: &[u8]) -> Self {
            let path = unique_temp_path();
            fs::write(&path, data).expect("写入临时镜像失败");
            Self { path }
        }
    }

    impl Drop for TempImage {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.path);
        }
    }

    fn unique_temp_path() -> PathBuf {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let sequence = COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "pure_music_sacd_{}_{}_{}.iso",
            std::process::id(),
            nanos,
            sequence
        ))
    }

    /// 按 2048 或 2064 字节布局逐扇区构造镜像。
    struct ImageBuilder {
        data: Vec<u8>,
        stride: usize,
        header_len: usize,
    }

    impl ImageBuilder {
        fn new(headered: bool) -> Self {
            let (stride, header_len) = if headered {
                (HEADERED_SECTOR_SIZE, HEADERED_SECTOR_HEADER)
            } else {
                (PLAIN_SECTOR_SIZE, 0)
            };
            Self {
                data: vec![0u8; IMAGE_SECTOR_COUNT * stride],
                stride,
                header_len,
            }
        }

        fn sector_mut(&mut self, lsn: usize) -> &mut [u8] {
            let start = lsn * self.stride + self.header_len;
            let end = start + SACD_LSN_SIZE;
            assert!(end <= self.data.len(), "测试镜像扇区越界");
            &mut self.data[start..end]
        }

        fn into_data(self) -> Vec<u8> {
            self.data
        }
    }

    fn put_u16(sector: &mut [u8], offset: usize, value: u16) {
        let target = sector
            .get_mut(offset..offset + 2)
            .expect("测试写入 u16 越界");
        target.copy_from_slice(&value.to_be_bytes());
    }

    fn put_u32(sector: &mut [u8], offset: usize, value: u32) {
        let target = sector
            .get_mut(offset..offset + 4)
            .expect("测试写入 u32 越界");
        target.copy_from_slice(&value.to_be_bytes());
    }

    /// 按 Master TOC 字段偏移写入（见 master_toc.rs 的偏移注释）。
    fn write_master_toc(
        sector: &mut [u8],
        area_1_toc_1_start: u32,
        area_1_toc_2_start: u32,
        area_1_toc_size: u16,
        area_2_toc_1_start: u32,
        area_2_toc_2_start: u32,
        area_2_toc_size: u16,
    ) {
        sector[0..8].copy_from_slice(b"SACDMTOC");
        sector[8] = 1;
        sector[9] = 0x14;
        put_u16(sector, 16, 1); // Album_Set_Size
        put_u16(sector, 18, 1); // Album_Sequence_Number
        put_u32(sector, 64, area_1_toc_1_start);
        put_u32(sector, 68, area_1_toc_2_start);
        put_u32(sector, 72, area_2_toc_1_start);
        put_u32(sector, 76, area_2_toc_2_start);
        sector[80] = 0x80; // Hybrid 标志
        put_u16(sector, 84, area_1_toc_size);
        put_u16(sector, 86, area_2_toc_size);
    }

    /// 按 Area TOC 字段偏移写入（见 area_toc.rs 的偏移注释）。
    fn write_area_toc(
        sector: &mut [u8],
        signature: &[u8],
        channel_count: u8,
        track_count: u8,
        frame_format: u8,
        total_playtime: (u8, u8, u8),
        track_start_lsn: u32,
        track_end_lsn: u32,
    ) {
        assert_eq!(signature.len(), 8, "Area TOC 签名必须为 8 字节");
        sector[0..8].copy_from_slice(signature);
        sector[8] = 1;
        sector[9] = 0x14;
        put_u16(sector, 10, AREA_TOC_SECTORS);
        sector[21] = frame_format & 0x0F;
        sector[32] = channel_count;
        sector[64] = total_playtime.0;
        sector[65] = total_playtime.1;
        sector[66] = total_playtime.2;
        sector[69] = track_count;
        put_u32(sector, 72, track_start_lsn);
        put_u32(sector, 76, track_end_lsn);
    }

    fn write_track_list_1(sector: &mut [u8], starts: &[u32], lengths: &[u32]) {
        sector[0..8].copy_from_slice(b"SACDTRL1");
        for (index, value) in starts.iter().enumerate() {
            put_u32(sector, 8 + index * 4, *value);
        }
        let lengths_base = 8 + 255 * 4;
        for (index, value) in lengths.iter().enumerate() {
            put_u32(sector, lengths_base + index * 4, *value);
        }
    }

    fn write_track_list_2(
        sector: &mut [u8],
        starts: &[(u8, u8, u8)],
        durations: &[(u8, u8, u8)],
    ) {
        sector[0..8].copy_from_slice(b"SACDTRL2");
        for (index, (minutes, seconds, frames)) in starts.iter().enumerate() {
            put_timecode(sector, 8 + index * 4, *minutes, *seconds, *frames);
        }
        let durations_base = 8 + 255 * 4;
        for (index, (minutes, seconds, frames)) in durations.iter().enumerate() {
            put_timecode(
                sector,
                durations_base + index * 4,
                *minutes,
                *seconds,
                *frames,
            );
        }
    }

    fn put_timecode(sector: &mut [u8], offset: usize, minutes: u8, seconds: u8, frames: u8) {
        let target = sector
            .get_mut(offset..offset + 4)
            .expect("测试写入时间码越界");
        target[0] = minutes;
        target[1] = seconds;
        target[2] = frames;
        target[3] = 0;
    }

    /// 构造最小镜像：1 个 2CH 区、2 轨、裸 DSD（3-in-14）、TOC 1 与 TOC 2 都存在。
    fn minimal_image(headered: bool) -> Vec<u8> {
        let mut image = ImageBuilder::new(headered);
        write_master_toc(
            image.sector_mut(MASTER_TOC_LSN),
            AREA_TOC_LSN as u32,
            0,
            AREA_TOC_SECTORS,
            0,
            0,
            0,
        );
        write_area_toc(
            image.sector_mut(AREA_TOC_LSN),
            b"TWOCHTOC",
            2,
            2,
            2,
            (5, 45, 50),
            1000,
            4500,
        );
        write_track_list_1(
            image.sector_mut(AREA_TOC_LSN + 1),
            &[1000, 3000],
            &[2000, 1500],
        );
        write_track_list_2(
            image.sector_mut(AREA_TOC_LSN + 2),
            &[(0, 0, 0), (3, 0, 0)],
            &[(1, 30, 25), (2, 15, 0)],
        );
        image.into_data()
    }

    fn assert_invalid_data(result: Result<SacdToc, SacdError>) {
        match result {
            Err(SacdError::InvalidData(_)) => {}
            other => panic!("期望 InvalidData，实际为 {other:?}"),
        }
    }

    fn assert_minimal_toc(image: &TempImage) {
        let toc = read_sacd_toc(&image.path).expect("应能解析最小镜像");
        assert_eq!(toc.version_major, 1);
        assert_eq!(toc.version_minor, 0x14);
        assert_eq!(toc.disc_flags, 0x80);
        assert_eq!(toc.album_set_size, 1);
        assert_eq!(toc.album_sequence_number, 1);
        assert_eq!(toc.areas.len(), 1);

        let area = &toc.areas[0];
        assert_eq!(area.kind, SacdAreaKind::TwoChannel);
        assert_eq!(area.channel_count, 2);
        assert_eq!(area.track_count, 2);
        assert_eq!(area.total_playtime_ms, 345_666);
        assert_eq!(area.frame_format, SacdFrameFormat::Dsd);
        assert_eq!(area.track_start_lsn, 1000);
        assert_eq!(area.track_end_lsn, 4500);
        assert_eq!(area.tracks.len(), 2);
        assert_eq!(
            area.tracks[0],
            SacdTrack {
                number: 1,
                start_lsn: 1000,
                length_lsn: 2000,
                start_ms: 0,
                duration_ms: 90_333,
            }
        );
        assert_eq!(
            area.tracks[1],
            SacdTrack {
                number: 2,
                start_lsn: 3000,
                length_lsn: 1500,
                start_ms: 180_000,
                duration_ms: 135_000,
            }
        );
    }

    #[test]
    fn is_sacd_iso_returns_false_for_non_sacd_file() {
        let image = TempImage::create(&vec![0u8; PLAIN_SECTOR_SIZE * 8]);
        assert!(!is_sacd_iso(&image.path));
    }

    #[test]
    fn is_sacd_iso_returns_false_for_missing_file() {
        let path = unique_temp_path();
        assert!(!is_sacd_iso(&path));
    }

    #[test]
    fn is_sacd_iso_returns_true_for_constructed_image() {
        let image = TempImage::create(&minimal_image(false));
        assert!(is_sacd_iso(&image.path));
    }

    #[test]
    fn parses_minimal_plain_2048_image() {
        let image = TempImage::create(&minimal_image(false));
        assert!(is_sacd_iso(&image.path));
        assert_minimal_toc(&image);
    }

    #[test]
    fn parses_minimal_headered_2064_image() {
        let image = TempImage::create(&minimal_image(true));
        assert!(is_sacd_iso(&image.path));
        assert_minimal_toc(&image);
    }

    #[test]
    fn falls_back_to_second_area_toc() {
        let mut image = ImageBuilder::new(false);
        write_master_toc(
            image.sector_mut(MASTER_TOC_LSN),
            AREA_TOC_LSN as u32,
            AREA_TOC_FALLBACK_LSN as u32,
            AREA_TOC_SECTORS,
            0,
            0,
            0,
        );
        // AREA_TOC_LSN 处保持全 0，签名无效，应回退到 TOC 2。
        write_area_toc(
            image.sector_mut(AREA_TOC_FALLBACK_LSN),
            b"TWOCHTOC",
            2,
            2,
            2,
            (5, 45, 50),
            1000,
            4500,
        );
        write_track_list_1(
            image.sector_mut(AREA_TOC_FALLBACK_LSN + 1),
            &[1000, 3000],
            &[2000, 1500],
        );
        write_track_list_2(
            image.sector_mut(AREA_TOC_FALLBACK_LSN + 2),
            &[(0, 0, 0), (3, 0, 0)],
            &[(1, 30, 25), (2, 15, 0)],
        );

        let image = TempImage::create(&image.into_data());
        let toc = read_sacd_toc(&image.path).expect("TOC 1 无效时应回退到 TOC 2");
        assert_eq!(toc.areas.len(), 1);
        assert_eq!(toc.areas[0].tracks.len(), 2);
        assert_eq!(toc.areas[0].tracks[1].start_lsn, 3000);
    }

    #[test]
    fn missing_track_list_2_yields_zero_times() {
        let mut image = ImageBuilder::new(false);
        write_master_toc(
            image.sector_mut(MASTER_TOC_LSN),
            AREA_TOC_LSN as u32,
            0,
            AREA_TOC_SECTORS,
            0,
            0,
            0,
        );
        write_area_toc(
            image.sector_mut(AREA_TOC_LSN),
            b"TWOCHTOC",
            2,
            2,
            2,
            (5, 45, 50),
            1000,
            4500,
        );
        write_track_list_1(
            image.sector_mut(AREA_TOC_LSN + 1),
            &[1000, 3000],
            &[2000, 1500],
        );

        let image = TempImage::create(&image.into_data());
        let toc = read_sacd_toc(&image.path).expect("缺少 SACDTRL2 时仍应解析轨道");
        let area = &toc.areas[0];
        assert_eq!(area.tracks.len(), 2);
        for track in &area.tracks {
            assert_eq!(track.start_ms, 0);
            assert_eq!(track.duration_ms, 0);
        }
    }

    #[test]
    fn rejects_wrong_master_signature() {
        let mut image = ImageBuilder::new(false);
        image.sector_mut(MASTER_TOC_LSN)[0..8].copy_from_slice(b"NOTSACD!");
        let image = TempImage::create(&image.into_data());

        assert!(!is_sacd_iso(&image.path));
        match read_sacd_toc(&image.path) {
            Err(SacdError::NotSacd) => {}
            other => panic!("期望 NotSacd，实际为 {other:?}"),
        }
    }

    #[test]
    fn rejects_area_toc_size_out_of_range() {
        let mut image = ImageBuilder::new(false);
        write_master_toc(
            image.sector_mut(MASTER_TOC_LSN),
            AREA_TOC_LSN as u32,
            0,
            4,
            0,
            0,
            0,
        );
        let image = TempImage::create(&image.into_data());
        assert_invalid_data(read_sacd_toc(&image.path));
    }

    #[test]
    fn rejects_zero_track_count() {
        let mut image = ImageBuilder::new(false);
        write_master_toc(
            image.sector_mut(MASTER_TOC_LSN),
            AREA_TOC_LSN as u32,
            0,
            AREA_TOC_SECTORS,
            0,
            0,
            0,
        );
        write_area_toc(
            image.sector_mut(AREA_TOC_LSN),
            b"TWOCHTOC",
            2,
            0,
            2,
            (5, 45, 50),
            1000,
            4500,
        );
        let image = TempImage::create(&image.into_data());
        assert_invalid_data(read_sacd_toc(&image.path));
    }

    #[test]
    fn rejects_invalid_area_signature() {
        let mut image = ImageBuilder::new(false);
        write_master_toc(
            image.sector_mut(MASTER_TOC_LSN),
            AREA_TOC_LSN as u32,
            0,
            AREA_TOC_SECTORS,
            0,
            0,
            0,
        );
        write_area_toc(
            image.sector_mut(AREA_TOC_LSN),
            b"BADSIGNC",
            2,
            2,
            2,
            (5, 45, 50),
            1000,
            4500,
        );
        let image = TempImage::create(&image.into_data());
        assert_invalid_data(read_sacd_toc(&image.path));
    }

    #[test]
    fn rejects_missing_track_list_1() {
        let mut image = ImageBuilder::new(false);
        write_master_toc(
            image.sector_mut(MASTER_TOC_LSN),
            AREA_TOC_LSN as u32,
            0,
            AREA_TOC_SECTORS,
            0,
            0,
            0,
        );
        write_area_toc(
            image.sector_mut(AREA_TOC_LSN),
            b"TWOCHTOC",
            2,
            2,
            2,
            (5, 45, 50),
            1000,
            4500,
        );
        let image = TempImage::create(&image.into_data());
        assert_invalid_data(read_sacd_toc(&image.path));
    }
}
