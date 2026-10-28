//! 内置读取器无法给出整轨源文件时长时的兜底探测。
//!
//! CUE 引用 `.tak`、`.tta` 等内置读取器不支持的整轨文件时，最后一轨会退化为零长度。
//! 本模块按「Windows 媒体属性 → 容器头部解析」的顺序补齐时长，并记录每次尝试的
//! 失败原因供上层诊断；调用方先执行内置读取器，再对本模块传入缺失时长。

use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::Path,
};

/// TAK 元数据块类型：流信息。
const TAK_METADATA_STREAMINFO: u8 = 1;
/// TAK 元数据块类型：元数据结束。
const TAK_METADATA_END: u8 = 0;
/// 单个 STREAMINFO 块的读取上限，实际块只有几十字节。
const TAK_MAX_STREAMINFO_BYTES: u64 = 1 << 16;
/// 元数据块扫描上限，避免损坏文件造成长时间循环。
const TAK_MAX_METADATA_BLOCKS: usize = 64;
/// TTA1 文件头固定长度。
const TTA_HEADER_BYTES: usize = 22;
/// TTA1 音频格式：无损 PCM。
const TTA_FORMAT_PCM: u16 = 1;

/// 单个 FILE 的时长探测结果，仅在本模块内累计，对外以元组返回。
#[derive(Debug, Default, PartialEq, Eq)]
struct DurationProbe {
    duration_ms: Option<u64>,
    attempts: Vec<String>,
}

/// 依次尝试 Windows 媒体属性与容器头部解析，任一成功即停止。
///
/// 返回 `(duration_ms, attempts)`：`attempts` 记录内置读取器与每次回退的失败原因，
/// 供上层诊断。`builtin_note` 描述内置读取器失败的原因；
/// `windows_probe` 与 `header_probe` 由调用方注入，测试可替换为桩。
pub(super) fn probe_container_duration_ms<W, H>(
    path: &Path,
    builtin_note: String,
    windows_probe: W,
    header_probe: H,
) -> (Option<u64>, Vec<String>)
where
    W: FnOnce(&Path) -> anyhow::Result<u64>,
    H: FnOnce(&Path) -> Result<u64, String>,
{
    let mut probe = DurationProbe {
        duration_ms: None,
        attempts: vec![builtin_note],
    };

    match windows_probe(path) {
        Ok(duration_ms) => {
            probe.duration_ms = Some(duration_ms);
            return (probe.duration_ms, probe.attempts);
        }
        Err(error) => probe
            .attempts
            .push(format!("windows media properties: {error:#}")),
    }

    match header_probe(path) {
        Ok(duration_ms) => probe.duration_ms = Some(duration_ms),
        Err(reason) => probe.attempts.push(reason),
    }

    (probe.duration_ms, probe.attempts)
}

/// 按扩展名解析容器头部的时长，单位毫秒。
pub(super) fn header_duration_ms(path: &Path) -> Result<u64, String> {
    let extension = path
        .extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| ext.to_ascii_lowercase());
    match extension.as_deref() {
        Some("tak") => tak_duration_ms(path),
        Some("tta") => tta_duration_ms(path),
        Some(other) => Err(format!("header fallback: no parser for .{other}")),
        None => Err("header fallback: file has no extension".to_string()),
    }
}

