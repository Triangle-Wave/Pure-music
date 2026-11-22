//! SACD 零缓存播放的流式数据源。
//!
//! 播放路径不写任何文件：直解模式把 ISO 中的 DSD 包装成虚拟 DSF，实时 PCM
//! 模式包装成虚拟 WAV，两者都通过 `BASS_FILEPROCS` 回调交给 BASS。会话由
//! 注册表持有 `Arc`，`close` 与 `sacd_stream_discard` 通过移除注册表条目
//! 互斥消费同一会话，回收线程负责 join 预读线程。

mod dsd_source;
mod layout;
mod pcm_source;
mod procs;
mod reader_thread;
mod session;
#[cfg(test)]
mod tests;

use std::ffi::c_void;
use std::fs;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use flutter_rust_bridge::frb;

use super::types::SacdFrameFormat;
use super::{
    modified_secs, parse_area, read_sacd_toc_cached, SacdFileProcs, SacdStreamDescriptor,
    SACD_SAMPLE_RATE_HZ,
};
use dsd_source::DsdSource;
use layout::{dsf_data_bytes, SACD_FRAMES_PER_SECOND};
use pcm_source::PcmSource;
use procs::{sacd_proc_close, sacd_proc_length, sacd_proc_read, sacd_proc_seek};
use reader_thread::{Source, spawn as spawn_reader};
use session::{SessionMeta, StreamSession};

/// 缓冲硬上限（8 MiB）。
const BUFFER_LIMIT: usize = 8 * 1024 * 1024;

/// 缓冲目标对应的音频时长（秒）。
const BUFFER_SECONDS: u64 = 4;

/// 缓冲目标的下限，避免极短轨道导致频繁等待。
const BUFFER_MIN: usize = 64 * 1024;

/// 回收线程等待预读线程结束的上限。
const RECLAIM_JOIN_TIMEOUT: Duration = Duration::from_secs(3);

/// 已打开的会话表，键是 `Arc::as_ptr` 得到的地址。
///
/// 同时播放的 SACD 流通常只有一两条，用线性表即可，也避免容器类型在 `static`
/// 初始化中的 const 约束。
static SESSIONS: Mutex<Vec<(usize, Arc<StreamSession>)>> = Mutex::new(Vec::new());

/// 回收队列；首次使用时创建专用线程。
static RECLAIM: OnceLock<Sender<Arc<StreamSession>>> = OnceLock::new();

/// 播放模式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[frb(ignore)]
enum StreamMode {
    /// DSD 直解（虚拟 DSF）。
    Dsd,
    /// 实时转换（虚拟 WAV）。
    Pcm,
}

impl StreamMode {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "dsd" => Ok(Self::Dsd),
            "pcm" => Ok(Self::Pcm),
            other => Err(format!(
                "不支持的 SACD 播放模式: {other}，仅支持 dsd 与 pcm"
            )),
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::Dsd => "dsd",
            Self::Pcm => "pcm",
        }
    }
}

/// 解析出的轨道信息。
#[derive(Debug, Clone)]
#[frb(ignore)]
pub(super) struct TrackInfo {
    /// 镜像路径。
    pub(super) iso_path: String,
    /// 音频区标识（`2ch` / `mch`）。
    pub(super) area: String,
    /// 区内轨号。
    pub(super) track_number: u32,
    /// 声道数。
    pub(super) channels: u32,
    /// DSD 采样率（Hz）。
    pub(super) sample_rate: u32,
    /// 帧格式。
    pub(super) frame_format: SacdFrameFormat,
    /// 起始逻辑扇区号。
    pub(super) start_lsn: u32,
    /// 轨道长度（逻辑扇区数）。
    pub(super) length_lsn: u32,
    /// 轨道时长（毫秒），缺 SACDTRL2 时按 LSN 估算。
    pub(super) duration_ms: u64,
}

/// 虚拟文件的关键参数。
#[frb(ignore)]
struct VirtualFile {
    length: u64,
    header_len: u64,
    channels: u32,
    sample_rate: u32,
    bit_depth: u16,
    /// 每秒音频字节数，用于计算缓冲目标。
    bytes_per_second: u64,
}

