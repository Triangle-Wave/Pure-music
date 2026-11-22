//! 流会话状态机：缓冲、读取、seek 与关闭。
//!
//! 预读线程是唯一的生产者，BASS 的解码线程是唯一的消费者。缓冲区是
//! [`VecDeque`]，读取在缓冲为空且未到 EOF 时最多等待 [`READ_TIMEOUT`]，超时
//! 按欠载记录并返回 0，避免回调永久阻塞。seek 由回调设置请求、由预读线程
//! 执行，回调按 generation 等待本次请求被应用，最多等待 [`SEEK_TIMEOUT`]。

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Condvar, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use flutter_rust_bridge::frb;

/// `read` 等待一个非空缓冲的最长时间。
///
/// 超时返回 0 会被 BASS 当作 EOF 导致跳曲，因此给足 5 秒；等待使用
/// [`WAIT_SLICE`] 切片轮询，`stop` 能立即唤醒，不会卡死。
pub(super) const READ_TIMEOUT: Duration = Duration::from_secs(5);

/// `seek` 等待预读线程完成定位的最长时间。
pub(super) const SEEK_TIMEOUT: Duration = Duration::from_secs(2);

/// 预读线程等待消费者取走数据时的轮询切片，保证 `stop` 能及时生效。
pub(super) const WAIT_SLICE: Duration = Duration::from_millis(50);

/// 会话的只读元数据。
#[derive(Debug, Clone)]
#[frb(ignore)]
pub(super) struct SessionMeta {
    /// 镜像路径，仅用于日志定位。
    pub(super) iso_path: String,
    /// 音频区标识（`2ch` / `mch`）。
    pub(super) area: String,
    /// 区内轨号。
    pub(super) track_number: u32,
    /// 播放模式（`dsd` / `pcm`）。
    pub(super) mode: String,
    /// 声道数。
    pub(super) channels: u32,
    /// 虚拟文件的采样率（直解为 DSD 采样率，PCM 为输出采样率）。
    pub(super) sample_rate: u32,
    /// 虚拟文件的位深（直解为 1，PCM 为 16/24）。
    pub(super) bit_depth: u16,
    /// 虚拟文件总字节数。
    pub(super) length: u64,
    /// 轨道时长（毫秒）。
    pub(super) duration_ms: u64,
    /// 虚拟文件头长度。
    pub(super) header_len: u64,
    /// 预读目标字节数。
    pub(super) buffer_target: usize,
    /// 缓冲硬上限，任何情况下都不应超过。
    pub(super) buffer_limit: usize,
    /// 音频字节率，用于把缓冲字节数换算成时长。
    pub(super) bytes_per_second: u64,
}

/// 会话的可变状态。
#[frb(ignore)]
pub(super) struct SessionInner {
    /// 已产出、待消费的字节。
    pub(super) buffer: VecDeque<u8>,
    /// `buffer` 的长度，避免每次调用 `len()`。
    pub(super) buffered_bytes: usize,
    /// 生产者已到真实结尾且缓冲已排空。
    pub(super) eof: bool,
    /// 生产或解析失败的原因。
    pub(super) failed: Option<String>,
    /// 待执行的 seek 目标（绝对文件偏移）。
    pub(super) pending_seek: Option<u64>,
    /// seek 请求序号。
    pub(super) seek_generation: u64,
    /// 已执行的 seek 序号。
    pub(super) applied_seek_generation: u64,
    /// 消费者已读到的绝对偏移。
    pub(super) position: u64,
    /// 欠载次数（等待超时）。
    pub(super) underruns: u64,
    /// seek 次数。
    pub(super) seeks: u64,
    /// 观测到的峰值缓冲字节数。
    pub(super) peak_buffered: usize,
    /// 已交付给消费者的总字节数。
    pub(super) bytes_read: u64,
}

