//! 日语歌词行的罗马音转换。
//!
//! 引擎为进程内单例：首次调用时加载内置 IPADIC（约 1 毫秒），初始化失败的结果同样
//! 被缓存，后续调用直接返回同一条可读错误。每行文本的转换结果缓存在 `HashMap` 中，
//! 上限 4096 条，超限时丢弃一半条目。
//!
//! 只有含假名（或日文特有标记 々 〆 〇）的连续片段参与转换；`include_kanji_only`
//! 为真时纯 CJK 汉字片段也参与转换。英文、韩文、数字与符号在任何开关下都被丢弃，
//! 多个片段之间以一个空格连接。
//!
//! 输出布局为 `Mode::Spaced`：片段内部还会按形态素边界插入空格，助词独立成词，
//! 例如 `東京へ行こう` 输出 `toukyou e ikou`。

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

use sabiyomi::{LongVowels, Mode, Options, RomajiSystem, Sabiyomi, Target};

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
/// 输出按形态素分词、以空格分隔，例如 `東京へ行こう` 得到 `toukyou e ikou`；
/// 同一行内的多个日文片段之间同样以空格连接。
///
/// `include_kanji_only` 为 true 时，纯 CJK 汉字片段也交给引擎转换；为 false 时
/// 只有含假名（或 々 〆 〇）的片段参与转换。纯中文行在 false 时返回空串，
/// 在 true 时由引擎决定返回空串或读音。
///
/// 每个输入行独立处理：单行转换失败时记录 WARN（只带文本长度，不打印歌词）
/// 并返回空串，不中断整批。
///
/// # 错误
///
/// 引擎初始化失败时返回可读错误，此时整批都不产生结果。
pub fn romanize_japanese_texts(
    texts: Vec<String>,
    include_kanji_only: bool,
) -> Result<Vec<String>, String> {
    let engine = engine()?;
    let opts = options();
    Ok(texts
        .iter()
        .map(|text| romanize_line(engine, &opts, text, include_kanji_only))
        .collect())
}

fn options() -> Options {
    Options {
        to: Target::Romaji,
        // 按形态素边界分词输出，助词独立成词，避免整行连写。
        mode: Mode::Spaced,
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

fn romanize_line(
    engine: &Sabiyomi,
    opts: &Options,
    text: &str,
    include_kanji_only: bool,
) -> String {
    if text.is_empty() {
        return String::new();
    }
    let key = cache_key(include_kanji_only, text);
    if let Some(cached) = cache_get(&key) {
        return cached;
    }
    match convert_japanese_runs(engine, opts, text, include_kanji_only) {
        Ok(romaji) => {
            cache_put(&key, &romaji);
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

/// 缓存键包含开关，避免 `false` 的空结果污染 `true` 的查询。
fn cache_key(include_kanji_only: bool, text: &str) -> String {
    format!("{include_kanji_only}\u{0}{text}")
}

/// 扫描整行，按开关决定纯汉字片段是否参与转换。
fn convert_japanese_runs(
    engine: &Sabiyomi,
    opts: &Options,
    text: &str,
    include_kanji_only: bool,
) -> Result<String, String> {
    let mut output = String::new();
    let mut run_start: Option<usize> = None;
    let mut run_has_marker = false;

    for (index, ch) in text.char_indices() {
        if is_japanese_char(ch) {
            if run_start.is_none() {
                run_start = Some(index);
            }
            run_has_marker |= is_japanese_marker(ch);
            continue;
        }
        if let Some(start) = run_start.take() {
            push_run(
                engine,
                opts,
                text,
                start,
                index,
                run_has_marker || include_kanji_only,
                &mut output,
            )?;
            run_has_marker = false;
        }
    }
    if let Some(start) = run_start {
        push_run(
            engine,
            opts,
            text,
            start,
            text.len(),
            run_has_marker || include_kanji_only,
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
    should_convert: bool,
    output: &mut String,
) -> Result<(), String> {
    if !should_convert {
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

fn cache_get(key: &str) -> Option<String> {
    let cache = cache().lock().unwrap_or_else(|err| err.into_inner());
    cache.get(key).cloned()
}

fn cache_put(key: &str, romaji: &str) {
    let mut cache = cache().lock().unwrap_or_else(|err| err.into_inner());
    if cache.len() >= CACHE_LIMIT && !cache.contains_key(key) {
        let remove_count = cache.len() / 2;
        let keys: Vec<String> = cache.keys().take(remove_count).cloned().collect();
        for key in keys {
            cache.remove(&key);
        }
    }
    cache.insert(key.to_string(), romaji.to_string());
}

#[cfg(test)]
pub(crate) fn cache_contains(text: &str, include_kanji_only: bool) -> bool {
    let key = cache_key(include_kanji_only, text);
    let cache = cache().lock().unwrap_or_else(|err| err.into_inner());
    cache.contains_key(&key)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn romanize(text: &str) -> String {
        romanize_with(text, false)
    }

    fn romanize_with(text: &str, include_kanji_only: bool) -> String {
        romanize_japanese_texts(vec![text.to_string()], include_kanji_only)
            .expect("引擎初始化不应失败")
            .remove(0)
    }

    #[test]
    fn converts_kanji_with_kana() {
        assert_eq!(romanize("君の名前"), "kimi no namae");
    }

    #[test]
    fn spells_long_vowels() {
        // とうきょう + へ(助词读 e) + いこう，按形态素以空格分隔。
        assert_eq!(romanize("東京へ行こう"), "toukyou e ikou");
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
        assert!(cache_contains(text, false), "首次转换应写入缓存");
        let second = romanize(text);
        assert_eq!(first, second);
        assert_eq!(second, "sakura no hana");
    }

    #[test]
    fn keeps_only_japanese_runs_in_mixed_line() {
        // 拉丁字母、数字与非日文内容被丢弃，只输出日文片段的罗马音。
        assert_eq!(romanize("hello 東京へ行こう 123"), "toukyou e ikou");
    }

    #[test]
    fn ignores_kanji_only_line_without_flag() {
        assert_eq!(romanize("東京"), "");
    }

    #[test]
    fn converts_kanji_only_line_with_flag() {
        // IPADIC 读作 とうきょう，Spelled 长音输出 "toukyou"；单个形态素不含空格。
        assert_eq!(romanize_with("東京", true), "toukyou");
    }

    #[test]
    fn reports_chinese_line_result_with_flag() {
        // 开关打开时纯中文行交给引擎决定：可能返回空串，也可能给出汉字读音。
        // Dart 侧只在整首判定为日语时才传 true，因此这里记录实际值、不做断言。
        let romaji = romanize_with("你好", true);
        println!("你好(include_kanji_only=true) -> {romaji}");
    }

    #[test]
    fn cache_separates_kanji_only_flag() {
        let text = "東京";
        assert_eq!(romanize_with(text, false), "");
        assert!(cache_contains(text, false), "false 查询应写入缓存");
        let converted = romanize_with(text, true);
        assert!(!converted.is_empty(), "true 不应复用 false 的空结果");
        assert!(cache_contains(text, true), "true 查询应写入独立缓存键");
    }

    #[test]
    fn warmup_is_idempotent() {
        romanizer_warmup().expect("引擎预热不应失败");
        romanizer_warmup().expect("重复预热不应失败");
    }
}
