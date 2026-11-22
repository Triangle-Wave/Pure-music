//! BASS `BASS_FILEPROCS` 回调。
//!
//! 四个回调都是 `extern "system"`，与 `bass.h` 的 `FILECLOSEPROC` /
//! `FILELENPROC` / `FILEREADPROC` / `FILESEEKPROC` 逐参数对应。每个回调都用
//! `catch_unwind` 兜底，禁止 panic 穿透到 C ABI。

use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};

/// `FILECLOSEPROC`: `void (CALLBACK *)(void *user)`。
///
/// 只置停止标志、唤醒等待者并把会话交给回收线程，不 join、不做磁盘 IO。
///
/// # Safety
///
/// `user` 必须是 [`super::open_stream`] 返回的会话地址，且 BASS 之后不再使用
/// 该指针。
pub(super) unsafe extern "system" fn sacd_proc_close(user: *mut c_void) {
    let ptr = user as usize;
    let result = catch_unwind(AssertUnwindSafe(|| {
        if ptr == 0 {
            return;
        }
        match super::take_registered_session(ptr) {
            Some(session) => {
                session.request_stop();
                super::enqueue_reclaim(session);
            }
            None => log::debug!("SACD 流 close 回调未命中会话（可能已丢弃）: user={ptr:#x}"),
        }
    }));
    if let Err(payload) = result {
        log::error!(
            "SACD 流 close 回调触发 panic: {}",
            panic_message(payload.as_ref())
        );
    }
}

/// `FILELENPROC`: `QWORD (CALLBACK *)(void *user)`。
///
/// 返回虚拟文件总字节数，永不返回 0（BASS 会把 0 当作不可 seek）。
///
/// # Safety
///
/// 同 [`sacd_proc_close`]。
pub(super) unsafe extern "system" fn sacd_proc_length(user: *mut c_void) -> u64 {
    let ptr = user as usize;
    if ptr == 0 {
        return 1;
    }
    // 先取一份强引用：close 可能同时把会话移出注册表并交给回收线程，
    // 持有克隆的 Arc 才能保证本次回调期间对象不被释放。
    let Some(session) = super::lookup_session(ptr) else {
        log::debug!("SACD 流 length 回调未命中会话: user={ptr:#x}");
        return 1;
    };
    let length = session.meta.length;
    match catch_unwind(AssertUnwindSafe(|| length)) {
        Ok(length) => length.max(1),
        Err(payload) => {
            log::error!(
                "SACD 流 length 回调触发 panic: user={ptr:#x}, {}",
                panic_message(payload.as_ref())
            );
            1
        }
    }
}

/// `FILEREADPROC`: `DWORD (CALLBACK *)(void *buffer, DWORD length, void *user)`。
///
/// 最多写入 `length` 字节并返回实际字节数；EOF、失败或等待超时返回 0。
///
/// # Safety
///
/// `buffer` 必须可写至少 `length` 字节；`user` 同 [`sacd_proc_close`]。
pub(super) unsafe extern "system" fn sacd_proc_read(
    buffer: *mut c_void,
    length: u32,
    user: *mut c_void,
) -> u32 {
    if buffer.is_null() || length == 0 {
        return 0;
    }
    let ptr = user as usize;
    // 同 length 回调：持有一份强引用，避免与 close 的回收竞争。
    let Some(session) = super::lookup_session(ptr) else {
        log::trace!("SACD 流 read 回调未命中会话: user={ptr:#x}");
        return 0;
    };
    let target = buffer as *mut u8;
    let result = catch_unwind(AssertUnwindSafe(|| session.read(target, length)));
    match result {
        Ok(written) => written,
        Err(payload) => {
            log::error!(
                "SACD 流 read 回调触发 panic: user={ptr:#x}, {}",
                panic_message(payload.as_ref())
            );
            0
        }
    }
}

/// `FILESEEKPROC`: `BOOL (CALLBACK *)(QWORD offset, void *user)`。
///
/// `offset` 是绝对文件偏移（BASS 不传 whence），成功返回 1，失败或超时返回 0。
///
/// # Safety
///
/// 同 [`sacd_proc_close`]。
pub(super) unsafe extern "system" fn sacd_proc_seek(
    offset: u64,
    user: *mut c_void,
) -> i32 {
    let ptr = user as usize;
    // 同 length 回调：持有一份强引用，避免与 close 的回收竞争。
    let Some(session) = super::lookup_session(ptr) else {
        log::debug!("SACD 流 seek 回调未命中会话: user={ptr:#x}, offset={offset}");
        return 0;
    };
    let result = catch_unwind(AssertUnwindSafe(|| session.seek(offset)));
    match result {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(payload) => {
            log::error!(
                "SACD 流 seek 回调触发 panic: user={ptr:#x}, {}",
                panic_message(payload.as_ref())
            );
            0
        }
    }
}

/// 提取 panic 负载中的可读消息。
fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        return (*message).to_owned();
    }
    if let Some(message) = payload.downcast_ref::<String>() {
        return message.clone();
    }
    "未知 panic 负载".to_owned()
}
