//! 流式数据源的单元测试。
//!
//! 复用 `sacd::tests` 与 `sacd::extract::tests` 的镜像构造 helper，覆盖直解
//! 与提取的一致性、seek 定位、会话回收、实时 PCM 与文件转换的等价性。

use std::ffi::c_void;
use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use rdsd2pcm::{DitherType, FilterType, StreamingPcm};

use super::super::dsf::DsfWriter;
use super::super::extract::extract_track_to_dsf;
use super::super::extract::tests::{write_dst_audio_sector, DST_DSD_FIXTURE, DST_FIXTURE};
use super::super::tests::{
    extractable_image, write_area_toc, write_audio_sector, write_master_toc, write_track_list_1,
    write_track_list_2, TempDir, TempImage, AREA_TOC_LSN, AREA_TOC_SECTORS, MASTER_TOC_LSN,
    PLAIN_SECTOR_SIZE,
};
use super::super::types::SacdAreaKind;
use super::super::{ensure_sacd_track_extracted, SacdStreamDescriptor, SACD_SAMPLE_RATE_HZ};
use super::layout;
use super::{open_stream, registered_session_exists};

/// 多帧镜像中每帧占用的扇区数。
const FRAME_SECTORS: usize = 5;

/// 多帧镜像中每扇区的音频负载：前 4 个扇区满负载，最后 1 个扇区补齐到一帧。
const FRAME_FULL_PAYLOAD: usize = 2_042;
const FRAME_TAIL_PAYLOAD: usize = 1_240;

/// 多帧镜像中首轨的起始 LSN。
const FRAME_TRACK_START_LSN: usize = 600;

/// 取镜像中的某个逻辑扇区切片。
fn sector_mut(image: &mut [u8], lsn: usize) -> &mut [u8] {
    let start = lsn * PLAIN_SECTOR_SIZE;
    &mut image[start..start + PLAIN_SECTOR_SIZE]
}

/// 构造一个真实帧率的多帧裸 DSD 镜像。
///
/// 每帧 5 个扇区，音频负载合计 4 * 2042 + 1240 = 9408 字节，正好是 DSD64
/// 立体声一帧的字节数（每通道 4704）。第 1 个扇区的包带帧起点标志，与真实
/// 镜像的帧结构一致，便于验证 seek 的帧定位。
fn framed_image(frames: u32) -> Vec<u8> {
    let length_lsn = frames as usize * FRAME_SECTORS;
    let total_sectors = FRAME_TRACK_START_LSN + length_lsn + 8;
    let mut image = vec![0u8; total_sectors * PLAIN_SECTOR_SIZE];

    write_master_toc(
        sector_mut(&mut image, MASTER_TOC_LSN),
        AREA_TOC_LSN as u32,
        0,
        AREA_TOC_SECTORS,
        0,
        0,
        0,
    );
    write_area_toc(
        sector_mut(&mut image, AREA_TOC_LSN),
        b"TWOCHTOC",
        2,
        1,
        2,
        (0, 0, 0),
        FRAME_TRACK_START_LSN as u32,
        (FRAME_TRACK_START_LSN + length_lsn) as u32,
    );
    write_track_list_1(
        sector_mut(&mut image, AREA_TOC_LSN + 1),
        &[FRAME_TRACK_START_LSN as u32],
        &[length_lsn as u32],
    );
    write_track_list_2(
        sector_mut(&mut image, AREA_TOC_LSN + 2),
        &[(0, 0, 0)],
        &[(0, 0, frames as u8)],
    );

    for frame in 0..frames as usize {
        for index in 0..FRAME_SECTORS {
            let lsn = FRAME_TRACK_START_LSN + frame * FRAME_SECTORS + index;
            let payload_len = if index + 1 < FRAME_SECTORS {
                FRAME_FULL_PAYLOAD
            } else {
                FRAME_TAIL_PAYLOAD
            };
            let payload: Vec<u8> = (0..payload_len)
                .map(|byte| ((frame * 31 + index * 7 + byte) % 251) as u8)
                .collect();
            write_audio_sector(sector_mut(&mut image, lsn), &payload, index == 0);
        }
    }

    image
}