/// 读取 TTA1 固定 22 字节文件头并换算时长，分数字段全部小端。
///
/// 头布局：magic(4) + format(2) + channels(2) + bps(2) + sample_rate(4)
/// + data_length(4) + crc32(4)。时长按四舍五入取整毫秒，避免整除截断。
fn tta_duration_ms(path: &Path) -> Result<u64, String> {
    let mut file = File::open(path)
        .map_err(|error| format!("header fallback: TTA open failed: {error}"))?;
    let mut header = [0_u8; TTA_HEADER_BYTES];
    file.read_exact(&mut header).map_err(|error| {
        format!("header fallback: TTA header truncated (need {TTA_HEADER_BYTES} bytes): {error}")
    })?;

    let magic = [header[0], header[1], header[2], header[3]];
    if magic != *b"TTA1" {
        return Err("header fallback: TTA magic missing".to_string());
    }

    let format = u16::from_le_bytes([header[4], header[5]]);
    if format != TTA_FORMAT_PCM {
        return Err(format!("header fallback: TTA unsupported audio format {format}"));
    }

    let sample_rate = u32::from_le_bytes([header[10], header[11], header[12], header[13]]);
    if sample_rate == 0 {
        return Err("header fallback: TTA sample rate is zero".to_string());
    }

    let data_length = u32::from_le_bytes([header[14], header[15], header[16], header[17]]);
    if data_length == 0 {
        return Err("header fallback: TTA data length is zero".to_string());
    }

    let sample_rate = u64::from(sample_rate);
    let duration_ms = (u64::from(data_length) * 1000 + sample_rate / 2) / sample_rate;
    if duration_ms == 0 {
        return Err("header fallback: TTA duration rounds to zero milliseconds".to_string());
    }
    Ok(duration_ms)
}

/// 读取 TAK 的第一个 STREAMINFO 元数据块并换算时长。
fn tak_duration_ms(path: &Path) -> Result<u64, String> {
    let mut file = File::open(path)
        .map_err(|error| format!("header fallback: TAK open failed: {error}"))?;
    let file_len = file
        .metadata()
        .map_err(|error| format!("header fallback: TAK stat failed: {error}"))?
        .len();

    let mut magic = [0_u8; 4];
    file.read_exact(&mut magic)
        .map_err(|error| format!("header fallback: TAK read magic failed: {error}"))?;
    if magic != *b"tBaK" {
        return Err("header fallback: TAK magic missing".to_string());
    }

    let mut offset = magic.len() as u64;
    for _ in 0..TAK_MAX_METADATA_BLOCKS {
        let Some(end) = offset.checked_add(4) else {
            return Err("header fallback: TAK metadata offset overflow".to_string());
        };
        if end > file_len {
            return Err("header fallback: TAK metadata header truncated".to_string());
        }

        let mut header = [0_u8; 4];
        file.read_exact(&mut header)
            .map_err(|error| format!("header fallback: TAK read block header failed: {error}"))?;
        offset = end;

        let kind = header[0] & 0x7f;
        let size = u64::from(u32::from_le_bytes([header[1], header[2], header[3], 0]));
        if kind == TAK_METADATA_END {
            return Err("header fallback: TAK streaminfo absent before metadata end".to_string());
        }
        if size < 3 {
            return Err(format!("header fallback: TAK invalid metadata size {size}"));
        }
        let Some(block_end) = offset.checked_add(size) else {
            return Err("header fallback: TAK metadata size overflow".to_string());
        };
        if block_end > file_len {
            return Err("header fallback: TAK metadata block exceeds file length".to_string());
        }

        if kind == TAK_METADATA_STREAMINFO {
            if size > TAK_MAX_STREAMINFO_BYTES {
                return Err(format!(
                    "header fallback: TAK streaminfo block too large ({size} bytes)"
                ));
            }
            let data_len = (size - 3) as usize;
            let mut data = vec![0_u8; data_len];
            file.read_exact(&mut data)
                .map_err(|error| format!("header fallback: TAK read streaminfo failed: {error}"))?;
            let (samples, sample_rate) = parse_tak_streaminfo(&data)
                .ok_or_else(|| "header fallback: invalid TAK streaminfo".to_string())?;
            let duration_ms = samples.saturating_mul(1000) / u64::from(sample_rate);
            if duration_ms == 0 {
                return Err("header fallback: TAK streaminfo reports zero duration".to_string());
            }
            return Ok(duration_ms);
        }

        file.seek(SeekFrom::Current(size as i64))
            .map_err(|error| format!("header fallback: TAK skip metadata failed: {error}"))?;
        offset = block_end;
    }

    Err("header fallback: TAK metadata block scan limit reached".to_string())
}