impl Default for SessionInner {
    fn default() -> Self {
        Self {
            buffer: VecDeque::new(),
            buffered_bytes: 0,
            eof: false,
            failed: None,
            pending_seek: None,
            seek_generation: 0,
            applied_seek_generation: 0,
            position: 0,
            underruns: 0,
            seeks: 0,
            peak_buffered: 0,
            bytes_read: 0,
        }
    }
}

/// 一条 SACD 流会话。
#[frb(ignore)]
pub(super) struct StreamSession {
    /// 可变状态，预读线程与回调共享。
    pub(super) inner: Mutex<SessionInner>,
    /// 生产/消费同步条件变量。
    pub(super) cond: Condvar,
    /// 关闭标志，`close` 只置位并唤醒。
    pub(super) stop: AtomicBool,
    /// 只读元数据。
    pub(super) meta: SessionMeta,
    /// 预读线程句柄，仅在回收线程里 join。
    pub(super) thread: Mutex<Option<JoinHandle<()>>>,
}

impl StreamSession {
    /// 创建会话；预读线程句柄稍后由调用方写入。
    pub(super) fn new(meta: SessionMeta) -> Self {
        Self {
            inner: Mutex::new(SessionInner::default()),
            cond: Condvar::new(),
            stop: AtomicBool::new(false),
            meta,
            thread: Mutex::new(None),
        }
    }