/// 构造 DST 镜像：每帧占一个扇区，帧格式为 DST。
fn dst_image_frames(frames: u32) -> Vec<u8> {
    let length_lsn = frames as usize;
    let total_sectors = FRAME_TRACK_START_LSN + length_lsn + 8;
    let mut image = vec![0u8; total_sectors * PLAIN_SECTOR_SIZE];

    write_master_toc(
        sector_mut(&mut image, MASTER_TOC_LSN),
        AREA_TOC_LSN as u32,
        0,
        AREA_TOC_SECTORS,
        0,
        0,
        0,
    );
    write_area_toc(
        sector_mut(&mut image, AREA_TOC_LSN),
        b"TWOCHTOC",
        2,
        1,
        0,
        (0, 0, 0),
        FRAME_TRACK_START_LSN as u32,
        (FRAME_TRACK_START_LSN + length_lsn) as u32,
    );
    write_track_list_1(
        sector_mut(&mut image, AREA_TOC_LSN + 1),
        &[FRAME_TRACK_START_LSN as u32],
        &[length_lsn as u32],
    );
    write_track_list_2(
        sector_mut(&mut image, AREA_TOC_LSN + 2),
        &[(0, 0, 0)],
        &[(0, 0, frames as u8)],
    );
    for frame in 0..frames as usize {
        write_dst_audio_sector(
            sector_mut(&mut image, FRAME_TRACK_START_LSN + frame),
            DST_FIXTURE,
            1,
        );
    }

    image
}

/// 构造单帧 DST 镜像。
fn dst_image() -> Vec<u8> {
    dst_image_frames(1)
}

fn read_proc(
    descriptor: &SacdStreamDescriptor,
) -> unsafe extern "system" fn(*mut c_void, u32, *mut c_void) -> u32 {
    // SAFETY: `procs.read` 是 `sacd_proc_read` 的地址，签名与 FILEREADPROC 一致。
    unsafe { std::mem::transmute(descriptor.procs.read) }
}

fn seek_proc(descriptor: &SacdStreamDescriptor) -> unsafe extern "system" fn(u64, *mut c_void) -> i32 {
    // SAFETY: `procs.seek` 是 `sacd_proc_seek` 的地址，签名与 FILESEEKPROC 一致。
    unsafe { std::mem::transmute(descriptor.procs.seek) }
}

fn length_proc(descriptor: &SacdStreamDescriptor) -> unsafe extern "system" fn(*mut c_void) -> u64 {
    // SAFETY: `procs.length` 是 `sacd_proc_length` 的地址，签名与 FILELENPROC 一致。
    unsafe { std::mem::transmute(descriptor.procs.length) }
}

fn close_proc(descriptor: &SacdStreamDescriptor) -> unsafe extern "system" fn(*mut c_void) {
    // SAFETY: `procs.close` 是 `sacd_proc_close` 的地址，签名与 FILECLOSEPROC 一致。
    unsafe { std::mem::transmute(descriptor.procs.close) }
}

fn stream_read(descriptor: &SacdStreamDescriptor, buffer: &mut [u8]) -> u32 {
    let read = read_proc(descriptor);
    // SAFETY: 缓冲区与 user 指针由本测试保证有效。
    unsafe {
        read(
            buffer.as_mut_ptr() as *mut c_void,
            buffer.len() as u32,
            descriptor.user as *mut c_void,
        )
    }
}

fn stream_seek(descriptor: &SacdStreamDescriptor, offset: u64) -> bool {
    let seek = seek_proc(descriptor);
    // SAFETY: user 指针由本测试保证有效。
    unsafe { seek(offset, descriptor.user as *mut c_void) == 1 }
}

fn stream_length(descriptor: &SacdStreamDescriptor) -> u64 {
    let length = length_proc(descriptor);
    // SAFETY: user 指针由本测试保证有效。
    unsafe { length(descriptor.user as *mut c_void) }
}

fn stream_close(descriptor: &SacdStreamDescriptor) {
    let close = close_proc(descriptor);
    // SAFETY: user 指针由本测试保证有效，close 之后不再使用。
    unsafe { close(descriptor.user as *mut c_void) }
}

/// 读完整条流并去掉虚拟文件头。
fn read_all_data(descriptor: &SacdStreamDescriptor, header_len: usize) -> Vec<u8> {
    let mut all = Vec::new();
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let written = stream_read(descriptor, &mut buffer);
        if written == 0 {
            break;
        }
        all.extend_from_slice(&buffer[..written as usize]);
        assert!(
            all.len() <= 128 * 1024 * 1024,
            "读取量超过 128 MiB，疑似读取循环未终止"
        );
    }
    if all.len() < header_len {
        return Vec::new();
    }
    all.split_off(header_len)
}