/// 打开一条 SACD 轨道的流式播放源，返回 BASS 建流所需信息。
#[frb(ignore)]
pub(super) fn open_stream(
    iso_path: String,
    area: String,
    track_number: u32,
    mode: String,
    sample_rate: u32,
    bit_depth: u16,
) -> Result<SacdStreamDescriptor, String> {
    let mode = StreamMode::parse(&mode)?;
    let track = resolve_track(&iso_path, &area, track_number)?;

    let (source, virtual_file) = match mode {
        StreamMode::Dsd => build_dsd(&track)?,
        StreamMode::Pcm => build_pcm(&track, sample_rate, bit_depth)?,
    };

    let bytes_per_second = virtual_file.bytes_per_second.max(1);
    let target = bytes_per_second
        .saturating_mul(BUFFER_SECONDS)
        .clamp(BUFFER_MIN as u64, BUFFER_LIMIT as u64) as usize;

    let meta = SessionMeta {
        iso_path: track.iso_path.clone(),
        area: track.area.clone(),
        track_number,
        mode: mode.as_str().to_string(),
        channels: virtual_file.channels,
        sample_rate: virtual_file.sample_rate,
        bit_depth: virtual_file.bit_depth,
        length: virtual_file.length,
        duration_ms: track.duration_ms,
        header_len: virtual_file.header_len,
        buffer_target: target,
        buffer_limit: BUFFER_LIMIT,
        bytes_per_second,
    };

    let session = Arc::new(StreamSession::new(meta));
    let user = Arc::as_ptr(&session) as usize;
    if let Err(error) = spawn_reader(Arc::clone(&session), source) {
        log::error!(
            "{error}: iso={iso_path}, area={area}, track={track_number}, mode={}",
            mode.as_str()
        );
        return Err(error);
    }
    register_session(user, Arc::clone(&session));

    log::info!(
        "SACD 流已打开: mode={}, iso={}, area={}, track={}, duration={} ms, 虚拟长度={}, 头长度={}, channels={}, sample_rate={}, bit_depth={}, 缓冲目标={} 字节, 缓冲上限={} 字节",
        mode.as_str(),
        iso_path,
        area,
        track_number,
        track.duration_ms,
        virtual_file.length,
        virtual_file.header_len,
        virtual_file.channels,
        virtual_file.sample_rate,
        virtual_file.bit_depth,
        target,
        BUFFER_LIMIT
    );

    // 先把函数项绑定到明确的函数指针类型，再转成地址，避免 `as` 转换类型歧义。
    let close_proc: unsafe extern "system" fn(*mut c_void) = sacd_proc_close;
    let length_proc: unsafe extern "system" fn(*mut c_void) -> u64 = sacd_proc_length;
    let read_proc: unsafe extern "system" fn(*mut c_void, u32, *mut c_void) -> u32 = sacd_proc_read;
    let seek_proc: unsafe extern "system" fn(u64, *mut c_void) -> i32 = sacd_proc_seek;

    Ok(SacdStreamDescriptor {
        user,
        procs: SacdFileProcs {
            close: close_proc as usize,
            length: length_proc as usize,
            read: read_proc as usize,
            seek: seek_proc as usize,
        },
        // x64 下 u64 与 usize 位宽相同，转换无损失；超界时退化为 usize::MAX。
        length: usize::try_from(virtual_file.length).unwrap_or(usize::MAX),
        duration_ms: usize::try_from(track.duration_ms).unwrap_or(usize::MAX),
        header_len: usize::try_from(virtual_file.header_len).unwrap_or(usize::MAX),
        channels: virtual_file.channels,
        sample_rate: virtual_file.sample_rate,
        bit_depth: virtual_file.bit_depth,
        mode: mode.as_str().to_string(),
    })
}

/// 丢弃一条会话；用于 `BASS_StreamCreateFileUser` 失败时。
#[frb(ignore)]
pub(super) fn discard_stream(user: usize) {
    if user == 0 {
        return;
    }
    match take_registered_session(user) {
        Some(session) => {
            session.request_stop();
            enqueue_reclaim(session);
        }
        None => log::debug!("SACD 流丢弃请求未命中会话（可能已关闭）: user={user:#x}"),
    }
}

/// 构造直解数据源。
#[frb(ignore)]
fn build_dsd(track: &TrackInfo) -> Result<(Source, VirtualFile), String> {
    let data_bytes = dsf_data_bytes(track.duration_ms, track.channels, track.sample_rate);
    if data_bytes == 0 {
        return Err(format!(
            "无法估算 SACD 轨道的 DSD 长度: iso={}, area={}, track={}, duration_ms={}",
            track.iso_path, track.area, track.track_number, track.duration_ms
        ));
    }
    let source = DsdSource::create(track, data_bytes)?;
    let virtual_file = VirtualFile {
        length: source.length(),
        header_len: source.header_len(),
        channels: track.channels,
        sample_rate: track.sample_rate,
        bit_depth: 1,
        bytes_per_second: u64::from(track.sample_rate)
            .saturating_mul(u64::from(track.channels))
            / 8,
    };
    Ok((Source::Dsd(Box::new(source)), virtual_file))
}

