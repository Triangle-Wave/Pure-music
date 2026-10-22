//! SACD ISO 只读解析与裸 DSD 轨道提取模块。
//!
//! 解析镜像的目录结构（Master TOC、Area TOC、TrackList）与 ISO 同目录 XML
//! 元数据，并把裸 DSD（3-in-14 / 3-in-16）轨道提取为 DSF 文件。不处理 DST
//! 解码。

#![allow(dead_code)]

mod area_toc;
mod audio;
mod dsf;
mod extract;
mod master_toc;
mod reader;
mod tracklist;
mod types;

use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use md5::{Digest, Md5};

pub(crate) use extract::extract_track_to_dsf;
pub(crate) use reader::{is_sacd_iso, read_sacd_toc};
pub(crate) use types::{SacdArea, SacdAreaKind, SacdError, SacdFrameFormat, SacdToc, SacdTrack};

/// SACD 裸 DSD 轨道的采样率（DSD64，Hz）。
const SACD_SAMPLE_RATE_HZ: u32 = 2_822_400;

/// 确保指定 SACD 轨道已提取为缓存中的 DSF 文件，并返回其路径。
///
/// `area` 只接受 `2ch` 与 `mch`；`track_number` 是区内的轨号（从 1 开始）。
/// 缓存键由 ISO 路径、区、轨号、ISO 文件长度与修改时间构成，镜像被替换或
/// 修改后会重新提取。提取先写临时文件，成功后再改名到目标路径，中断的提取
/// 不会留下被当作有效缓存的半截文件。
pub fn ensure_sacd_track_extracted(
    iso_path: String,
    area: String,
    track_number: u32,
    cache_root: String,
) -> Result<String, String> {
    let kind = parse_area(&area)?;

    let toc = read_sacd_toc(Path::new(&iso_path)).map_err(|error| {
        let message = format!("解析 SACD 目录失败: {error}");
        log::warn!("{message}, iso={iso_path}");
        message
    })?;
    let selected_area = toc
        .areas
        .iter()
        .find(|candidate| candidate.kind == kind)
        .ok_or_else(|| {
            let message = format!("SACD 镜像中没有 {area} 区");
            log::warn!("{message}, iso={iso_path}");
            message
        })?;
    let track = selected_area
        .tracks
        .iter()
        .find(|track| u32::from(track.number) == track_number)
        .ok_or_else(|| {
            let message = format!("SACD {area} 区中没有轨道 {track_number}");
            log::warn!("{message}, iso={iso_path}");
            message
        })?;

    let metadata = fs::metadata(&iso_path).map_err(|error| {
        let message = format!("读取 SACD 镜像信息失败: {iso_path}: {error}");
        log::warn!("{message}");
        message
    })?;
    let modified_secs = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |duration| duration.as_secs());

    let cache_key = format!(
        "{iso_path}:{area}:{track_number}:{}:{modified_secs}",
        metadata.len()
    );
    let mut hasher = Md5::new();
    hasher.update(cache_key.as_bytes());
    let hash = format!("{:x}", hasher.finalize());

    let cache_dir = Path::new(&cache_root).join(&hash);
    fs::create_dir_all(&cache_dir).map_err(|error| {
        let message = format!("创建 SACD 缓存目录失败: {}: {error}", cache_dir.display());
        log::warn!("{message}");
        message
    })?;

    let target = cache_dir.join(format!("{area}-{track_number:02}.dsf"));
    let target_path = path_to_string(&target).map_err(|error| {
        log::warn!("{error}");
        error
    })?;

    match fs::metadata(&target) {
        Ok(existing) if existing.len() > 0 => {
            log::info!("命中 SACD 轨道缓存: {target_path}");
            return Ok(target_path);
        }
        Ok(_) => log::warn!("SACD 缓存文件长度为 0，重新提取: {target_path}"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => log::warn!("读取 SACD 缓存文件信息失败，重新提取: {target_path}: {error}"),
    }

    let temp = temporary_path(&target);
    log::info!(
        "开始提取 SACD 轨道到缓存: iso={iso_path}, area={area}, track={track_number}, 输出={target_path}"
    );

    if let Err(error) = extract_track_to_dsf(
        Path::new(&iso_path),
        selected_area.kind,
        track.start_lsn,
        track.length_lsn,
        selected_area.channel_count,
        SACD_SAMPLE_RATE_HZ,
        selected_area.frame_format,
        &temp,
    ) {
        let _ = fs::remove_file(&temp);
        log::warn!(
            "提取 SACD 轨道失败: iso={iso_path}, area={area}, track={track_number}: {error}"
        );
        return Err(format!("提取 SACD 轨道失败: {error}"));
    }

    if let Err(error) = replace_file(&temp, &target) {
        let _ = fs::remove_file(&temp);
        log::warn!("写入 SACD 缓存失败: {target_path}: {error}");
        return Err(format!("写入 SACD 缓存失败: {target_path}: {error}"));
    }

    log::info!(
        "SACD 轨道缓存完成: iso={iso_path}, area={area}, track={track_number}, 输出={target_path}"
    );
    Ok(target_path)
}