/// 16 位样本的平均绝对差，用于容忍 TPDF 抖动带来的 1 LSB 差异。
fn mean_abs_diff(left: &[u8], right: &[u8]) -> f64 {
    let len = left.len().min(right.len());
    if len < 2 {
        return f64::MAX;
    }
    let mut sum = 0.0f64;
    let mut count = 0usize;
    let mut index = 0usize;
    while index + 1 < len {
        let a = i16::from_le_bytes([left[index], left[index + 1]]) as f64;
        let b = i16::from_le_bytes([right[index], right[index + 1]]) as f64;
        sum += (a - b).abs();
        count += 1;
        index += 2;
    }
    if count == 0 {
        f64::MAX
    } else {
        sum / count as f64
    }
}

/// 读取 24 位小端样本并做符号扩展。
fn read_i24(bytes: &[u8]) -> i32 {
    let raw = i32::from(bytes[0]) | (i32::from(bytes[1]) << 8) | (i32::from(bytes[2]) << 16);
    if raw & 0x0080_0000 != 0 {
        raw - 0x0100_0000
    } else {
        raw
    }
}

/// 构造仅用于驱动 `StreamSession` 状态机的元数据。
fn test_meta() -> super::session::SessionMeta {
    super::session::SessionMeta {
        iso_path: "test.iso".to_string(),
        area: "2ch".to_string(),
        track_number: 1,
        mode: "dsd".to_string(),
        channels: 2,
        sample_rate: SACD_SAMPLE_RATE_HZ,
        bit_depth: 1,
        length: 1_000_000,
        duration_ms: 1_000,
        header_len: 92,
        buffer_target: 65_536,
        buffer_limit: 1_048_576,
        bytes_per_second: 705_600,
    }
}

/// 轮询等待某个条件成立，超时则让测试失败。
fn wait_until(mut predicate: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(2);
    while !predicate() {
        assert!(Instant::now() < deadline, "等待条件超时");
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn open_dsd(iso_path: &str) -> SacdStreamDescriptor {
    open_stream(
        iso_path.to_string(),
        "2ch".to_string(),
        1,
        "dsd".to_string(),
        0,
        0,
    )
    .expect("打开直解流")
}

fn open_pcm(iso_path: &str, sample_rate: u32, bit_depth: u16) -> SacdStreamDescriptor {
    open_stream(
        iso_path.to_string(),
        "2ch".to_string(),
        1,
        "pcm".to_string(),
        sample_rate,
        bit_depth,
    )
    .expect("打开实时 PCM 流")
}

#[test]
fn dsd_virtual_stream_matches_extracted_dsf() {
    let iso = TempImage::create(&extractable_image());
    let cache = TempDir::unused();
    fs::create_dir_all(&cache.path).expect("创建缓存目录");
    let iso_path = iso.path.to_string_lossy().into_owned();

    let dsf_path = ensure_sacd_track_extracted(
        iso_path.clone(),
        "2ch".to_string(),
        1,
        cache.path.to_string_lossy().into_owned(),
    )
    .expect("提取参考 DSF");
    let dsf_bytes = fs::read(&dsf_path).expect("读取参考 DSF");
    let reference_data = &dsf_bytes[92..];

    let descriptor = open_dsd(&iso_path);
    let streamed = read_all_data(&descriptor, descriptor.header_len);
    stream_close(&descriptor);

    assert_eq!(
        streamed, reference_data,
        "直解字节应与提取的 DSF data 区逐字节一致"
    );
}

#[test]
fn dsd_header_fields_match_layout() {
    let iso = TempImage::create(&framed_image(24));
    let cache = TempDir::unused();
    fs::create_dir_all(&cache.path).expect("创建缓存目录");
    let iso_path = iso.path.to_string_lossy().into_owned();

    // 参考头部来自现有文件提取路径，避免用 layout 自证。
    let dsf_path = ensure_sacd_track_extracted(
        iso_path.clone(),
        "2ch".to_string(),
        1,
        cache.path.to_string_lossy().into_owned(),
    )
    .expect("提取参考 DSF");
    let dsf_bytes = fs::read(&dsf_path).expect("读取参考 DSF");
    let reference_header = &dsf_bytes[..92];

    let descriptor = open_dsd(&iso_path);
    let mut header = vec![0u8; descriptor.header_len];
    let written = stream_read(&descriptor, &mut header) as usize;
    stream_close(&descriptor);

    assert_eq!(written, descriptor.header_len, "首次读取应恰好取完虚拟头");
    assert_eq!(
        header.as_slice(),
        reference_header,
        "虚拟 DSF 头应与提取产物的头逐字段一致"
    );
}

/// 直解流的真实产出字节数（含 92 字节头）必须等于描述结构的虚拟长度。
#[test]
fn dsd_stream_length_matches_descriptor() {
    let iso = TempImage::create(&framed_image(24));
    let iso_path = iso.path.to_string_lossy().into_owned();
    let descriptor = open_dsd(&iso_path);

    let mut all = Vec::new();
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let written = stream_read(&descriptor, &mut buffer);
        if written == 0 {
            break;
        }
        all.extend_from_slice(&buffer[..written as usize]);
        assert!(all.len() <= 128 * 1024 * 1024, "读取量超过 128 MiB");
    }
    let length = descriptor.length;
    stream_close(&descriptor);

    assert_eq!(
        all.len(),
        length,
        "直解产出 {all_len} 字节应与虚拟长度 {length} 一致",
        all_len = all.len()
    );
}

/// PCM 流的真实产出与虚拟长度最多差一个 4096 字节块对应的 PCM 数据。
///
/// 虚拟长度按 duration 估算，而流式转换只处理完整的 4096 字节 DSD 块，
/// 轨道尾部不足一块的余量不会产出 PCM，因此允许一个块的差值；BASS 读到
/// 真实 EOF 即停止，不会补齐静音。
#[test]
fn pcm_stream_length_matches_descriptor() {
    let iso = TempImage::create(&framed_image(60));
    let iso_path = iso.path.to_string_lossy().into_owned();
    let descriptor = open_pcm(&iso_path, 44_100, 16);

    let mut all = Vec::new();
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let written = stream_read(&descriptor, &mut buffer);
        if written == 0 {
            break;
        }
        all.extend_from_slice(&buffer[..written as usize]);
        assert!(all.len() <= 128 * 1024 * 1024, "读取量超过 128 MiB");
    }
    let length = descriptor.length;
    stream_close(&descriptor);

    // flush 处理尾部不足一块的残余后，实际产出与虚拟长度只差不足一帧。
    let bytes_per_sample = 2usize;
    let channels = 2usize;
    let frame_bytes = channels * bytes_per_sample;
    let difference = all.len().abs_diff(length);
    assert!(
        difference <= frame_bytes,
        "实际产出 {} 字节与虚拟长度 {length} 的差值 {difference} 应小于一帧对应的 {frame_bytes} 字节",
        all.len()
    );
}