/// 构造实时 PCM 数据源。
#[frb(ignore)]
fn build_pcm(
    track: &TrackInfo,
    sample_rate: u32,
    bit_depth: u16,
) -> Result<(Source, VirtualFile), String> {
    if !matches!(sample_rate, 44_100 | 48_000 | 88_200 | 96_000 | 192_000) {
        return Err(format!(
            "不支持的 PCM 采样率 {sample_rate}，仅支持 44100/48000/88200/96000/192000"
        ));
    }
    if !matches!(bit_depth, 16 | 24) {
        return Err(format!("不支持的 PCM 位深 {bit_depth}，仅支持 16/24"));
    }
    let out_rate = super::pcm::effective_sample_rate(sample_rate);
    let source = PcmSource::create(track, out_rate, bit_depth)?;
    let bytes_per_sample = u64::from(bit_depth / 8);
    let virtual_file = VirtualFile {
        length: source.length(),
        header_len: source.header_len(),
        channels: track.channels,
        sample_rate: out_rate,
        bit_depth,
        bytes_per_second: u64::from(out_rate)
            .saturating_mul(u64::from(track.channels))
            .saturating_mul(bytes_per_sample),
    };
    Ok((Source::Pcm(Box::new(source)), virtual_file))
}

/// 解析轨道元数据。
#[frb(ignore)]
fn resolve_track(iso_path: &str, area: &str, track_number: u32) -> Result<TrackInfo, String> {
    let kind = parse_area(area).map_err(|_| {
        format!(
            "不支持的 SACD 区: {area}，仅支持 2ch 与 mch (iso={iso_path}, track={track_number})"
        )
    })?;

    let metadata = fs::metadata(iso_path).map_err(|error| {
        format!("读取 SACD 镜像信息失败: iso={iso_path}, error={error}")
    })?;
    let iso_len = metadata.len();
    let mtime = modified_secs(&metadata);

    let toc = read_sacd_toc_cached(iso_path, iso_len, mtime).map_err(|error| {
        format!(
            "解析 SACD 目录失败: iso={iso_path}, area={area}, track={track_number}, error={error}"
        )
    })?;

    let selected = toc
        .areas
        .iter()
        .find(|candidate| candidate.kind == kind)
        .ok_or_else(|| {
            format!("SACD 镜像中没有 {area} 区: iso={iso_path}, track={track_number}")
        })?;
    let track = selected
        .tracks
        .iter()
        .find(|candidate| u32::from(candidate.number) == track_number)
        .ok_or_else(|| {
            format!("SACD {area} 区中没有轨道 {track_number}: iso={iso_path}")
        })?;

    if selected.channel_count == 0 {
        return Err(format!(
            "SACD {area} 区声道数为 0: iso={iso_path}, track={track_number}"
        ));
    }
    if track.length_lsn == 0 {
        return Err(format!(
            "SACD 轨道长度为 0: iso={iso_path}, area={area}, track={track_number}"
        ));
    }

    let duration_ms = if track.duration_ms > 0 {
        track.duration_ms
    } else if selected.frame_format == SacdFrameFormat::Dst {
        // DST 是变码率：按 LSN 估算会偏大 2~3 倍，导致虚拟长度虚高、进度条与
        // 结束时点失真。这里只读扇区头统计帧数，不做 DST 解码。
        match count_dst_frames(iso_path, track.start_lsn, track.length_lsn) {
            Ok(frames) if frames > 0 => {
                let duration = frames.saturating_mul(1_000) / SACD_FRAMES_PER_SECOND;
                log::info!(
                    "SACD DST 轨道缺少时长，按帧起点统计: iso={iso_path}, area={area}, track={track_number}, 帧数={frames}, 时长={duration} ms"
                );
                duration
            }
            Ok(_) => {
                log::warn!(
                    "SACD DST 轨道未统计到帧起点，回退按 LSN 估算时长: iso={iso_path}, area={area}, track={track_number}"
                );
                estimate_duration_ms(
                    track.length_lsn,
                    selected.channel_count,
                    SACD_SAMPLE_RATE_HZ,
                )
            }
            Err(error) => {
                log::warn!(
                    "SACD DST 帧数统计失败，回退按 LSN 估算时长: iso={iso_path}, area={area}, track={track_number}, error={error}"
                );
                estimate_duration_ms(
                    track.length_lsn,
                    selected.channel_count,
                    SACD_SAMPLE_RATE_HZ,
                )
            }
        }
    } else {
        estimate_duration_ms(
            track.length_lsn,
            selected.channel_count,
            SACD_SAMPLE_RATE_HZ,
        )
    };

    Ok(TrackInfo {
        iso_path: iso_path.to_string(),
        area: area.to_string(),
        track_number,
        channels: u32::from(selected.channel_count),
        sample_rate: SACD_SAMPLE_RATE_HZ,
        frame_format: selected.frame_format,
        start_lsn: track.start_lsn,
        length_lsn: track.length_lsn,
        duration_ms,
    })
}