/// 把区标识转换为区类型；只接受 `2ch` 与 `mch`。
fn parse_area(area: &str) -> Result<SacdAreaKind, String> {
    match area {
        "2ch" => Ok(SacdAreaKind::TwoChannel),
        "mch" => Ok(SacdAreaKind::MultiChannel),
        other => Err(format!("unsupported sacd area: {other}")),
    }
}

/// 把路径转换为 UTF-8 字符串。
fn path_to_string(path: &Path) -> Result<String, String> {
    path.to_str()
        .map(str::to_owned)
        .ok_or_else(|| format!("缓存路径无法转换为 UTF-8: {}", path.display()))
}

/// 构造与进程绑定的临时文件路径，避免多个进程同时提取时互相覆盖。
fn temporary_path(target: &Path) -> PathBuf {
    let mut name = target.as_os_str().to_os_string();
    name.push(format!(".{}.tmp", std::process::id()));
    PathBuf::from(name)
}

/// 把临时文件改名到目标路径。
///
/// Windows 的 `rename` 不覆盖已存在的目标，因此目标只剩 0 字节残留时先删除
/// 再改名；其他情况直接返回原错误。
fn replace_file(temp: &Path, target: &Path) -> Result<(), std::io::Error> {
    match fs::rename(temp, target) {
        Ok(()) => Ok(()),
        Err(error) => {
            let empty_target = fs::metadata(target)
                .map(|metadata| metadata.len() == 0)
                .unwrap_or(false);
            if !empty_target {
                return Err(error);
            }
            fs::remove_file(target)?;
            fs::rename(temp, target)
        }
    }
}

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

    /// 可提取测试镜像中首轨的起始 LSN。
    const EXTRACT_TRACK_LSN: usize = 600;
    /// 可提取测试镜像中首轨占用的 LSN 数。
    const EXTRACT_TRACK_LENGTH_LSN: u32 = 2;
    /// 单扇区音频负载：2048 - 1 字节扇区头 - 2 字节包信息 - 3 字节帧信息。
    const AUDIO_PAYLOAD_SIZE: usize = PLAIN_SECTOR_SIZE - 6;

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

    fn unique_temp_dir() -> PathBuf {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let sequence = COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "pure_music_sacd_cache_{}_{}_{}",
            std::process::id(),
            nanos,
            sequence
        ))
    }

    /// 测试结束后自动删除的临时缓存目录。
    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn unused() -> Self {
            Self {
                path: unique_temp_dir(),
            }
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
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

    /// 构造可提取的最小镜像：1 个 2CH 区、2 轨、裸 DSD，首轨从 LSN 600 起占 2 个扇区。
    fn extractable_image() -> Vec<u8> {
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
            (0, 0, 0),
            EXTRACT_TRACK_LSN as u32,
            EXTRACT_TRACK_LSN as u32 + EXTRACT_TRACK_LENGTH_LSN * 2,
        );
        write_track_list_1(
            image.sector_mut(AREA_TOC_LSN + 1),
            &[
                EXTRACT_TRACK_LSN as u32,
                EXTRACT_TRACK_LSN as u32 + EXTRACT_TRACK_LENGTH_LSN,
            ],
            &[EXTRACT_TRACK_LENGTH_LSN, 1],
        );
        write_track_list_2(
            image.sector_mut(AREA_TOC_LSN + 2),
            &[(0, 0, 0), (0, 1, 0)],
            &[(0, 0, 1), (0, 0, 1)],
        );
        for index in 0..EXTRACT_TRACK_LENGTH_LSN as usize {
            let payload = vec![0xA5u8; AUDIO_PAYLOAD_SIZE];
            write_audio_sector(
                image.sector_mut(EXTRACT_TRACK_LSN + index),
                &payload,
                index == 0,
            );
        }
        image.into_data()
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

    #[test]
    fn ensure_sacd_track_extracted_rejects_unsupported_area() {
        let iso = TempImage::create(&minimal_image(false));
        let cache = TempDir::unused();

        let result = ensure_sacd_track_extracted(
            iso.path.to_string_lossy().into_owned(),
            "3ch".to_string(),
            1,
            cache.path.to_string_lossy().into_owned(),
        );

        let message = result.expect_err("不支持的区应返回错误");
        assert!(
            message.contains("unsupported sacd area"),
            "错误信息应说明区不支持: {message}"
        );
    }

    #[test]
    fn ensure_sacd_track_extracted_rejects_non_sacd_image() {
        let iso = TempImage::create(&vec![0u8; PLAIN_SECTOR_SIZE * 8]);
        let cache = TempDir::unused();

        let result = ensure_sacd_track_extracted(
            iso.path.to_string_lossy().into_owned(),
            "2ch".to_string(),
            1,
            cache.path.to_string_lossy().into_owned(),
        );

        assert!(result.is_err(), "非 SACD 文件应返回错误而不 panic");
    }

    #[test]
    fn ensure_sacd_track_extracted_rejects_missing_iso() {
        let iso_path = unique_temp_path();
        assert!(!iso_path.exists());
        let cache = TempDir::unused();

        let result = ensure_sacd_track_extracted(
            iso_path.to_string_lossy().into_owned(),
            "2ch".to_string(),
            1,
            cache.path.to_string_lossy().into_owned(),
        );

        assert!(result.is_err(), "不存在的镜像应返回错误而不 panic");
    }

    #[test]
    fn ensure_sacd_track_extracted_rejects_missing_area_and_track() {
        let iso = TempImage::create(&extractable_image());
        let cache = TempDir::unused();
        let iso_path = iso.path.to_string_lossy().into_owned();
        let cache_path = cache.path.to_string_lossy().into_owned();

        assert!(
            ensure_sacd_track_extracted(iso_path.clone(), "mch".to_string(), 1, cache_path.clone())
                .is_err(),
            "镜像没有多声道区时应返回错误"
        );
        assert!(
            ensure_sacd_track_extracted(iso_path, "2ch".to_string(), 9, cache_path).is_err(),
            "不存在的轨号应返回错误"
        );
    }

    #[test]
    fn ensure_sacd_track_extracted_writes_and_reuses_cache() {
        let iso = TempImage::create(&extractable_image());
        let cache = TempDir::unused();
        let iso_path = iso.path.to_string_lossy().into_owned();
        let cache_path = cache.path.to_string_lossy().into_owned();

        let first = ensure_sacd_track_extracted(
            iso_path.clone(),
            "2ch".to_string(),
            1,
            cache_path.clone(),
        )
        .expect("首次调用应提取轨道");

        let first_path = PathBuf::from(&first);
        assert!(first_path.is_file(), "首次调用后缓存文件应存在");
        let bytes = fs::read(&first_path).expect("读取缓存 DSF");
        assert!(!bytes.is_empty(), "缓存 DSF 不应为空");
        assert_eq!(&bytes[0..4], b"DSD ", "缓存文件应为 DSF 格式");
        assert!(first.ends_with("2ch-01.dsf"), "缓存文件名应为 2ch-01.dsf");

        let second = ensure_sacd_track_extracted(iso_path, "2ch".to_string(), 1, cache_path)
            .expect("第二次调用应命中缓存");

        assert_eq!(first, second, "缓存命中应返回同一路径");
        assert!(first_path.is_file(), "缓存命中后文件仍应存在");
    }
}