#[test]
fn dsd_seek_returns_tail_bytes() {
    let iso = TempImage::create(&framed_image(24));
    let iso_path = iso.path.to_string_lossy().into_owned();
    let descriptor = open_dsd(&iso_path);

    let full = read_all_data(&descriptor, descriptor.header_len);
    assert!(!full.is_empty(), "顺序读取应产出数据");

    let target_data = full.len() as u64 * 60 / 100;
    let target_offset = descriptor.header_len as u64 + target_data;
    assert!(stream_seek(&descriptor, target_offset), "seek 应成功");

    let mut tail = vec![0u8; 8_192];
    let written = stream_read(&descriptor, &mut tail) as usize;
    stream_close(&descriptor);
    assert!(written > 0, "seek 后读取应产出数据");

    let start = target_data as usize;
    assert_eq!(
        &tail[..written],
        &full[start..start + written],
        "seek 后的字节应与从头读取的对应位置一致"
    );
}

#[test]
fn dst_virtual_stream_matches_extracted_dsf() {
    let iso = TempImage::create(&dst_image());
    let temp = TempDir::unused();
    fs::create_dir_all(&temp.path).expect("创建临时目录");
    let iso_path = iso.path.to_string_lossy().into_owned();

    let dsf_path = temp.path.join("dst.dsf");
    extract_track_to_dsf(
        Path::new(&iso_path),
        SacdAreaKind::TwoChannel,
        FRAME_TRACK_START_LSN as u32,
        1,
        2,
        SACD_SAMPLE_RATE_HZ,
        super::super::types::SacdFrameFormat::Dst,
        &dsf_path,
    )
    .expect("提取参考 DST 轨道");
    let dsf_bytes = fs::read(&dsf_path).expect("读取参考 DSF");

    let descriptor = open_dsd(&iso_path);
    let streamed = read_all_data(&descriptor, descriptor.header_len);
    stream_close(&descriptor);

    assert_eq!(
        streamed,
        &dsf_bytes[92..],
        "DST 直解字节应与提取的 DSF data 区逐字节一致"
    );
}

