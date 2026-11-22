//! 预读线程：唯一的生产者。
//!
//! 循环检查停止标志与 seek 请求，把数据源产出的字节推进会话缓冲。缓冲达到
//! 目标时短暂等待消费者取走，持续读盘时沿用提取流程的让出策略，降低对前台
//! 操作的干扰。

use std::sync::Arc;

use super::dsd_source::DsdSource;
use super::pcm_source::PcmSource;
use super::session::{apply_seek_result, StreamSession, WAIT_SLICE};

/// 单次产出的字节上限，限制一批数据的规模，让 seek 与停止能及时生效。
const CHUNK_MAX: usize = 512 * 1024;

/// 连续空批的最大轮数，超过后让出一次时间片，避免 DST 空帧造成忙等。
const IDLE_ROUNDS_BEFORE_YIELD: u32 = 64;

/// 预读线程持有的数据源。
pub(super) enum Source {
    /// 直解：ISO → 虚拟 DSF。
    Dsd(Box<DsdSource>),
    /// 实时 PCM：ISO → 虚拟 WAV。
    Pcm(Box<PcmSource>),
}

impl Source {
    fn length(&self) -> u64 {
        match self {
            Self::Dsd(source) => source.length(),
            Self::Pcm(source) => source.length(),
        }
    }

    fn header_len(&self) -> u64 {
        match self {
            Self::Dsd(source) => source.header_len(),
            Self::Pcm(source) => source.header_len(),
        }
    }

    fn seek(&mut self, offset: u64) -> Result<(), String> {
        match self {
            Self::Dsd(source) => source.seek(offset),
            Self::Pcm(source) => source.seek(offset),
        }
    }

    fn produce(&mut self, max_bytes: usize, out: &mut Vec<u8>) -> Result<bool, String> {
        match self {
            Self::Dsd(source) => source.produce(max_bytes, out),
            Self::Pcm(source) => source.produce(max_bytes, out),
        }
    }
}

/// 为会话启动预读线程，并把句柄写回会话，供回收线程 join。
pub(super) fn spawn(session: Arc<StreamSession>, source: Source) -> Result<(), String> {
    let thread_session = Arc::clone(&session);
    let handle = std::thread::Builder::new()
        .name("sacd-stream-reader".to_string())
        .spawn(move || run(thread_session, source))
        .map_err(|error| format!("启动 SACD 流预读线程失败: {error}"))?;

    match session.thread.lock() {
        Ok(mut guard) => *guard = Some(handle),
        Err(poisoned) => {
            log::warn!(
                "SACD 流线程句柄锁中毒，恢复后继续: iso={}",
                session.meta.iso_path
            );
            *poisoned.into_inner() = Some(handle);
        }
    }
    Ok(())
}

/// 预读主循环。
fn run(session: Arc<StreamSession>, mut source: Source) {
    let mut chunk: Vec<u8> = Vec::new();
    let mut idle_rounds: u32 = 0;
    let mut logged_lengths = false;

    loop {
        if session.is_stopped() {
            return;
        }

        if !logged_lengths {
            logged_lengths = true;
            log::debug!(
                "SACD 流预读开始: iso={}, area={}, track={}, mode={}, 虚拟长度={}, 头长度={}, 缓冲目标={}, 缓冲上限={}",
                session.meta.iso_path,
                session.meta.area,
                session.meta.track_number,
                session.meta.mode,
                source.length(),
                source.header_len(),
                session.meta.buffer_target,
                session.meta.buffer_limit
            );
        }

        // 1. 有挂起的 seek 时先执行定位。
        if let Some((offset, generation)) = take_seek_request(&session) {
            let started = std::time::Instant::now();
            let result = source.seek(offset);
            let elapsed = started.elapsed();
            let terminate = {
                let mut inner = session.lock_inner();
                apply_seek_result(&mut inner, offset, generation, &result)
            };
            session.cond.notify_all();

            match result {
                Ok(()) => log::debug!(
                    "SACD 流 seek 完成: iso={}, area={}, track={}, mode={}, offset={offset}, 耗时={elapsed:?}",
                    session.meta.iso_path,
                    session.meta.area,
                    session.meta.track_number,
                    session.meta.mode
                ),
                Err(error) => {
                    if terminate {
                        log::error!(
                            "SACD 流 seek 失败: iso={}, area={}, track={}, mode={}, offset={offset}, error={error}",
                            session.meta.iso_path,
                            session.meta.area,
                            session.meta.track_number,
                            session.meta.mode
                        );
                        // 当前请求定位失败是致命状态，failed 已由
                        // apply_seek_result 设置，后续 read/seek 会立即失败。
                        return;
                    }
                    log::warn!(
                        "SACD 流旧 seek 失败但已被新请求覆盖，继续处理最新请求: iso={}, area={}, track={}, offset={offset}, generation={generation}, error={error}",
                        session.meta.iso_path,
                        session.meta.area,
                        session.meta.track_number
                    );
                }
            }
            continue;
        }

        // 2. 缓冲已够时等待消费者取走。
        let buffered = { session.lock_inner().buffered_bytes };
        if buffered >= session.meta.buffer_target {
            wait_for_consumer(&session);
            continue;
        }

        // 3. 产出一批。
        let want = session
            .meta
            .buffer_target
            .saturating_sub(buffered)
            .min(CHUNK_MAX)
            .max(1);
        chunk.clear();
        let eof = match source.produce(want, &mut chunk) {
            Ok(eof) => eof,
            Err(error) => {
                log::error!(
                    "SACD 流预读失败: iso={}, area={}, track={}, mode={}, error={error}",
                    session.meta.iso_path,
                    session.meta.area,
                    session.meta.track_number,
                    session.meta.mode
                );
                session.fail(format!("SACD 流预读失败: {error}"));
                return;
            }
        };

        if !chunk.is_empty() {
            session.push_buffer(&chunk);
            idle_rounds = 0;
        } else if !eof {
            idle_rounds = idle_rounds.saturating_add(1);
            if idle_rounds >= IDLE_ROUNDS_BEFORE_YIELD {
                idle_rounds = 0;
                std::thread::yield_now();
            }
        }

        if eof {
            session.mark_eof();
            // EOF 后线程不能退出：BASS 的预读总比播放进度提前，用户可能把
            // 进度条拖回前面。这里等待新的 seek 请求或停止信号，回到主循环
            // 继续服务，避免「播到末尾再拖回开头」时 seek 无人处理。
            loop {
                if session.is_stopped() {
                    return;
                }
                if has_pending_seek(&session) {
                    break;
                }
                wait_for_consumer(&session);
            }
            continue;
        }
    }
}

/// 是否还有尚未应用的 seek 请求；只读判断，不消费请求。
fn has_pending_seek(session: &StreamSession) -> bool {
    let inner = session.lock_inner();
    inner.pending_seek.is_some() && inner.seek_generation > inner.applied_seek_generation
}

/// 读取挂起的 seek 请求；序号已应用或没有请求时返回 `None`。
fn take_seek_request(session: &StreamSession) -> Option<(u64, u64)> {
    let inner = session.lock_inner();
    let pending = inner.pending_seek?;
    if inner.seek_generation <= inner.applied_seek_generation {
        return None;
    }
    Some((pending, inner.seek_generation))
}

/// 短暂等待消费者取走数据；超时后由主循环重新判断状态。
fn wait_for_consumer(session: &StreamSession) {
    let _ = session.cond.wait_timeout(session.lock_inner(), WAIT_SLICE);
}