/// 按 LSN 数估算轨道时长（毫秒）。
#[frb(ignore)]
fn estimate_duration_ms(length_lsn: u32, channels: u8, sample_rate: u32) -> u64 {
    let channels = u64::from(channels.max(1));
    let denominator = u128::from(sample_rate) * u128::from(channels);
    if denominator == 0 {
        return 0;
    }
    let bits = u128::from(length_lsn) * 2_048 * 8 * 1_000;
    u64::try_from(bits / denominator).unwrap_or(u64::MAX)
}

/// 统计一条 DST 轨道的帧数：只读扇区头判断 `frame_start`，不做 DST 解码。
#[frb(ignore)]
fn count_dst_frames(iso_path: &str, start_lsn: u32, length_lsn: u32) -> Result<u64, String> {
    let mut image = super::reader::ImageReader::open(std::path::Path::new(iso_path)).map_err(
        |error| {
            format!(
                "打开 SACD 镜像统计 DST 帧数失败: iso={iso_path}, error={error}"
            )
        },
    )?;
    let end_lsn = start_lsn.saturating_add(length_lsn);
    let mut lsn = start_lsn;
    let mut frames = 0u64;
    let mut batch_index = 0u32;
    while lsn < end_lsn {
        let count = (end_lsn - lsn).min(u32::from(super::extract::SECTORS_PER_BATCH)) as u16;
        if count == 0 {
            break;
        }
        let sectors = image.read_sectors(lsn, count).map_err(|error| {
            format!(
                "读取 SACD 扇区统计 DST 帧数失败: iso={iso_path}, lsn={lsn}, error={error}"
            )
        })?;
        for sector in sectors.chunks_exact(super::types::SACD_LSN_SIZE) {
            if dsd_source::sector_has_frame_start(sector) {
                frames = frames.saturating_add(1);
            }
        }
        lsn = lsn.saturating_add(u32::from(count));
        batch_index = batch_index.saturating_add(1);
        super::extract::apply_batch_pause(batch_index);
    }
    Ok(frames)
}

/// 按地址取一份会话的强引用；会话已被 `close` / `discard` 消费时返回 `None`。
///
/// 回调持有一份克隆的 `Arc`，因此即便 `close` 同时把会话移出注册表并交给
/// 回收线程，回调本次执行期间的对象也不会被释放。锁顺序仍是「注册表 →
/// 会话内部状态」，不新增嵌套。
#[frb(ignore)]
pub(super) fn lookup_session(user: usize) -> Option<Arc<StreamSession>> {
    match SESSIONS.lock() {
        Ok(guard) => find_session(&guard, user),
        Err(poisoned) => {
            log::warn!("SACD 流会话表锁中毒，恢复后继续查找: user={user:#x}");
            find_session(&poisoned.into_inner(), user)
        }
    }
}

/// 在会话表中查找并克隆强引用。
#[frb(ignore)]
fn find_session(
    entries: &[(usize, Arc<StreamSession>)],
    user: usize,
) -> Option<Arc<StreamSession>> {
    entries
        .iter()
        .find(|(key, _)| *key == user)
        .map(|(_, session)| Arc::clone(session))
}

/// 把会话登记到注册表。
#[frb(ignore)]
fn register_session(user: usize, session: Arc<StreamSession>) {
    match SESSIONS.lock() {
        Ok(mut guard) => {
            guard.retain(|(key, _)| *key != user);
            guard.push((user, session));
        }
        Err(poisoned) => {
            log::warn!("SACD 流会话表锁中毒，恢复后继续登记: user={user:#x}");
            let mut guard = poisoned.into_inner();
            guard.retain(|(key, _)| *key != user);
            guard.push((user, session));
        }
    }
}

/// 从注册表移除会话；返回 `None` 表示已被消费或从未登记。
#[frb(ignore)]
pub(super) fn take_registered_session(user: usize) -> Option<Arc<StreamSession>> {
    match SESSIONS.lock() {
        Ok(mut guard) => take_from(&mut guard, user),
        Err(poisoned) => {
            log::warn!("SACD 流会话表锁中毒，恢复后继续移除: user={user:#x}");
            take_from(&mut poisoned.into_inner(), user)
        }
    }
}