#[test]
fn dst_seek_lands_on_frame_start() {
    let iso = TempImage::create(&dst_image_frames(4));
    let iso_path = iso.path.to_string_lossy().into_owned();
    let descriptor = open_dsd(&iso_path);

    let full = read_all_data(&descriptor, descriptor.header_len);
    assert_eq!(full.len(), 40_960, "4 帧 DST 应对齐为 10 个 4096 字节块");

    // 目标落在第 3 个块起点，位于第 2 帧的块内，必须回到帧起点重解再丢弃。
    let target_data = 20_480u64;
    assert!(
        stream_seek(&descriptor, descriptor.header_len as u64 + target_data),
        "DST seek 应成功"
    );
    let mut tail = vec![0u8; 8_192];
    let written = stream_read(&descriptor, &mut tail) as usize;
    stream_close(&descriptor);

    assert!(written > 0, "DST seek 后应能继续解码");
    assert_eq!(
        &tail[..written],
        &full[target_data as usize..target_data as usize + written],
        "DST seek 后的字节应与从头读取的对应位置一致"
    );
}

#[test]
fn length_matches_duration_estimate() {
    let iso = TempImage::create(&framed_image(24));
    let iso_path = iso.path.to_string_lossy().into_owned();
    let descriptor = open_dsd(&iso_path);
    let length = stream_length(&descriptor);
    stream_close(&descriptor);

    let track = super::resolve_track(&iso_path, "2ch", 1).expect("解析轨道");
    let data_bytes = layout::dsf_data_bytes(track.duration_ms, track.channels, track.sample_rate);
    let expected = layout::DSF_HEADER_LEN + data_bytes;
    assert_eq!(length, expected, "虚拟长度应等于头长度加估算 data 长度");
    assert!(length > 0, "length 回调不得返回 0");
}