    /// 取会话锁；锁中毒时记录警告并恢复内层数据。
    pub(super) fn lock_inner(&self) -> MutexGuard<'_, SessionInner> {
        match self.inner.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                log::warn!(
                    "SACD 流会话锁中毒，恢复后继续: iso={}, area={}, track={}",
                    self.meta.iso_path,
                    self.meta.area,
                    self.meta.track_number
                );
                poisoned.into_inner()
            }
        }
    }

    /// 是否已被要求停止。
    pub(super) fn is_stopped(&self) -> bool {
        self.stop.load(Ordering::Acquire)
    }

    /// 置停止标志、取消挂起的 seek 并唤醒所有等待者。
    ///
    /// 只做内存操作，不 join 线程、不做磁盘 IO，可在 BASS 解码线程里安全调用。
    pub(super) fn request_stop(&self) {
        self.stop.store(true, Ordering::Release);
        {
            let mut inner = self.lock_inner();
            inner.pending_seek = None;
        }
        self.cond.notify_all();
    }

    /// 从会话缓冲读取至多 `length` 字节并写入 `buffer`。
    ///
    /// 缓冲为空且未到 EOF 时最多等待 [`READ_TIMEOUT`]；超时按欠载记录并
    /// 返回 0（BASS 视为 EOF），不阻塞回调线程。
    ///
    /// 调用方必须保证 `buffer` 指向可写的最少 `length` 字节，并在本次调用
    /// 期间保持有效；`buffer` 为空指针时直接返回 0。
    pub(super) fn read(&self, buffer: *mut u8, length: u32) -> u32 {
        if buffer.is_null() || length == 0 {
            return 0;
        }

        let mut inner = self.lock_inner();
        if self.is_stopped() {
            return 0;
        }

        let deadline = Instant::now() + READ_TIMEOUT;
        loop {
            if !inner.buffer.is_empty() {
                break;
            }
            if inner.eof {
                return 0;
            }
            if inner.failed.is_some() {
                return 0;
            }
            if self.is_stopped() {
                return 0;
            }

            let now = Instant::now();
            if now >= deadline {
                inner.underruns = inner.underruns.saturating_add(1);
                let buffered = inner.buffered_bytes;
                let position = inner.position;
                drop(inner);
                let rate = self.meta.bytes_per_second.max(1);
                let buffered_ms = (buffered as u64).saturating_mul(1_000) / rate;
                log::warn!(
                    "SACD 流缓冲欠载: iso={}, area={}, track={}, mode={}, 已缓冲={buffered} 字节（约 {buffered_ms} ms）, 已读={position} 字节",
                    self.meta.iso_path,
                    self.meta.area,
                    self.meta.track_number,
                    self.meta.mode
                );
                return 0;
            }

            let slice = deadline.saturating_duration_since(now).min(WAIT_SLICE);
            inner = match self.cond.wait_timeout(inner, slice) {
                Ok((guard, _)) => guard,
                Err(poisoned) => {
                    log::warn!(
                        "SACD 流读取等待时锁中毒，恢复后继续: iso={}",
                        self.meta.iso_path
                    );
                    poisoned.into_inner().0
                }
            };
        }

        let available = inner.buffer.len();
        let take = (length as usize).min(available);
        if take == 0 {
            return 0;
        }

        {
            let (first, second) = inner.buffer.as_slices();
            let first_take = take.min(first.len());
            // SAFETY: 调用方保证 `buffer` 至少有 `length` 字节可写，`take <= length`。
            unsafe {
                std::ptr::copy_nonoverlapping(first.as_ptr(), buffer, first_take);
                if take > first_take {
                    let rest = take - first_take;
                    std::ptr::copy_nonoverlapping(
                        second.as_ptr(),
                        buffer.add(first_take),
                        rest,
                    );
                }
            }
        }

        inner.buffer.drain(..take);
        inner.buffered_bytes = inner.buffer.len();
        inner.position = inner.position.saturating_add(take as u64);
        inner.bytes_read = inner.bytes_read.saturating_add(take as u64);
        drop(inner);

        self.cond.notify_all();
        take as u32
    }

    /// 请求预读线程定位到 `offset`，成功后返回 `true`。
    ///
    /// 记录请求并清空缓冲后，按本次请求的 generation 等待它被应用。等待期间
    /// 若出现更新的 seek 请求（`seek_generation` 被推进），本次调用立即返回
    /// `false`，让 BASS 重试最新位置，避免"位置停在旧目标却报告成功"。等待
    /// 超过 [`SEEK_TIMEOUT`]、会话停止或生产已失败时同样返回 `false`。
    pub(super) fn seek(&self, offset: u64) -> bool {
        let mut inner = self.lock_inner();
        if self.is_stopped() {
            return false;
        }
        if inner.failed.is_some() {
            return false;
        }

        let my_generation = inner.seek_generation.wrapping_add(1);
        inner.seek_generation = my_generation;
        inner.pending_seek = Some(offset);
        inner.seeks = inner.seeks.saturating_add(1);
        inner.buffer.clear();
        inner.buffered_bytes = 0;
        inner.eof = false;
        self.cond.notify_all();

        let deadline = Instant::now() + SEEK_TIMEOUT;
        loop {
            // 只有本次 generation 被应用才算完成；旧请求被新请求覆盖时不冒充成功。
            if inner.applied_seek_generation >= my_generation {
                return inner.failed.is_none();
            }
            if self.is_stopped() {
                return false;
            }
            if inner.failed.is_some() {
                return false;
            }
            if inner.seek_generation > my_generation {
                log::debug!(
                    "SACD 流 seek 被更新的请求覆盖: iso={}, track={}, offset={offset}, 本次 generation={my_generation}, 最新={}",
                    self.meta.iso_path,
                    self.meta.track_number,
                    inner.seek_generation
                );
                return false;
            }

            let now = Instant::now();
            if now >= deadline {
                log::warn!(
                    "SACD 流 seek 超时: iso={}, area={}, track={}, mode={}, offset={offset}",
                    self.meta.iso_path,
                    self.meta.area,
                    self.meta.track_number,
                    self.meta.mode
                );
                return false;
            }

            let slice = deadline.saturating_duration_since(now).min(WAIT_SLICE);
            inner = match self.cond.wait_timeout(inner, slice) {
                Ok((guard, _)) => guard,
                Err(poisoned) => {
                    log::warn!(
                        "SACD 流 seek 等待时锁中毒，恢复后继续: iso={}",
                        self.meta.iso_path
                    );
                    poisoned.into_inner().0
                }
            };
        }
    }

    /// 记录一次生产失败，唤醒等待者并让后续 `read` 立即返回 0。
    pub(super) fn fail(&self, message: String) {
        {
            let mut inner = self.lock_inner();
            inner.failed = Some(message);
            inner.eof = true;
        }
        self.cond.notify_all();
    }

    /// 把一批数据追加进缓冲；缓冲达到上限时背压等待，不丢弃音频。
    ///
    /// 等待用 [`WAIT_SLICE`] 切片轮询并释放锁，消费者取走数据后会唤醒本线程；
    /// `stop` 与新的 seek 请求都会让等待立即结束（本批在 seek 后会被重新产出）。
    pub(super) fn push_buffer(&self, data: &[u8]) {
        if data.is_empty() {
            return;
        }
        let limit = self.meta.buffer_limit.max(1);
        let mut inner = self.lock_inner();
        let mut logged_backpressure = false;
        loop {
            // seek 已挂起时本批数据属于旧位置，直接丢弃。
            if inner.pending_seek.is_some() || self.is_stopped() {
                return;
            }
            if inner.buffered_bytes.saturating_add(data.len()) <= limit {
                break;
            }
            if !logged_backpressure {
                logged_backpressure = true;
                log::debug!(
                    "SACD 流缓冲达到上限，等待消费者: 已缓冲={} 字节, 上限={limit} 字节, 待写入={} 字节",
                    inner.buffered_bytes,
                    data.len()
                );
            }
            inner = match self.cond.wait_timeout(inner, WAIT_SLICE) {
                Ok((guard, _)) => guard,
                Err(poisoned) => {
                    log::warn!(
                        "SACD 流缓冲等待时锁中毒，恢复后继续: iso={}",
                        self.meta.iso_path
                    );
                    poisoned.into_inner().0
                }
            };
        }
        inner.buffer.extend(data.iter().copied());
        inner.buffered_bytes = inner.buffer.len();
        inner.peak_buffered = inner.peak_buffered.max(inner.buffered_bytes);
        drop(inner);
        self.cond.notify_all();
    }

    /// 标记生产者已到真实结尾。
    pub(super) fn mark_eof(&self) {
        {
            let mut inner = self.lock_inner();
            inner.eof = true;
        }
        self.cond.notify_all();
    }
}