/// 解析 TAK STREAMINFO 数据块（不含 3 字节 CRC），返回采样数与采样率。
fn parse_tak_streaminfo(data: &[u8]) -> Option<(u64, u32)> {
    let mut bits = LsbBits::new(data);
    bits.skip(6 + 4)?; // codec + profile
    bits.skip(4)?; // frame duration type
    let samples = bits.read(35)?;
    bits.skip(3)?; // data type
    let sample_rate = u32::try_from(bits.read(18)?).ok()?.checked_add(6000)?;
    bits.skip(5 + 4)?; // bps + channels
    if samples == 0 {
        return None;
    }
    Some((samples, sample_rate))
}

/// LSB-first 位读取器，按 TAK 的位序从字节流取字段。
struct LsbBits<'a> {
    data: &'a [u8],
    position: usize,
}

impl<'a> LsbBits<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, position: 0 }
    }

    fn read(&mut self, count: u32) -> Option<u64> {
        let end = self.position.checked_add(count as usize)?;
        if end > self.data.len().checked_mul(8)? {
            return None;
        }
        let mut value = 0_u64;
        for index in 0..count as usize {
            let position = self.position + index;
            let bit = (self.data[position / 8] >> (position % 8)) & 1;
            value |= u64::from(bit) << index;
        }
        self.position = end;
        Some(value)
    }

    fn skip(&mut self, count: u32) -> Option<()> {
        self.read(count).map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        path::{Path, PathBuf},
        sync::atomic::{AtomicU64, Ordering},
        time::{SystemTime, UNIX_EPOCH},
    };

    /// 按 LSB-first 顺序把若干位字段打包成字节。
    fn pack_lsb(fields: &[(u64, u32)]) -> Vec<u8> {
        let mut bytes: Vec<u8> = Vec::new();
        let mut position = 0_usize;
        for &(value, count) in fields {
            for index in 0..count as usize {
                if position % 8 == 0 {
                    bytes.push(0);
                }
                let bit = ((value >> index) & 1) as u8;
                bytes[position / 8] |= bit << (position % 8);
                position += 1;
            }
        }
        bytes
    }

    /// 构造 STREAMINFO 数据块，44100 Hz、733480 ms 对应 32_346_468 个采样。
    fn streaminfo_bytes(samples: u64, sample_rate: u32) -> Vec<u8> {
        pack_lsb(&[
            (2, 6),  // codec: mono/stereo
            (0, 4),  // profile
            (0, 4),  // frame duration type
            (samples, 35),
            (1, 3),  // data type
            (u64::from(sample_rate.saturating_sub(6000)), 18),
            (8, 5),  // bps - 8
            (1, 4),  // channels - 1
        ])
    }

    fn tak_bytes(samples: u64, sample_rate: u32) -> Vec<u8> {
        let streaminfo = streaminfo_bytes(samples, sample_rate);
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"tBaK");
        let size = (streaminfo.len() + 3) as u32;
        bytes.push(TAK_METADATA_STREAMINFO);
        bytes.extend_from_slice(&size.to_le_bytes()[..3]);
        bytes.extend_from_slice(&streaminfo);
        bytes.extend_from_slice(&[0, 0, 0]); // CRC，解析不校验
        bytes.push(TAK_METADATA_END);
        bytes.extend_from_slice(&[0, 0, 0]);
        bytes
    }

    struct TempFile(PathBuf);

    impl Drop for TempFile {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    /// 同进程内并行测试可能拿到相同纳秒时间戳，用计数器区分文件名。
    static TEMP_FILE_SERIAL: AtomicU64 = AtomicU64::new(0);

    fn temp_file(bytes: &[u8], extension: &str) -> TempFile {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|value| value.as_nanos())
            .unwrap_or(0);
        let serial = TEMP_FILE_SERIAL.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "pure_music_duration_probe_{}_{}_{}.{}",
            std::process::id(),
            nanos,
            serial,
            extension
        ));
        std::fs::write(&path, bytes).expect("write temp probe file");
        TempFile(path)
    }

    fn temp_tak(bytes: &[u8]) -> TempFile {
        temp_file(bytes, "tak")
    }

    fn temp_tta(bytes: &[u8]) -> TempFile {
        temp_file(bytes, "tta")
    }

    /// 构造 TTA1 22 字节文件头，各字段小端。
    fn tta_bytes(sample_rate: u32, data_length: u32) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(TTA_HEADER_BYTES);
        bytes.extend_from_slice(b"TTA1");
        bytes.extend_from_slice(&TTA_FORMAT_PCM.to_le_bytes());
        bytes.extend_from_slice(&2_u16.to_le_bytes()); // channels
        bytes.extend_from_slice(&16_u16.to_le_bytes()); // bits per sample
        bytes.extend_from_slice(&sample_rate.to_le_bytes());
        bytes.extend_from_slice(&data_length.to_le_bytes());
        bytes.extend_from_slice(&[0_u8; 4]); // CRC32，解析不校验
        bytes
    }

    #[test]
    fn parses_tak_streaminfo_samples_and_rate() {
        let data = streaminfo_bytes(32_346_468, 44_100);
        assert_eq!(parse_tak_streaminfo(&data), Some((32_346_468, 44_100)));
    }

    #[test]
    fn rejects_truncated_tak_streaminfo() {
        assert_eq!(parse_tak_streaminfo(&[0_u8; 4]), None);
    }

    #[test]
    fn tak_duration_includes_metadata_crc_in_block_size() {
        let file = temp_tak(&tak_bytes(32_346_468, 44_100));
        assert_eq!(header_duration_ms(&file.0), Ok(733_480));
    }

    #[test]
    fn header_duration_rejects_unsupported_extension() {
        let error =
            header_duration_ms(Path::new("album.flac")).expect_err("flac has no header probe");
        assert!(error.contains("no parser"));
    }

    #[test]
    fn header_duration_rejects_wrong_tak_magic() {
        let file = temp_tak(b"not a tak file at all");
        let error = header_duration_ms(&file.0).expect_err("wrong magic must fail");
        assert!(error.contains("magic"));
    }

    #[test]
    fn probe_prefers_windows_duration_without_reading_header() {
        let (duration_ms, attempts) = probe_container_duration_ms(
            Path::new("album.tak"),
            "built-in readers: unsupported".to_string(),
            |_| Ok(733_480),
            |_| panic!("header probe must not run when Windows probe succeeds"),
        );
        assert_eq!(duration_ms, Some(733_480));
        assert_eq!(attempts, vec!["built-in readers: unsupported"]);
    }

    #[test]
    fn probe_falls_back_to_header_when_windows_fails() {
        let (duration_ms, attempts) = probe_container_duration_ms(
            Path::new("album.tak"),
            "built-in readers: unsupported".to_string(),
            |_| Err(anyhow::anyhow!("no media property handler")),
            |_| Ok(700_000),
        );
        assert_eq!(duration_ms, Some(700_000));
        assert_eq!(attempts.len(), 2);
        assert!(attempts[1].contains("no media property handler"));
    }

    #[test]
    fn probe_reports_every_attempt_when_all_sources_fail() {
        let (duration_ms, attempts) = probe_container_duration_ms(
            Path::new("album.tak"),
            "built-in readers: unsupported".to_string(),
            |_| Err(anyhow::anyhow!("windows failed")),
            |_| Err("header fallback: invalid TAK streaminfo".to_string()),
        );
        assert_eq!(duration_ms, None);
        assert_eq!(attempts.len(), 3);
        assert!(attempts[0].contains("unsupported"));
        assert!(attempts[1].contains("windows failed"));
        assert!(attempts[2].contains("invalid TAK streaminfo"));
    }

    #[test]
    fn tta_header_duration_uses_data_length_and_sample_rate() {
        let bytes = tta_bytes(44_100, 32_346_468);
        assert_eq!(bytes.len(), TTA_HEADER_BYTES);
        let file = temp_tta(&bytes);
        assert_eq!(header_duration_ms(&file.0), Ok(733_480));
    }

    #[test]
    fn tta_header_duration_keeps_large_data_length_in_u64() {
        let file = temp_tta(&tta_bytes(1, u32::MAX));
        assert_eq!(header_duration_ms(&file.0), Ok(4_294_967_295_000));
    }

    #[test]
    fn header_duration_rejects_wrong_tta_magic() {
        let file = temp_tta(b"not a TTA1 header at all!!");
        let error = header_duration_ms(&file.0).expect_err("wrong magic must fail");
        assert!(error.contains("TTA magic missing"));
    }

    #[test]
    fn header_duration_rejects_zero_tta_sample_rate() {
        let file = temp_tta(&tta_bytes(0, 32_346_468));
        let error = header_duration_ms(&file.0).expect_err("zero sample rate must fail");
        assert!(error.contains("TTA sample rate is zero"));
    }

    #[test]
    fn header_duration_rejects_zero_tta_data_length() {
        let file = temp_tta(&tta_bytes(44_100, 0));
        let error = header_duration_ms(&file.0).expect_err("zero data length must fail");
        assert!(error.contains("TTA data length is zero"));
    }

    #[test]
    fn header_duration_rejects_truncated_tta_header() {
        let mut bytes = tta_bytes(44_100, 32_346_468);
        bytes.truncate(TTA_HEADER_BYTES - 1);
        let file = temp_tta(&bytes);
        let error = header_duration_ms(&file.0).expect_err("short header must fail");
        assert!(error.contains("TTA header truncated"));
    }

    #[test]
    fn header_duration_rejects_tak_shorter_than_magic() {
        let file = temp_tak(b"tB");
        let error = header_duration_ms(&file.0).expect_err("short file must fail");
        assert!(error.contains("TAK read magic failed"));
    }

    #[test]
    fn header_duration_rejects_truncated_tak_metadata_header() {
        let file = temp_tak(b"tBaK\x01\x00");
        let error = header_duration_ms(&file.0).expect_err("truncated metadata must fail");
        assert!(error.contains("TAK metadata header truncated"));
    }

    #[test]
    fn header_duration_rejects_tak_block_exceeding_file() {
        let file = temp_tak(b"tBaK\x01\xff\xff\xff");
        let error = header_duration_ms(&file.0).expect_err("oversized block must fail");
        assert!(error.contains("TAK metadata block exceeds file length"));
    }

    #[test]
    fn header_duration_rejects_tak_without_streaminfo() {
        let file = temp_tak(b"tBaK\x00\x00\x00\x00");
        let error = header_duration_ms(&file.0).expect_err("missing streaminfo must fail");
        assert!(error.contains("TAK streaminfo absent"));
    }

    #[test]
    fn header_duration_rejects_tak_streaminfo_with_zero_samples() {
        let file = temp_tak(&tak_bytes(0, 44_100));
        let error = header_duration_ms(&file.0).expect_err("zero samples must fail");
        assert!(error.contains("invalid TAK streaminfo"));
    }

    #[test]
    fn probe_falls_back_to_tta_header_when_windows_fails() {
        let file = temp_tta(&tta_bytes(44_100, 32_346_468));
        let (duration_ms, attempts) = probe_container_duration_ms(
            &file.0,
            "built-in readers: unsupported".to_string(),
            |_| Err(anyhow::anyhow!("no media property handler")),
            header_duration_ms,
        );
        assert_eq!(duration_ms, Some(733_480));
        assert_eq!(attempts.len(), 2);
        assert!(attempts[1].contains("no media property handler"));
    }

    #[test]
    fn probe_collects_both_failures_for_tta_source() {
        let file = temp_tta(&tta_bytes(0, 32_346_468));
        let (duration_ms, attempts) = probe_container_duration_ms(
            &file.0,
            "built-in readers: unsupported".to_string(),
            |_| Err(anyhow::anyhow!("windows media properties unavailable")),
            header_duration_ms,
        );
        assert_eq!(duration_ms, None);
        assert_eq!(attempts.len(), 3);
        assert!(attempts[0].contains("unsupported"));
        assert!(attempts[1].contains("windows media properties unavailable"));
        assert!(attempts[2].contains("TTA sample rate is zero"));
    }
}