#[test]
fn session_close_releases_without_leak() {
    let iso = TempImage::create(&extractable_image());
    let iso_path = iso.path.to_string_lossy().into_owned();

    for _ in 0..3 {
        let descriptor = open_dsd(&iso_path);
        let user = descriptor.user;
        assert!(
            registered_session_exists(user),
            "打开后会话应登记在会话表中"
        );

        stream_close(&descriptor);
        let deadline = Instant::now() + Duration::from_secs(5);
        while registered_session_exists(user) {
            assert!(
                Instant::now() < deadline,
                "close 后会话应在超时前从会话表移除"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

#[test]
fn pcm_push_matches_file_conversion() {
    let temp = TempDir::unused();
    fs::create_dir_all(&temp.path).expect("创建临时目录");
    let dsf_path = temp.path.join("fixture.dsf");
    let per_channel = DST_DSD_FIXTURE.len() / 2;

    let mut writer = DsfWriter::create(
        &dsf_path,
        2,
        SACD_SAMPLE_RATE_HZ,
        (per_channel * 8) as u64,
        0,
    )
    .expect("创建参考 DSF");
    writer
        .write_samples(DST_DSD_FIXTURE)
        .expect("写入参考 DSF");
    writer.finalize().expect("完成参考 DSF");

    let wav_path = super::super::pcm::ensure_pcm_cached(&dsf_path, 44_100, 16)
        .expect("文件路径转换为 WAV");
    let wav_bytes = fs::read(&wav_path).expect("读取参考 WAV");
    let wav_data = &wav_bytes[44..];

    let mut converter = StreamingPcm::new(
        2,
        SACD_SAMPLE_RATE_HZ,
        16,
        44_100,
        DitherType::TPDF,
        FilterType::Equiripple,
    )
    .expect("创建流式转换器");

    // 与文件转换一致：只喂有效字节（每通道 4704），尾部不足一块的残余由
    // flush 处理，不做人为的块补齐。
    let mut pcm = converter.push(DST_DSD_FIXTURE).expect("流式转换");
    pcm.extend(converter.flush().expect("冲刷转换器"));

    assert_eq!(
        pcm.len(),
        wav_data.len(),
        "流式 PCM 长度应与文件转换的 data 长度一致"
    );
    let max_diff = pcm
        .chunks_exact(2)
        .zip(wav_data.chunks_exact(2))
        .map(|(left, right)| {
            let a = i16::from_le_bytes([left[0], left[1]]) as i32;
            let b = i16::from_le_bytes([right[0], right[1]]) as i32;
            (a - b).abs()
        })
        .max()
        .unwrap_or(0);
    // 两条路径各自持有独立的 TPDF 抖动实例，随机序列不同；两个独立三角分布
    // 之差的最大幅度为 2 LSB。超过 2 说明滤波、抽取或缩放路径不一致，而不是抖动。
    assert!(
        max_diff <= 2,
        "流式与文件转换各用独立 TPDF 抖动，最大差应为 2 LSB；超过即说明滤波或缩放路径不一致，实际 {max_diff}"
    );
}

/// 192kHz / 24bit 走有理重采样（LM）路径，必须与文件转换保持一致。
#[test]
fn pcm_192k24_matches_file_conversion() {
    let temp = TempDir::unused();
    fs::create_dir_all(&temp.path).expect("创建临时目录");
    let dsf_path = temp.path.join("fixture-192.dsf");
    let per_channel = DST_DSD_FIXTURE.len() / 2;

    let mut writer = DsfWriter::create(
        &dsf_path,
        2,
        SACD_SAMPLE_RATE_HZ,
        (per_channel * 8) as u64,
        0,
    )
    .expect("创建参考 DSF");
    writer
        .write_samples(DST_DSD_FIXTURE)
        .expect("写入参考 DSF");
    writer.finalize().expect("完成参考 DSF");

    let wav_path = super::super::pcm::ensure_pcm_cached(&dsf_path, 192_000, 24)
        .expect("文件路径转换为 192k/24 WAV");
    let wav_bytes = fs::read(&wav_path).expect("读取参考 WAV");
    let wav_data = &wav_bytes[44..];

    let mut converter = StreamingPcm::new(
        2,
        SACD_SAMPLE_RATE_HZ,
        24,
        192_000,
        DitherType::TPDF,
        FilterType::Equiripple,
    )
    .expect("创建 192k 流式转换器");

    // 同样只喂有效字节，尾部不足一块的残余交给 flush。
    let mut pcm = converter.push(DST_DSD_FIXTURE).expect("流式转换");
    pcm.extend(converter.flush().expect("冲刷转换器"));

    assert_eq!(
        pcm.len(),
        wav_data.len(),
        "192k/24 的输出长度应与文件转换一致"
    );
    let max_diff = pcm
        .chunks_exact(3)
        .zip(wav_data.chunks_exact(3))
        .map(|(left, right)| (read_i24(left) - read_i24(right)).abs())
        .max()
        .unwrap_or(0);
    // 同上：两条路径各用独立的 TPDF 抖动实例，24-bit 下最大差为 2 LSB。
    assert!(
        max_diff <= 2,
        "192k/24 两条路径各用独立 TPDF 抖动，最大差应为 2 LSB；超过即说明 LM 滤波或 24 位缩放路径不一致，实际 {max_diff}"
    );
}

/// 非对齐的 push 长度不得打乱通道轮转：分段喂入与一次性喂入必须逐字节相同。
///
/// 8193 字节一次喂入时，第 8192 字节处会触发一次块处理，此时每通道还多出
/// 1 个字节；修复前这些余量被 `clear()` 丢弃，通道相位从此错位。
#[test]
fn streaming_pcm_handles_unaligned_push_lengths() {
    let mut input = Vec::with_capacity(DST_DSD_FIXTURE.len() * 4);
    for _ in 0..4 {
        input.extend_from_slice(DST_DSD_FIXTURE);
    }

    let create = || {
        StreamingPcm::new(
            2,
            SACD_SAMPLE_RATE_HZ,
            16,
            44_100,
            DitherType::None,
            FilterType::Equiripple,
        )
        .expect("创建流式转换器")
    };

    // 一次性喂入作为基准；DitherType::None 让输出确定，可以比到字节。
    let mut whole = create();
    let mut expected = whole.push(&input).expect("一次性转换");
    expected.extend(whole.flush().expect("冲刷转换器"));
    assert!(!expected.is_empty(), "基准输出不应为空");

    let sizes = [8_193usize, 4_097, 1_234, 1, 8_192, 3];
    let mut chunked = create();
    let mut observed = Vec::new();
    let mut offset = 0usize;
    let mut index = 0usize;
    while offset < input.len() {
        let size = sizes[index % sizes.len()].min(input.len() - offset);
        observed.extend(
            chunked
                .push(&input[offset..offset + size])
                .expect("分段转换"),
        );
        offset += size;
        index += 1;
    }
    observed.extend(chunked.flush().expect("冲刷转换器"));

    assert_eq!(
        observed, expected,
        "非对齐分段的 PCM 输出应与一次性转换逐字节一致"
    );

    // reset 之后重新喂入同一段输入，应与新建实例完全一致。
    chunked.reset();
    let mut after_reset = chunked.push(&input).expect("重置后转换");
    after_reset.extend(chunked.flush().expect("冲刷转换器"));
    assert_eq!(
        after_reset, expected,
        "reset 后重新喂入应与新建实例逐字节一致"
    );
}

#[test]
fn pcm_seek_resets_filter_state() {
    let iso = TempImage::create(&framed_image(60));
    let iso_path = iso.path.to_string_lossy().into_owned();
    let descriptor = open_pcm(&iso_path, 44_100, 16);

    let full = read_all_data(&descriptor, descriptor.header_len);
    // 每秒 PCM 字节数：44100 帧 * 2 通道 * 2 字节。
    let bytes_per_second = 44_100usize * 4;
    assert!(
        full.len() > bytes_per_second / 2,
        "PCM 输出应超过 0.5 秒，实际 {} 字节",
        full.len()
    );

    let target_data = full.len() as u64 / 2;
    assert!(
        stream_seek(&descriptor, descriptor.header_len as u64 + target_data),
        "PCM seek 应成功"
    );
    let mut tail = vec![0u8; 4_096];
    let written = stream_read(&descriptor, &mut tail) as usize;
    stream_close(&descriptor);
    assert!(written > 0, "PCM seek 后应产出数据");

    let compare = written.min(512);
    let seek_slice = &tail[..compare];
    let head_end = full.len().min(compare.max(bytes_per_second));
    let head_diff = mean_abs_diff(&full[..head_end], seek_slice);

    let mut best_diff = f64::MAX;
    let mut best_offset = 0usize;
    let window_lo = target_data.saturating_sub(bytes_per_second as u64 / 5) as usize;
    let window_hi = (target_data + bytes_per_second as u64 / 5) as usize;
    let mut offset = window_lo;
    while offset + compare <= full.len() && offset <= window_hi {
        let diff = mean_abs_diff(&full[offset..offset + compare], seek_slice);
        if diff < best_diff {
            best_diff = diff;
            best_offset = offset;
        }
        offset += 16;
    }

    assert!(best_diff.is_finite(), "目标窗口内应有足够的 PCM 数据");
    assert!(
        best_diff < head_diff,
        "seek 后的内容应更接近目标位置而不是开头"
    );
    // 23 ms ≈ 44.1kHz 下一个 SACD 帧（1/75 秒）加一个块的余量。
    let tolerance = (bytes_per_second as i64) * 23 / 1_000;
    assert!(
        (best_offset as i64 - target_data as i64).abs() <= tolerance,
        "seek 后位置 {} 应在目标 {target_data} 的 ±23 ms 范围内",
        best_offset
    );
    let aligned_diff = mean_abs_diff(&full[best_offset..best_offset + compare], seek_slice);
    assert!(
        aligned_diff < 8.0,
        "seek 后首段应与顺序读取对齐，平均差 {aligned_diff}"
    );
}

#[test]
fn read_on_eof_returns_zero() {
    let iso = TempImage::create(&extractable_image());
    let iso_path = iso.path.to_string_lossy().into_owned();
    let descriptor = open_dsd(&iso_path);

    let data = read_all_data(&descriptor, descriptor.header_len);
    assert!(!data.is_empty(), "应读到轨道数据");

    let started = Instant::now();
    let mut buffer = vec![0u8; 4_096];
    let written = stream_read(&descriptor, &mut buffer);
    let elapsed = started.elapsed();
    stream_close(&descriptor);

    assert_eq!(written, 0, "真实 EOF 后 read 应返回 0");
    assert!(
        elapsed < Duration::from_millis(500),
        "EOF 后 read 不应阻塞，实际耗时 {elapsed:?}"
    );
}

/// 读到真实 EOF 后，预读线程必须继续存活，否则把进度条拖回开头时 seek 永远超时。
#[test]
fn seek_after_eof_restarts_reading() {
    let iso = TempImage::create(&extractable_image());
    let iso_path = iso.path.to_string_lossy().into_owned();
    let descriptor = open_dsd(&iso_path);

    let first = read_all_data(&descriptor, descriptor.header_len);
    assert!(!first.is_empty(), "首次读取应产出数据");

    // 此时已到真实 EOF；线程应仍在等待新的 seek 请求。
    assert!(stream_seek(&descriptor, 0), "EOF 后 seek 回 0 应成功");

    let second = read_all_data(&descriptor, descriptor.header_len);
    stream_close(&descriptor);

    assert!(!second.is_empty(), "seek 回 0 后应重新读到数据");
    assert_eq!(second, first, "EOF 后重新读取的字节应与首次一致");
}

/// 旧请求失败但已被新请求覆盖：不得把会话标记失败，也不得终止预读线程。
#[test]
fn apply_seek_result_keeps_latest_on_superseded_failure() {
    let mut inner = super::session::SessionInner::default();
    inner.pending_seek = Some(222);
    inner.seek_generation = 2;
    inner.applied_seek_generation = 0;
    inner.buffer.push_back(1);
    inner.buffered_bytes = 1;

    let terminate =
        super::session::apply_seek_result(&mut inner, 111, 1, &Err("旧的定位失败".to_string()));

    assert!(!terminate, "被覆盖的旧请求失败不应终止预读线程");
    assert!(inner.failed.is_none(), "不得把会话标记为失败");
    assert_eq!(inner.pending_seek, Some(222), "应保留最新请求");
    assert_eq!(inner.applied_seek_generation, 0, "不得推进应用序号");
}

/// 当前请求失败：设置 failed 与 eof，并终止预读线程。
#[test]
fn apply_seek_result_fails_current_request() {
    let mut inner = super::session::SessionInner::default();
    inner.pending_seek = Some(222);
    inner.seek_generation = 2;

    let terminate =
        super::session::apply_seek_result(&mut inner, 222, 2, &Err("定位失败".to_string()));

    assert!(terminate, "当前请求失败应终止预读线程");
    assert!(inner.failed.is_some(), "应把会话标记为失败");
    assert!(inner.eof, "失败后读取应立即结束");
    assert_eq!(inner.pending_seek, None, "应清掉已处理的请求");
}

/// 当前请求成功：清 pending、推进 applied 并记录位置。
#[test]
fn apply_seek_result_completes_current_request() {
    let mut inner = super::session::SessionInner::default();
    inner.pending_seek = Some(5_000);
    inner.seek_generation = 3;
    inner.applied_seek_generation = 2;

    let terminate = super::session::apply_seek_result(&mut inner, 5_000, 3, &Ok(()));

    assert!(!terminate, "成功不应终止预读线程");
    assert!(inner.failed.is_none());
    assert_eq!(inner.pending_seek, None);
    assert_eq!(inner.applied_seek_generation, 3);
    assert_eq!(inner.position, 5_000);
}

/// 连续两次 seek 时，被覆盖的旧请求必须返回失败，最新请求才算成功。
#[test]
fn concurrent_seek_keeps_latest_request() {
    let session = Arc::new(super::session::StreamSession::new(test_meta()));

    let first_session = Arc::clone(&session);
    let first = std::thread::spawn(move || first_session.seek(111));
    wait_until(|| session.lock_inner().pending_seek == Some(111));

    let second_session = Arc::clone(&session);
    let second = std::thread::spawn(move || second_session.seek(222));
    wait_until(|| session.lock_inner().pending_seek == Some(222));

    assert!(
        !first.join().expect("首个 seek 线程不应 panic"),
        "被覆盖的 seek 不应报告成功"
    );

    // 应用最新请求：只有 generation 匹配的请求才算完成。
    let latest_generation = {
        let mut inner = session.lock_inner();
        let generation = inner.seek_generation;
        inner.applied_seek_generation = generation;
        inner.pending_seek = None;
        generation
    };
    session.cond.notify_all();

    assert!(
        second.join().expect("第二个 seek 线程不应 panic"),
        "最新一次 seek 应成功"
    );
    assert_eq!(
        session.lock_inner().applied_seek_generation,
        latest_generation,
        "应用序号应推进到最新请求"
    );
}

/// 会话停止后 seek 必须立即失败，不能假装成功。
#[test]
fn seek_returns_false_when_stopped() {
    let session = super::session::StreamSession::new(test_meta());
    session.request_stop();
    assert!(!session.seek(1_024), "停止后 seek 必须失败");
}

/// 生产失败后 seek 必须立即失败，不再等满超时。
#[test]
fn seek_returns_false_after_failure() {
    let session = super::session::StreamSession::new(test_meta());
    session.fail("模拟生产失败".to_string());
    assert!(!session.seek(2_048), "生产失败后 seek 必须立即失败");
}

/// `lookup_session` 返回的克隆在注册表移除后仍然可用，移除后再查找返回 `None`。
#[test]
fn lookup_session_keeps_arc_after_registry_removal() {
    let iso = TempImage::create(&extractable_image());
    let iso_path = iso.path.to_string_lossy().into_owned();
    let descriptor = open_dsd(&iso_path);
    let user = descriptor.user;

    let kept = super::lookup_session(user).expect("注册期间应能查到会话");
    assert!(super::registered_session_exists(user));

    let taken = super::take_registered_session(user).expect("移除应返回会话");
    assert!(!super::registered_session_exists(user));
    assert!(
        super::lookup_session(user).is_none(),
        "移除后不应再能查到会话"
    );

    // 回调持有的克隆不受移除影响，仍可读取元数据。
    assert_eq!(kept.meta.length, taken.meta.length);
    assert_eq!(kept.meta.track_number, 1);

    // 会话已被消费，close 回调只会记录未命中，不会重复释放。
    taken.request_stop();
    super::enqueue_reclaim(taken);
    drop(kept);
    stream_close(&descriptor);
}