/// 把一次 seek 的执行结果写回会话状态，返回是否应终止预读线程。
///
/// 关键点：只有当写回时 `pending_seek` 与 `seek_generation` 仍对应本次请求
/// （`is_current`）时才推进状态。并发 seek 下，旧请求 A 被新请求 B 覆盖后即使
/// A 失败，也不能把整条会话标记失败——否则 B 与后续读取全部报废。
///
/// 返回值语义：`true` 表示当前（最新）请求定位失败，`failed` 与 `eof` 已在
/// 本函数内设置，调用方唤醒等待者后应结束预读线程；`false` 表示可以继续。
#[frb(ignore)]
pub(super) fn apply_seek_result(
    inner: &mut SessionInner,
    offset: u64,
    generation: u64,
    result: &Result<(), String>,
) -> bool {
    let is_current = inner.pending_seek == Some(offset) && inner.seek_generation == generation;
    inner.buffer.clear();
    inner.buffered_bytes = 0;
    inner.eof = false;

    match result {
        Ok(()) => {
            inner.failed = None;
            inner.position = offset;
            if is_current {
                inner.applied_seek_generation = generation;
                inner.pending_seek = None;
            }
            false
        }
        Err(error) => {
            if is_current {
                inner.failed = Some(error.clone());
                inner.eof = true;
                inner.pending_seek = None;
                true
            } else {
                // 旧请求失败但已被新请求覆盖：保留新请求，会话继续可用。
                false
            }
        }
    }
}
