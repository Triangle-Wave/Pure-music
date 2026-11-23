//! 日语歌词行的罗马音转换。
//!
//! 引擎为进程内单例：首次调用时加载内置 IPADIC（约 1 毫秒），初始化失败的结果同样
//! 被缓存，后续调用直接返回同一条可读错误。每行文本的转换结果缓存在 `HashMap` 中，
//! 上限 4096 条，超限时丢弃一半条目。
//!
//! 只有含假名（或日文特有标记 々 〆 〇）的连续片段参与转换：纯中文、英文、
//! 韩文、数字与符号被丢弃，因此非日文行返回空串。多个片段之间以一个空格连接。

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

use sabiyomi::{LongVowels, Options, RomajiSystem, Sabiyomi, Target};

/// 行级缓存条目上限，超过后丢弃一半。
const CACHE_LIMIT: usize = 4096;

type Engine = Result<Sabiyomi, String>;

static ENGINE: OnceLock<Engine> = OnceLock::new();
static CACHE: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();

/// 初始化日语罗马音引擎，供应用启动时预热。
///
/// 重复调用只读取已初始化的单例，不重复加载词典。
pub fn romanizer_warmup() -> Result<(), String> {
    engine().map(|_| ())
}

/// 把若干行歌词转换为罗马音。
///
/// 每个输入行独立处理：不含假名的行返回空串；单行转换失败时记录 WARN
/// （只带文本长度，不打印歌词）并返回空串，不中断整批。
///
/// # 错误
///
/// 引擎初始化失败时返回可读错误，此时整批都不产生结果。
pub fn romanize_japanese_texts(texts: Vec<String>) -> Result<Vec<String>, String> {
    let engine = engine()?;
    let opts = options();
    Ok(texts
        .iter()
        .map(|text| romanize_line(engine, &opts, text))
        .collect())
}

fn options() -> Options {
    Options {
        to: Target::Romaji,
        long_vowels: Some(LongVowels::Spelled),
        system: RomajiSystem::Hepburn,
        ..Options::default()
    }
}

fn engine() -> Result<&'static Sabiyomi, String> {
    let engine = ENGINE.get_or_init(|| {
        let started = Instant::now();
        match Sabiyomi::new() {
            Ok(engine) => {
                log::info!(
                    target: "lyric",
                    "日语罗马音引擎初始化完成，耗时 {:.2} ms",
                    started.elapsed().as_secs_f64() * 1000.0
                );
                Ok(engine)
            }
            Err(err) => {
                let message = format!("日语罗马音引擎初始化失败：{err}");
                log::error!(target: "lyric", "{message}");
                Err(message)
            }
        }
    });
    engine.as_ref().map_err(|message| message.clone())
}

fn romanize_line(engine: &Sabiyomi, opts: &Options, text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }
    if let Some(cached) = cache_get(text) {
        return cached;
    }
    match convert_japanese_runs(engine, opts, text) {
        Ok(romaji) => {
            cache_put(text, &romaji);
            romaji
        }
        Err(err) => {
            log::warn!(
                target: "lyric",
                "歌词行罗马音转换失败，长度 {} 字符：{}",
                text.chars().count(),
                err
            );
            String::new()
        }
    }
}

/// 扫描整行，只转换含假名（或日文特有标记）的连续日文片段。
fn convert_japanese_runs(engine: &Sabiyomi, opts: &Options, text: &str) -> Result<String, String> {
    let mut output = String::new();
    let mut run_start: Option<usize> = None;
    let mut run_is_japanese = false;

    for (index, ch) in text.char_indices() {
        if is_japanese_char(ch) {
            if run_start.is_none() {
                run_start = Some(index);
            }
            run_is_japanese |= is_japanese_marker(ch);
            continue;
        }
        if let Some(start) = run_start.take() {
            push_run(
                engine,
                opts,
                text,
                start,
                index,
                run_is_japanese,
                &mut output,
            )?;
            run_is_japanese = false;
        }
    }
    if let Some(start) = run_start {
        push_run(
            engine,
            opts,
            text,
            start,
            text.len(),
            run_is_japanese,
            &mut output,
        )?;
    }
    Ok(output)
}