/// 从会话表中取出指定条目。
#[frb(ignore)]
fn take_from(
    entries: &mut Vec<(usize, Arc<StreamSession>)>,
    user: usize,
) -> Option<Arc<StreamSession>> {
    let position = entries.iter().position(|(key, _)| *key == user)?;
    Some(entries.remove(position).1)
}

/// 当前登记的会话数量，供测试核对回收是否完成。
#[cfg(test)]
#[frb(ignore)]
pub(super) fn registered_session_count() -> usize {
    match SESSIONS.lock() {
        Ok(guard) => guard.len(),
        Err(poisoned) => poisoned.into_inner().len(),
    }
}

/// 指定指针是否仍在会话表中，供测试核对 `close` 是否消费了会话。
#[cfg(test)]
#[frb(ignore)]
pub(super) fn registered_session_exists(user: usize) -> bool {
    match SESSIONS.lock() {
        Ok(guard) => guard.iter().any(|(key, _)| *key == user),
        Err(poisoned) => poisoned.into_inner().iter().any(|(key, _)| *key == user),
    }
}

/// 把会话交给回收线程；`close` 与 `discard` 都走这里。
#[frb(ignore)]
pub(super) fn enqueue_reclaim(session: Arc<StreamSession>) {
    let sender = reclaim_sender();
    if let Err(error) = sender.send(Arc::clone(&session)) {
        log::error!(
            "SACD 流回收队列不可用，改为直接释放会话: iso={}, area={}, track={}, error={error}",
            session.meta.iso_path,
            session.meta.area,
            session.meta.track_number
        );
        // 发送失败时错误值持有我们克隆的 Arc，随错误一起丢弃。
        drop(error);
    }
}

/// 取回收队列发送端；首次调用时启动回收线程。
#[frb(ignore)]
fn reclaim_sender() -> &'static Sender<Arc<StreamSession>> {
    RECLAIM.get_or_init(|| {
        let (sender, receiver) = mpsc::channel::<Arc<StreamSession>>();
        if let Err(error) = std::thread::Builder::new()
            .name("sacd-stream-reclaim".to_string())
            .spawn(move || reclaim_loop(receiver))
        {
            log::error!("启动 SACD 流回收线程失败: {error}");
        }
        sender
    })
}

/// 回收线程主循环：等待预读线程结束，记录关闭摘要。
#[frb(ignore)]
fn reclaim_loop(receiver: Receiver<Arc<StreamSession>>) {
    for session in receiver {
        let handle = match session.thread.lock() {
            Ok(mut guard) => guard.take(),
            Err(poisoned) => {
                log::warn!(
                    "SACD 流线程句柄锁中毒，恢复后继续回收: iso={}",
                    session.meta.iso_path
                );
                poisoned.into_inner().take()
            }
        };

        if let Some(handle) = handle {
            let deadline = Instant::now() + RECLAIM_JOIN_TIMEOUT;
            let mut joined = handle.is_finished();
            while !joined {
                if Instant::now() >= deadline {
                    log::error!(
                        "SACD 流预读线程 {} 秒内未结束，放弃等待: iso={}, area={}, track={}",
                        RECLAIM_JOIN_TIMEOUT.as_secs(),
                        session.meta.iso_path,
                        session.meta.area,
                        session.meta.track_number
                    );
                    break;
                }
                std::thread::sleep(Duration::from_millis(5));
                joined = handle.is_finished();
            }
            if joined {
                if handle.join().is_err() {
                    log::error!(
                        "SACD 流预读线程 panic: iso={}, area={}, track={}",
                        session.meta.iso_path,
                        session.meta.area,
                        session.meta.track_number
                    );
                }
            }
        }

        let (bytes_read, underruns, seeks, peak_buffered, position) = {
            let inner = session.lock_inner();
            (
                inner.bytes_read,
                inner.underruns,
                inner.seeks,
                inner.peak_buffered,
                inner.position,
            )
        };
        log::info!(
            "SACD 流已关闭: iso={}, area={}, track={}, mode={}, 已读={bytes_read} 字节, 位置={position}, 欠载={underruns}, seek={seeks}, 峰值缓冲={peak_buffered} 字节, 缓冲目标={} 字节",
            session.meta.iso_path,
            session.meta.area,
            session.meta.track_number,
            session.meta.mode,
            session.meta.buffer_target
        );
    }
}
