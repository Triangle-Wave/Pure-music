//! 进程级临时目录环境变量配置。
//!
//! FFmpeg、BASS_FFMPEG、桌面歌词与更新 helper 等子进程会继承当前进程的
//! 环境变量，Dart 侧在启动时把这些变量指向程序数据目录，避免子进程把
//! 临时文件写到系统盘或受限目录。

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// 串行化三个临时目录变量的写入，避免并发调用产生部分生效的状态。
static TEMP_DIR_LOCK: Mutex<()> = Mutex::new(());

/// 子进程会读取的临时目录变量。
const TEMP_ENV_KEYS: [&str; 3] = ["TEMP", "TMP", "TMPDIR"];

/// 把当前进程的临时目录环境变量指向 `path`，供后续启动的子进程继承。
///
/// 设置 `TEMP`、`TMP`、`TMPDIR` 三个变量；目录不存在时自动创建。
/// 写入前保存这三个变量的原值，任一写入失败时回滚。
/// 已启动的子进程不受影响，调用方应在启动子进程之前执行。
///
/// # Errors
///
/// `path` 为空、仅含空白、带首尾空白、包含 NUL 字符、不是绝对路径，
/// 或目录创建、目录校验失败时返回错误；错误信息包含目标路径。
#[flutter_rust_bridge::frb]
pub fn set_process_temp_dir(path: String) -> Result<(), String> {
    let validated = validate_temp_dir(&path)?;
    let directory = ensure_temp_dir(&validated)?;
    let value = directory.to_string_lossy().into_owned();

    let _guard = match TEMP_DIR_LOCK.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            log::warn!(
                target: "app_env",
                "temp dir lock poisoned while writing, recovering: {poisoned}"
            );
            TEMP_DIR_LOCK.clear_poison();
            poisoned.into_inner()
        }
    };

    apply_temp_dir(&value)
}

/// 校验临时目录路径并转换为 `PathBuf`。
fn validate_temp_dir(raw: &str) -> Result<PathBuf, String> {
    if raw.is_empty() {
        return Err("temp dir path is empty".to_string());
    }
    if raw.trim().is_empty() {
        return Err("temp dir path is blank".to_string());
    }
    if raw.trim() != raw {
        return Err(format!(
            "temp dir path must not have leading or trailing whitespace: '{raw}'"
        ));
    }
    if raw.contains('\0') {
        return Err("temp dir path must not contain a NUL character".to_string());
    }

    let path = PathBuf::from(raw);
    if !path.is_absolute() {
        return Err(format!("temp dir path must be absolute: '{raw}'"));
    }
    Ok(path)
}

/// 创建目录并确认目标确实是目录。
fn ensure_temp_dir(path: &Path) -> Result<PathBuf, String> {
    std::fs::create_dir_all(path)
        .map_err(|err| format!("failed to create temp dir '{}': {err}", path.display()))?;

    let metadata = std::fs::metadata(path)
        .map_err(|err| format!("failed to inspect temp dir '{}': {err}", path.display()))?;
    if !metadata.is_dir() {
        return Err(format!(
            "temp dir path is not a directory: '{}'",
            path.display()
        ));
    }

    Ok(path.to_path_buf())
}

/// 写入三个环境变量；失败时恢复调用前的值。
fn apply_temp_dir(value: &str) -> Result<(), String> {
    let previous: Vec<(&'static str, Option<OsString>)> = TEMP_ENV_KEYS
        .iter()
        .map(|key| (*key, std::env::var_os(*key)))
        .collect();

    // 当前 crate 为 edition 2021，`std::env::set_var` 是安全函数；升级到
    // edition 2024 时此处需要改为 unsafe，并由 TEMP_DIR_LOCK 保证不与其他
    // 环境变量写入并发。catch_unwind 兜住 NUL 字符等触发 panic 的输入，
    // 避免 panic 穿透 FFI 边界。
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        for key in TEMP_ENV_KEYS {
            std::env::set_var(key, value);
        }
    }));

    match outcome {
        Ok(()) => {
            log::info!(target: "app_env", "process temp dir set to '{value}'");
            Ok(())
        }
        Err(payload) => {
            restore_temp_env(&previous);
            let reason = panic_message(payload);
            log::warn!(
                target: "app_env",
                "failed to set process temp dir to '{value}': {reason}"
            );
            Err(format!(
                "failed to set process temp dir to '{value}': {reason}"
            ))
        }
    }
}

/// 恢复调用前的环境变量值；`None` 表示该变量原本不存在。
fn restore_temp_env(previous: &[(&'static str, Option<OsString>)]) {
    for (key, old_value) in previous {
        let outcome =
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| match old_value {
                Some(value) => std::env::set_var(*key, value),
                None => std::env::remove_var(*key),
            }));
        if outcome.is_err() {
            log::warn!(target: "app_env", "failed to restore environment variable '{key}'");
        }
    }
}

/// 提取 panic 载荷中的可读信息。
fn panic_message(payload: Box<dyn std::any::Any + Send>) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_string()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "unknown panic".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::{ensure_temp_dir, validate_temp_dir};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static TEST_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    fn unique_test_dir() -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let sequence = TEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "pure_music_app_env_test_{}_{}_{}",
            std::process::id(),
            nanos,
            sequence
        ))
    }

    #[test]
    fn rejects_empty_path() {
        let err = validate_temp_dir("").unwrap_err();
        assert!(err.contains("empty"), "unexpected error: {err}");
    }

    #[test]
    fn rejects_blank_path() {
        let err = validate_temp_dir("   ").unwrap_err();
        assert!(err.contains("blank"), "unexpected error: {err}");
    }

    #[test]
    fn rejects_relative_path() {
        for raw in ["relative/temp", "C:temp", r"\temp", "."] {
            let err = validate_temp_dir(raw).unwrap_err();
            assert!(err.contains("absolute"), "unexpected error for {raw}: {err}");
        }
    }

    #[test]
    fn rejects_nul_character() {
        let err = validate_temp_dir("C:\\temp\0cache").unwrap_err();
        assert!(err.contains("NUL"), "unexpected error: {err}");
    }

    #[test]
    fn rejects_surrounding_whitespace() {
        let err = validate_temp_dir(" C:\\temp ").unwrap_err();
        assert!(err.contains("whitespace"), "unexpected error: {err}");
    }

    #[test]
    fn accepts_absolute_path() {
        let expected = unique_test_dir();
        let validated = validate_temp_dir(&expected.to_string_lossy()).expect("absolute path");
        assert_eq!(validated, expected);
    }

    #[test]
    fn creates_missing_directory_tree() {
        let root = unique_test_dir();
        let target = root.join("nested").join("cache");
        let created = ensure_temp_dir(&target).expect("create temp dir");
        assert!(created.is_dir());
        std::fs::remove_dir_all(&root).expect("remove test temp dir");
    }

    #[test]
    fn ensure_rejects_existing_file() {
        let root = unique_test_dir();
        std::fs::create_dir_all(&root).expect("create test root");
        let file = root.join("blocker");
        std::fs::write(&file, b"not a directory").expect("write blocker file");
        let err = ensure_temp_dir(&file).unwrap_err();
        assert!(err.contains("blocker"), "unexpected error: {err}");
        std::fs::remove_dir_all(&root).expect("remove test temp dir");
    }
}