fn push_run(
    engine: &Sabiyomi,
    opts: &Options,
    text: &str,
    start: usize,
    end: usize,
    is_japanese: bool,
    output: &mut String,
) -> Result<(), String> {
    if !is_japanese {
        return Ok(());
    }
    let fragment = &text[start..end];
    let converted = engine
        .convert(fragment, opts)
        .map_err(|err| format!("日文片段转换失败：{err}"))?;
    let converted = converted.trim();
    if converted.is_empty() {
        return Ok(());
    }
    if !output.is_empty() {
        output.push(' ');
    }
    output.push_str(converted);
    Ok(())
}

/// 平假名、片假名与半角片假名（含长音符 30FC）。
fn is_kana(ch: char) -> bool {
    matches!(
        ch,
        '\u{3041}'..='\u{309F}'      // 平假名
            | '\u{30A1}'..='\u{30FF}' // 片假名（含长音符 30FC）
            | '\u{31F0}'..='\u{31FF}' // 片假名扩展
            | '\u{FF66}'..='\u{FF9D}' // 半角片假名
    )
}

/// 判断字符是否足以把片段认定为日文：假名，或日文特有的 々 〆 〇。
fn is_japanese_marker(ch: char) -> bool {
    is_kana(ch) || matches!(ch, '\u{3005}' | '\u{3006}' | '\u{3007}')
}

fn is_japanese_char(ch: char) -> bool {
    is_japanese_marker(ch) || is_cjk_ideograph(ch)
}

fn is_cjk_ideograph(ch: char) -> bool {
    matches!(
        ch,
        '\u{3400}'..='\u{4DBF}'       // 扩展 A
            | '\u{4E00}'..='\u{9FFF}' // 基本区
            | '\u{F900}'..='\u{FAFF}' // 兼容表意文字
            | '\u{20000}'..='\u{2FA1F}' // 扩展 B 及以后
    )
}

fn cache() -> &'static Mutex<HashMap<String, String>> {
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn cache_get(text: &str) -> Option<String> {
    let cache = cache().lock().unwrap_or_else(|err| err.into_inner());
    cache.get(text).cloned()
}

fn cache_put(text: &str, romaji: &str) {
    let mut cache = cache().lock().unwrap_or_else(|err| err.into_inner());
    if cache.len() >= CACHE_LIMIT && !cache.contains_key(text) {
        let remove_count = cache.len() / 2;
        let keys: Vec<String> = cache.keys().take(remove_count).cloned().collect();
        for key in keys {
            cache.remove(&key);
        }
    }
    cache.insert(text.to_string(), romaji.to_string());
}

#[cfg(test)]
pub(crate) fn cache_contains(text: &str) -> bool {
    let cache = cache().lock().unwrap_or_else(|err| err.into_inner());
    cache.contains_key(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn romanize(text: &str) -> String {
        romanize_japanese_texts(vec![text.to_string()])
            .expect("引擎初始化不应失败")
            .remove(0)
    }

    #[test]
    fn converts_kanji_with_kana() {
        assert_eq!(romanize("君の名前"), "kiminonamae");
    }

    #[test]
    fn spells_long_vowels() {
        // とうきょう + へ(助词读 e) + いこう
        assert_eq!(romanize("東京へ行こう"), "toukyoueikou");
    }

    #[test]
    fn ignores_chinese_only_line() {
        assert_eq!(romanize("你好"), "");
    }

    #[test]
    fn ignores_english_only_line() {
        assert_eq!(romanize("hello"), "");
    }

    #[test]
    fn ignores_empty_line() {
        assert_eq!(romanize(""), "");
    }

    #[test]
    fn ignores_digits_and_symbols() {
        assert_eq!(romanize("1234!?"), "");
    }

    #[test]
    fn reuses_cached_line() {
        let text = "桜の花";
        let first = romanize(text);
        assert!(cache_contains(text), "首次转换应写入缓存");
        let second = romanize(text);
        assert_eq!(first, second);
        assert_eq!(second, "sakuranohana");
    }

    #[test]
    fn keeps_only_japanese_runs_in_mixed_line() {
        // 拉丁字母、数字与非日文内容被丢弃，只输出日文片段的罗马音。
        assert_eq!(romanize("hello 東京へ行こう 123"), "toukyoueikou");
    }

    #[test]
    fn warmup_is_idempotent() {
        romanizer_warmup().expect("引擎预热不应失败");
        romanizer_warmup().expect("重复预热不应失败");
    }
}
