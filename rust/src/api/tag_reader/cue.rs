#![allow(dead_code)]

use std::fmt;
use std::path::Path;

const DEFAULT_LINE_ENDING: &str = "\r\n";
const FRAMES_PER_SECOND: u64 = 75;
const UTF8_BOM: [u8; 3] = [0xEF, 0xBB, 0xBF];
const UTF16_LE_BOM: [u8; 2] = [0xFF, 0xFE];
const UTF16_BE_BOM: [u8; 2] = [0xFE, 0xFF];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CueEncoding {
    Utf8Bom,
    Utf8,
    Gbk,
    ShiftJis,
    Utf16Le,
    Utf16Be,
}

impl CueEncoding {
    /// 按原编码输出文本；UTF-8 BOM 与 UTF-16 变体带上对应 BOM。
    pub(crate) fn encode(&self, text: &str) -> Vec<u8> {
        match self {
            CueEncoding::Utf8Bom => {
                let mut bytes = Vec::with_capacity(UTF8_BOM.len() + text.len());
                bytes.extend_from_slice(&UTF8_BOM);
                bytes.extend_from_slice(text.as_bytes());
                bytes
            }
            CueEncoding::Utf8 => text.as_bytes().to_vec(),
            CueEncoding::Gbk => encoding_rs::GBK.encode(text).0.into_owned(),
            CueEncoding::ShiftJis => encoding_rs::SHIFT_JIS.encode(text).0.into_owned(),
            CueEncoding::Utf16Le => encode_utf16(text, true),
            CueEncoding::Utf16Be => encode_utf16(text, false),
        }
    }

    pub(crate) fn label(&self) -> &'static str {
        match self {
            CueEncoding::Utf8Bom => "UTF-8 BOM",
            CueEncoding::Utf8 => "UTF-8",
            CueEncoding::Gbk => "GBK",
            CueEncoding::ShiftJis => "Shift-JIS",
            CueEncoding::Utf16Le => "UTF-16 LE",
            CueEncoding::Utf16Be => "UTF-16 BE",
        }
    }
}

fn encode_utf16(text: &str, little_endian: bool) -> Vec<u8> {
    let bom = if little_endian {
        UTF16_LE_BOM
    } else {
        UTF16_BE_BOM
    };
    let mut bytes = Vec::with_capacity(bom.len() + text.len() * 2);
    bytes.extend_from_slice(&bom);
    for unit in text.encode_utf16() {
        let pair = if little_endian {
            unit.to_le_bytes()
        } else {
            unit.to_be_bytes()
        };
        bytes.extend_from_slice(&pair);
    }
    bytes
}

#[derive(Debug, Clone)]
pub(crate) struct CueSheet {
    pub(crate) title: Option<String>,
    pub(crate) performer: Option<String>,
    pub(crate) genre: Option<String>,
    pub(crate) date: Option<String>,
    pub(crate) catalog: Option<String>,
    pub(crate) files: Vec<CueFile>,
    pub(crate) tracks: Vec<CueTrack>,
    pub(crate) encoding: CueEncoding,
    pub(crate) line_ending: String,
    pub(crate) warnings: Vec<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct CueFile {
    pub(crate) name: String,
    pub(crate) file_type: Option<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct CueTrack {
    pub(crate) number: u32,
    pub(crate) kind: String,
    pub(crate) title: Option<String>,
    pub(crate) performer: Option<String>,
    pub(crate) songwriter: Option<String>,
    pub(crate) isrc: Option<String>,
    pub(crate) file_index: usize,
    pub(crate) index00_ms: Option<u64>,
    /// INDEX 01 缺失时为 None，消费方按 INDEX 00 或 0 兜底。
    pub(crate) index01_ms: Option<u64>,
    pub(crate) pregap_ms: Option<u64>,
    pub(crate) postgap_ms: Option<u64>,
}

#[derive(Debug)]
pub(crate) enum CueError {
    Io(std::io::Error),
    Decode,
    Syntax { line: usize, message: String },
    NoTracks,
    TrackBeforeFile,
}

impl fmt::Display for CueError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CueError::Io(error) => write!(formatter, "io error: {error}"),
            CueError::Decode => write!(formatter, "unsupported or invalid text encoding"),
            CueError::Syntax { line, message } => {
                write!(formatter, "syntax error at line {line}: {message}")
            }
            CueError::NoTracks => write!(formatter, "cue sheet contains no tracks"),
            CueError::TrackBeforeFile => write!(formatter, "TRACK appears before FILE"),
        }
    }
}

impl std::error::Error for CueError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            CueError::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<std::io::Error> for CueError {
    fn from(error: std::io::Error) -> Self {
        CueError::Io(error)
    }
}

/// 扩展名是否为 cue，大小写不敏感。
pub(crate) fn is_cue_path(path: &Path) -> bool {
    path.extension()
        .is_some_and(|extension| extension.eq_ignore_ascii_case("cue"))
}

pub(crate) fn parse_cue_file(path: &Path) -> Result<CueSheet, CueError> {
    let bytes = std::fs::read(path)?;
    parse_cue_bytes(&bytes)
}

pub(crate) fn parse_cue_bytes(bytes: &[u8]) -> Result<CueSheet, CueError> {
    let (text, encoding) = decode_cue_bytes(bytes)?;
    let mut sheet = CueSheet {
        title: None,
        performer: None,
        genre: None,
        date: None,
        catalog: None,
        files: Vec::new(),
        tracks: Vec::new(),
        encoding,
        line_ending: detect_line_ending(&text),
        warnings: Vec::new(),
    };
    let mut current_file = None;
    let lines = split_lines(&text);

    for (index, raw_line) in lines.iter().enumerate() {
        let line_number = index + 1;
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        let (keyword, rest) = split_keyword(line);
        match keyword.to_ascii_uppercase().as_str() {
            "FILE" => {
                let (name, file_type) = parse_file_args(rest, line_number)?;
                sheet.files.push(CueFile { name, file_type });
                current_file = Some(sheet.files.len() - 1);
            }
            "TRACK" => {
                let Some(file_index) = current_file else {
                    return Err(CueError::TrackBeforeFile);
                };
                let (number, kind) = parse_track_args(rest, line_number)?;
                sheet.tracks.push(CueTrack {
                    number,
                    kind,
                    title: None,
                    performer: None,
                    songwriter: None,
                    isrc: None,
                    file_index,
                    index00_ms: None,
                    index01_ms: None,
                    pregap_ms: None,
                    postgap_ms: None,
                });
            }
            "INDEX" => {
                let Some(track) = sheet.tracks.last_mut() else {
                    continue;
                };
                if let Some((number, time)) = parse_index_args(rest, line_number)? {
                    match number {
                        0 => track.index00_ms = Some(time),
                        1 => track.index01_ms = Some(time),
                        _ => {}
                    }
                }
            }
            "PREGAP" | "POSTGAP" => {
                let Some(track) = sheet.tracks.last_mut() else {
                    continue;
                };
                let time = parse_timestamp(rest.trim(), line_number)?;
                if keyword.eq_ignore_ascii_case("PREGAP") {
                    track.pregap_ms = Some(time);
                } else {
                    track.postgap_ms = Some(time);
                }
            }
            "TITLE" => {
                let value = parse_text_value(rest, line_number)?;
                if sheet.tracks.is_empty() {
                    sheet.title = Some(value);
                } else if let Some(track) = sheet.tracks.last_mut() {
                    track.title = Some(value);
                }
            }
            "PERFORMER" => {
                let value = parse_text_value(rest, line_number)?;
                if sheet.tracks.is_empty() {
                    sheet.performer = Some(value);
                } else if let Some(track) = sheet.tracks.last_mut() {
                    track.performer = Some(value);
                }
            }
            "SONGWRITER" => {
                let value = parse_text_value(rest, line_number)?;
                if let Some(track) = sheet.tracks.last_mut() {
                    track.songwriter = Some(value);
                }
            }
            "ISRC" => {
                let value = parse_text_value(rest, line_number)?;
                if let Some(track) = sheet.tracks.last_mut() {
                    track.isrc = Some(value);
                }
            }
            "CATALOG" => {
                sheet.catalog = Some(parse_text_value(rest, line_number)?);
            }
            "REM" => {
                let (rem_key, rem_value) = split_keyword(rest);
                match rem_key.to_ascii_uppercase().as_str() {
                    "GENRE" => sheet.genre = Some(parse_text_value(rem_value, line_number)?),
                    "DATE" => sheet.date = Some(parse_text_value(rem_value, line_number)?),
                    _ => {}
                }
            }
            _ => {}
        }
    }

    if sheet.tracks.is_empty() {
        return Err(CueError::NoTracks);
    }
    let missing_index: Vec<String> = sheet
        .tracks
        .iter()
        .filter(|track| track.index01_ms.is_none())
        .map(|track| format!("track {}: missing INDEX 01", track.number))
        .collect();
    sheet.warnings.extend(missing_index);
    Ok(sheet)
}

fn decode_cue_bytes(bytes: &[u8]) -> Result<(String, CueEncoding), CueError> {
    if bytes.starts_with(&UTF8_BOM) {
        let text = std::str::from_utf8(&bytes[UTF8_BOM.len()..]).map_err(|_| CueError::Decode)?;
        return Ok((text.to_string(), CueEncoding::Utf8Bom));
    }
    if bytes.starts_with(&UTF16_LE_BOM) {
        let (text, had_errors) =
            encoding_rs::UTF_16LE.decode_with_bom_removal(&bytes[UTF16_LE_BOM.len()..]);
        if had_errors {
            return Err(CueError::Decode);
        }
        return Ok((text.into_owned(), CueEncoding::Utf16Le));
    }
    if bytes.starts_with(&UTF16_BE_BOM) {
        let (text, had_errors) =
            encoding_rs::UTF_16BE.decode_with_bom_removal(&bytes[UTF16_BE_BOM.len()..]);
        if had_errors {
            return Err(CueError::Decode);
        }
        return Ok((text.into_owned(), CueEncoding::Utf16Be));
    }
    if let Ok(text) = std::str::from_utf8(bytes) {
        return Ok((text.to_string(), CueEncoding::Utf8));
    }
    let (text, _, had_errors) = encoding_rs::GBK.decode(bytes);
    if !had_errors {
        return Ok((text.into_owned(), CueEncoding::Gbk));
    }
    let (text, _, had_errors) = encoding_rs::SHIFT_JIS.decode(bytes);
    if !had_errors {
        return Ok((text.into_owned(), CueEncoding::ShiftJis));
    }
    Err(CueError::Decode)
}

fn detect_line_ending(text: &str) -> String {
    let bytes = text.as_bytes();
    for (index, byte) in bytes.iter().enumerate() {
        match *byte {
            b'\r' => {
                let ending = if bytes.get(index + 1) == Some(&b'\n') {
                    "\r\n"
                } else {
                    "\r"
                };
                return ending.to_string();
            }
            b'\n' => return "\n".to_string(),
            _ => {}
        }
    }
    DEFAULT_LINE_ENDING.to_string()
}

fn split_lines(text: &str) -> Vec<&str> {
    let bytes = text.as_bytes();
    let mut lines = Vec::new();
    let mut start = 0;
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'\r' => {
                lines.push(&text[start..index]);
                index += 1;
                if bytes.get(index) == Some(&b'\n') {
                    index += 1;
                }
                start = index;
            }
            b'\n' => {
                lines.push(&text[start..index]);
                index += 1;
                start = index;
            }
            _ => index += 1,
        }
    }
    if start < text.len() {
        lines.push(&text[start..]);
    }
    lines
}

fn split_keyword(line: &str) -> (&str, &str) {
    match line.find(char::is_whitespace) {
        Some(index) => (&line[..index], line[index..].trim_start()),
        None => (line, ""),
    }
}

fn parse_file_args(text: &str, line: usize) -> Result<(String, Option<String>), CueError> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err(syntax(line, "FILE requires a name"));
    }
    if trimmed.starts_with('"') {
        let Some((name, tail)) = parse_quoted_prefix(trimmed) else {
            return Err(syntax(line, "unterminated quoted string"));
        };
        if name.is_empty() {
            return Err(syntax(line, "FILE requires a name"));
        }
        return Ok((name, tail.split_whitespace().next().map(str::to_string)));
    }
    let mut parts = trimmed.split_whitespace();
    let Some(name) = parts.next() else {
        return Err(syntax(line, "FILE requires a name"));
    };
    Ok((name.to_string(), parts.next().map(str::to_string)))
}

fn parse_quoted_prefix(text: &str) -> Option<(String, &str)> {
    let content = text.strip_prefix('"')?;
    let mut value = String::with_capacity(content.len());
    let mut escaped = false;
    for (index, ch) in content.char_indices() {
        if escaped {
            if ch == '"' {
                value.push('"');
            } else {
                value.push('\\');
                value.push(ch);
            }
            escaped = false;
            continue;
        }
        match ch {
            '\\' => escaped = true,
            '"' => return Some((value, &content[index + 1..])),
            _ => value.push(ch),
        }
    }
    None
}

fn parse_text_value(text: &str, line: usize) -> Result<String, CueError> {
    let trimmed = text.trim();
    let Some(first) = trimmed.find('"') else {
        return Ok(trimmed.to_string());
    };
    let content = &trimmed[first + 1..];
    let Some(last) = content.rfind('"') else {
        return Err(syntax(line, "unterminated quoted string"));
    };
    Ok(unescape_quotes(&content[..last]))
}

fn unescape_quotes(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\\' && chars.peek() == Some(&'"') {
            chars.next();
            result.push('"');
        } else {
            result.push(ch);
        }
    }
    result
}

fn parse_track_args(text: &str, line: usize) -> Result<(u32, String), CueError> {
    let mut parts = text.split_whitespace();
    let Some(number) = parts.next() else {
        return Err(syntax(line, "TRACK requires a number"));
    };
    let number = number
        .parse::<u32>()
        .map_err(|_| syntax(line, format!("invalid TRACK number: {number}")))?;
    let Some(kind) = parts.next() else {
        return Err(syntax(line, "TRACK requires a type"));
    };
    Ok((number, kind.to_string()))
}

fn parse_index_args(text: &str, line: usize) -> Result<Option<(u32, u64)>, CueError> {
    let mut parts = text.split_whitespace();
    let Some(number) = parts.next() else {
        return Err(syntax(line, "INDEX requires a number"));
    };
    let number = number
        .parse::<u32>()
        .map_err(|_| syntax(line, format!("invalid INDEX number: {number}")))?;
    if number > 1 {
        return Ok(None);
    }
    let Some(timestamp) = parts.next() else {
        return Err(syntax(line, "INDEX requires a timestamp"));
    };
    let time = parse_timestamp(timestamp, line)?;
    Ok(Some((number, time)))
}

fn parse_timestamp(text: &str, line: usize) -> Result<u64, CueError> {
    let mut parts = text.split(':');
    let (Some(minutes), Some(seconds), Some(frames), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err(syntax(line, format!("invalid timestamp: {text}")));
    };
    let minutes = parse_time_part(minutes, line, text)?;
    let seconds = parse_time_part(seconds, line, text)?;
    let frames = parse_time_part(frames, line, text)?;
    if frames >= FRAMES_PER_SECOND {
        return Err(syntax(line, format!("frame out of range: {text}")));
    }
    minutes
        .checked_mul(60)
        .and_then(|value| value.checked_add(seconds))
        .and_then(|value| value.checked_mul(1000))
        .and_then(|value| value.checked_add(frames * 1000 / FRAMES_PER_SECOND))
        .ok_or_else(|| syntax(line, format!("timestamp overflow: {text}")))
}

fn parse_time_part(part: &str, line: usize, timestamp: &str) -> Result<u64, CueError> {
    part.parse::<u64>()
        .map_err(|_| syntax(line, format!("invalid timestamp: {timestamp}")))
}

fn syntax(line: usize, message: impl Into<String>) -> CueError {
    CueError::Syntax {
        line,
        message: message.into(),
    }
}

/// 由 CUE 展开的可播放段，起止时间以毫秒为单位。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CueSegment {
    pub(crate) file_index: usize,
    pub(crate) track_number: u32,
    pub(crate) title: Option<String>,
    pub(crate) performer: Option<String>,
    pub(crate) start_ms: u64,
    pub(crate) end_ms: u64,
}

impl CueSegment {
    /// 段时长；终点早于起点时饱和为 0。
    pub(crate) fn duration_ms(&self) -> u64 {
        self.end_ms.saturating_sub(self.start_ms)
    }
}

/// 轨道起点：优先 INDEX 01，其次 INDEX 00，两者都缺失时为 0。
fn track_start_ms(track: &CueTrack) -> u64 {
    track.index01_ms.or(track.index00_ms).unwrap_or(0)
}

/// 把 CUE 轨道展开为带起止时间的段，同时返回展开过程中的告警。
///
/// 段顺序与 `sheet.tracks` 一致，零长度段保留。终点无法确定时按起点收尾，
/// 由上层决定是否过滤。
pub(crate) fn expand_segments(
    sheet: &CueSheet,
    file_durations_ms: &[Option<u64>],
) -> (Vec<CueSegment>, Vec<String>) {
    let mut segments = Vec::with_capacity(sheet.tracks.len());
    let mut warnings = Vec::new();

    for (position, track) in sheet.tracks.iter().enumerate() {
        let start_ms = track_start_ms(track);
        let mut end_ms = start_ms;

        match sheet.tracks.get(position.saturating_add(1)) {
            Some(next) if next.file_index == track.file_index => {
                let next_start_ms = track_start_ms(next);
                if next_start_ms > start_ms {
                    end_ms = next_start_ms;
                } else {
                    warnings.push(format!(
                        "track {}: next track starts before current",
                        track.number
                    ));
                }
            }
            _ => {
                let file_duration_ms = file_durations_ms
                    .get(track.file_index)
                    .copied()
                    .flatten();
                match file_duration_ms {
                    Some(duration_ms) if duration_ms > start_ms => end_ms = duration_ms,
                    _ => warnings.push(format!("track {}: unknown end position", track.number)),
                }
            }
        }

        segments.push(CueSegment {
            file_index: track.file_index,
            track_number: track.number,
            title: track.title.clone(),
            performer: track.performer.clone(),
            start_ms,
            end_ms: end_ms.max(start_ms),
        });
    }

    (segments, warnings)
}

/// 归一化容器路径：反斜杠转斜杠、去掉尾部斜杠、转小写。
fn normalize_container_path(path: &str) -> String {
    let unified = path.replace('\\', "/");
    unified.trim_end_matches('/').to_lowercase()
}

/// 生成段在容器内的稳定标识，例如 `cue:music/album#01`。
pub(crate) fn segment_track_uid(container_path: &str, track_number: u32) -> String {
    format!(
        "cue:{}#{:02}",
        normalize_container_path(container_path),
        track_number
    )
}

/// 生成段作为曲库条目的合成路径，保留传入路径的原始形态。
pub(crate) fn segment_path(source_path: &str, track_number: u32) -> String {
    format!("{source_path}::track={track_number:02}")
}

/// 生成带段起止的合成路径，例如 `<source_path>::track=01::start=0::end=200000`。
///
/// `source_path` 原样保留，不改变大小写、分隔符、空格与中文字符。
pub(crate) fn segment_path_with_range(
    source_path: &str,
    track_number: u32,
    start_ms: u64,
    end_ms: u64,
) -> String {
    format!("{source_path}::track={track_number:02}::start={start_ms}::end={end_ms}")
}

/// 合成路径的解析结果，`source_path` 借用输入字符串。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ParsedSegmentPath<'a> {
    pub(crate) source_path: &'a str,
    pub(crate) track_number: u32,
    pub(crate) start_ms: u64,
    pub(crate) end_ms: u64,
}

/// 解析带段起止的合成路径；格式不符、数字非法或终点早于起点时返回 None。
pub(crate) fn parse_segment_path(path: &str) -> Option<ParsedSegmentPath<'_>> {
    // 源路径自身可能含 `::`，取最后一个标记作为段信息的起点。
    let marker_index = path.rfind("::track=")?;
    let (source_path, suffix) = path.split_at(marker_index);
    if source_path.is_empty() {
        return None;
    }
    let rest = suffix.strip_prefix("::")?;
    let mut parts = rest.split("::");
    let track_part = parts.next()?;
    let start_part = parts.next()?;
    let end_part = parts.next()?;
    // 后缀只允许三段，多余内容视为损坏的合成路径。
    if parts.next().is_some() {
        return None;
    }
    let track_number = track_part.strip_prefix("track=")?.parse::<u32>().ok()?;
    let start_ms = start_part.strip_prefix("start=")?.parse::<u64>().ok()?;
    let end_ms = end_part.strip_prefix("end=")?.parse::<u64>().ok()?;
    if end_ms < start_ms {
        return None;
    }
    Some(ParsedSegmentPath {
        source_path,
        track_number,
        start_ms,
        end_ms,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_ok(text: &str) -> CueSheet {
        parse_cue_bytes(text.as_bytes()).expect("cue should parse")
    }

    #[test]
    fn parses_utf8_bom_with_two_tracks() {
        let text = "\u{feff}TITLE \"专辑\"\r\nPERFORMER \"群星\"\r\nREM GENRE \"流行\"\r\nREM DATE 2024\r\nCATALOG 1234567890123\r\nFILE \"album.flac\" WAVE\r\n  TRACK 01 AUDIO\r\n    TITLE \"第一首\"\r\n    PERFORMER \"甲\"\r\n    SONGWRITER \"词曲\"\r\n    ISRC ABCDE1234567\r\n    INDEX 00 00:00:00\r\n    INDEX 01 00:00:02\r\n  TRACK 02 AUDIO\r\n    TITLE \"第二首\"\r\n    PERFORMER \"乙\"\r\n    INDEX 01 03:20:15\r\n";
        let sheet = parse_ok(text);
        assert_eq!(sheet.encoding, CueEncoding::Utf8Bom);
        assert_eq!(sheet.line_ending, "\r\n");
        assert_eq!(sheet.title.as_deref(), Some("专辑"));
        assert_eq!(sheet.performer.as_deref(), Some("群星"));
        assert_eq!(sheet.genre.as_deref(), Some("流行"));
        assert_eq!(sheet.date.as_deref(), Some("2024"));
        assert_eq!(sheet.catalog.as_deref(), Some("1234567890123"));
        assert_eq!(sheet.files.len(), 1);
        assert_eq!(sheet.files[0].name, "album.flac");
        assert_eq!(sheet.files[0].file_type.as_deref(), Some("WAVE"));
        assert_eq!(sheet.tracks.len(), 2);
        assert_eq!(sheet.tracks[0].number, 1);
        assert_eq!(sheet.tracks[0].kind, "AUDIO");
        assert_eq!(sheet.tracks[0].title.as_deref(), Some("第一首"));
        assert_eq!(sheet.tracks[0].performer.as_deref(), Some("甲"));
        assert_eq!(sheet.tracks[0].songwriter.as_deref(), Some("词曲"));
        assert_eq!(sheet.tracks[0].isrc.as_deref(), Some("ABCDE1234567"));
        assert_eq!(sheet.tracks[0].file_index, 0);
        assert_eq!(sheet.tracks[0].index00_ms, Some(0));
        assert_eq!(sheet.tracks[0].index01_ms, Some(26));
        assert_eq!(sheet.tracks[1].number, 2);
        assert_eq!(sheet.tracks[1].title.as_deref(), Some("第二首"));
        assert_eq!(sheet.tracks[1].index01_ms, Some(200_200));
        assert!(sheet.warnings.is_empty());
    }

    #[test]
    fn decodes_gbk_without_bom() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"TITLE \"");
        bytes.extend_from_slice(&[0xB2, 0xE2, 0xCA, 0xD4]);
        bytes.extend_from_slice(
            b"\"\r\nFILE \"album.flac\" WAVE\r\n  TRACK 01 AUDIO\r\n    TITLE \"track\"\r\n    INDEX 01 00:00:00\r\n",
        );
        let sheet = parse_cue_bytes(&bytes).expect("gbk cue should parse");
        assert_eq!(sheet.encoding, CueEncoding::Gbk);
        assert_eq!(sheet.title.as_deref(), Some("测试"));
        assert_eq!(sheet.tracks.len(), 1);
    }

    #[test]
    fn maps_tracks_to_nearest_file() {
        let text = "FILE \"disc1.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 01 01:00:00\nFILE \"disc2.flac\" WAVE\nTRACK 03 AUDIO\nINDEX 01 00:00:00\nTRACK 04 AUDIO\nINDEX 01 02:00:00\n";
        let sheet = parse_ok(text);
        assert_eq!(sheet.files.len(), 2);
        assert_eq!(sheet.files[0].name, "disc1.flac");
        assert_eq!(sheet.files[1].name, "disc2.flac");
        let indexes: Vec<usize> = sheet.tracks.iter().map(|track| track.file_index).collect();
        assert_eq!(indexes, vec![0, 0, 1, 1]);
    }

    #[test]
    fn parses_quoted_file_name_with_spaces() {
        let text = "FILE \"My Album (Deluxe).flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n";
        let sheet = parse_ok(text);
        assert_eq!(sheet.files.len(), 1);
        assert_eq!(sheet.files[0].name, "My Album (Deluxe).flac");
        assert_eq!(sheet.files[0].file_type.as_deref(), Some("WAVE"));
    }

    #[test]
    fn records_first_line_ending() {
        let crlf = parse_ok("FILE \"a.flac\" WAVE\r\nTRACK 01 AUDIO\r\nINDEX 01 00:00:00\r\n");
        assert_eq!(crlf.line_ending, "\r\n");
        let lf = parse_ok("FILE \"a.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n");
        assert_eq!(lf.line_ending, "\n");
        let cr = parse_ok("FILE \"a.flac\" WAVE\rTRACK 01 AUDIO\rINDEX 01 00:00:00\r");
        assert_eq!(cr.line_ending, "\r");
        assert_eq!(detect_line_ending("FILE \"a.flac\" WAVE"), DEFAULT_LINE_ENDING);
    }

    #[test]
    fn rejects_track_before_file() {
        let error = parse_cue_bytes(b"TRACK 01 AUDIO\nINDEX 01 00:00:00\n")
            .expect_err("track before file should fail");
        assert!(matches!(error, CueError::TrackBeforeFile));
    }

    #[test]
    fn keeps_track_without_index_01() {
        let sheet = parse_ok(
            "FILE \"a.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 00 00:00:30\nTRACK 02 AUDIO\n",
        );
        assert_eq!(sheet.tracks.len(), 2);
        assert_eq!(sheet.tracks[0].index00_ms, Some(400));
        assert_eq!(sheet.tracks[0].index01_ms, None);
        assert_eq!(sheet.tracks[1].index01_ms, None);
        assert_eq!(sheet.warnings.len(), 2);
        assert_eq!(sheet.warnings[0], "track 1: missing INDEX 01");
        assert_eq!(sheet.warnings[1], "track 2: missing INDEX 01");
    }

    #[test]
    fn converts_timestamp_to_milliseconds() {
        // (1 * 60 + 2) * 1000 + 3 * 1000 / 75 = 62040
        let sheet = parse_ok("FILE \"a.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 01:02:03\n");
        assert_eq!(sheet.tracks[0].index01_ms, Some(62_040));
    }

    #[test]
    fn rejects_frame_at_or_above_75() {
        let error = parse_cue_bytes(b"FILE \"a.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:75\n")
            .expect_err("invalid frame should fail");
        match error {
            CueError::Syntax { line, .. } => assert_eq!(line, 3),
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn empty_input_has_no_tracks() {
        assert!(matches!(parse_cue_bytes(b""), Err(CueError::NoTracks)));
    }

    #[test]
    fn encodes_utf8_bom_and_gbk() {
        let bom_bytes = CueEncoding::Utf8Bom.encode("测试");
        assert_eq!(&bom_bytes[..UTF8_BOM.len()], &UTF8_BOM);
        assert_eq!(&bom_bytes[UTF8_BOM.len()..], "测试".as_bytes());
        let gbk_bytes = CueEncoding::Gbk.encode("测试");
        assert_eq!(gbk_bytes, vec![0xB2, 0xE2, 0xCA, 0xD4]);
        let (decoded, _, had_errors) = encoding_rs::GBK.decode(&gbk_bytes);
        assert!(!had_errors);
        assert_eq!(&*decoded, "测试");
    }

    #[test]
    fn decodes_utf16_with_bom() {
        let text = "FILE \"a.flac\" WAVE\r\nTRACK 01 AUDIO\r\nINDEX 01 00:00:00\r\n";
        for (little_endian, encoding) in [
            (true, CueEncoding::Utf16Le),
            (false, CueEncoding::Utf16Be),
        ] {
            let bom = if little_endian {
                UTF16_LE_BOM
            } else {
                UTF16_BE_BOM
            };
            let mut bytes = bom.to_vec();
            for unit in text.encode_utf16() {
                let pair = if little_endian {
                    unit.to_le_bytes()
                } else {
                    unit.to_be_bytes()
                };
                bytes.extend_from_slice(&pair);
            }
            let sheet = parse_cue_bytes(&bytes).expect("utf16 cue should parse");
            assert_eq!(sheet.encoding, encoding);
            assert_eq!(sheet.tracks.len(), 1);
            assert_eq!(sheet.tracks[0].index01_ms, Some(0));
        }
    }

    #[test]
    fn rejects_unterminated_quote() {
        let error = parse_cue_bytes(
            b"FILE \"a.flac\" WAVE\nTRACK 01 AUDIO\nTITLE \"unfinished\nINDEX 01 00:00:00\n",
        )
        .expect_err("unterminated quote should fail");
        match error {
            CueError::Syntax { line, .. } => assert_eq!(line, 3),
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn ignores_unknown_directives_and_other_indexes() {
        let sheet = parse_ok(
            "FILE \"a.flac\" WAVE\nTRACK 01 AUDIO\nREM COMMENT ignored\nINDEX 02 00:01:00\nINDEX 01 00:00:00\n",
        );
        assert_eq!(sheet.tracks[0].index00_ms, None);
        assert_eq!(sheet.tracks[0].index01_ms, Some(0));
        assert!(sheet.warnings.is_empty());
    }

    #[test]
    fn parses_pregap_and_postgap() {
        let sheet = parse_ok(
            "FILE \"a.flac\" WAVE\nTRACK 01 AUDIO\nPREGAP 00:02:00\nPOSTGAP 00:01:30\nINDEX 01 00:00:00\n",
        );
        assert_eq!(sheet.tracks[0].pregap_ms, Some(2_000));
        assert_eq!(sheet.tracks[0].postgap_ms, Some(1_400));
    }

    #[test]
    fn expands_two_tracks_using_next_start_and_file_duration() {
        let text = "PERFORMER \"album artist\"\nFILE \"a.flac\" WAVE\nTRACK 01 AUDIO\nTITLE \"one\"\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nTITLE \"two\"\nINDEX 01 03:20:00\n";
        let sheet = parse_ok(text);
        let (segments, warnings) = expand_segments(&sheet, &[Some(240_000)]);

        assert!(warnings.is_empty());
        assert_eq!(segments.len(), 2);
        assert_eq!(segments[0].file_index, 0);
        assert_eq!(segments[0].track_number, 1);
        assert_eq!(segments[0].title.as_deref(), Some("one"));
        // 专辑级 PERFORMER 不回退到轨道段。
        assert!(segments[0].performer.is_none());
        assert_eq!(segments[0].start_ms, 0);
        assert_eq!(segments[0].end_ms, 200_000);
        assert_eq!(segments[0].duration_ms(), 200_000);
        assert_eq!(segments[1].track_number, 2);
        assert_eq!(segments[1].title.as_deref(), Some("two"));
        assert_eq!(segments[1].start_ms, 200_000);
        assert_eq!(segments[1].end_ms, 240_000);
        assert_eq!(segments[1].duration_ms(), 40_000);
    }

    #[test]
    fn last_track_without_file_duration_is_zero_length() {
        let text = "FILE \"a.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 02:00:00\n";
        let sheet = parse_ok(text);
        let empty: &[Option<u64>] = &[];
        let missing: &[Option<u64>] = &[None];
        for durations in [empty, missing] {
            let (segments, warnings) = expand_segments(&sheet, durations);
            assert_eq!(segments.len(), 1);
            assert_eq!(segments[0].start_ms, 120_000);
            assert_eq!(segments[0].end_ms, 120_000);
            assert_eq!(segments[0].duration_ms(), 0);
            assert_eq!(warnings, vec!["track 1: unknown end position"]);
        }
    }

    #[test]
    fn falls_back_to_index00_when_index01_missing() {
        let text = "FILE \"a.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 00 00:00:30\nTRACK 02 AUDIO\nINDEX 00 01:00:00\n";
        let sheet = parse_ok(text);
        let (segments, warnings) = expand_segments(&sheet, &[Some(90_000)]);

        assert!(warnings.is_empty());
        assert_eq!(segments.len(), 2);
        assert_eq!(segments[0].start_ms, 400);
        assert_eq!(segments[0].end_ms, 60_000);
        assert_eq!(segments[1].start_ms, 60_000);
        assert_eq!(segments[1].end_ms, 90_000);
    }

    #[test]
    fn expands_tracks_per_file_with_own_duration() {
        let text = "FILE \"disc1.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 01 01:00:00\nFILE \"disc2.flac\" WAVE\nTRACK 03 AUDIO\nINDEX 01 00:00:00\nTRACK 04 AUDIO\nINDEX 01 02:00:00\n";
        let sheet = parse_ok(text);
        let (segments, warnings) = expand_segments(&sheet, &[Some(120_000), Some(180_000)]);

        assert!(warnings.is_empty());
        assert_eq!(segments.len(), 4);
        let file_indexes: Vec<usize> = segments.iter().map(|segment| segment.file_index).collect();
        assert_eq!(file_indexes, vec![0, 0, 1, 1]);
        let tracks: Vec<u32> = segments.iter().map(|segment| segment.track_number).collect();
        assert_eq!(tracks, vec![1, 2, 3, 4]);
        let ranges: Vec<(u64, u64)> = segments
            .iter()
            .map(|segment| (segment.start_ms, segment.end_ms))
            .collect();
        assert_eq!(
            ranges,
            vec![
                (0, 60_000),
                (60_000, 120_000),
                (0, 120_000),
                (120_000, 180_000)
            ]
        );
    }

    #[test]
    fn keeps_zero_length_segment_when_next_track_starts_earlier() {
        let text = "FILE \"a.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:01:00\nTRACK 02 AUDIO\nINDEX 01 00:00:00\nTRACK 03 AUDIO\nINDEX 01 00:02:00\n";
        let sheet = parse_ok(text);
        let (segments, warnings) = expand_segments(&sheet, &[Some(300_000)]);

        assert_eq!(segments.len(), 3);
        assert_eq!(segments[0].start_ms, 1_000);
        assert_eq!(segments[0].end_ms, 1_000);
        assert_eq!(segments[1].start_ms, 0);
        assert_eq!(segments[1].end_ms, 2_000);
        assert_eq!(segments[2].start_ms, 2_000);
        assert_eq!(segments[2].end_ms, 300_000);
        assert_eq!(warnings, vec!["track 1: next track starts before current"]);
    }

    #[test]
    fn segment_duration_uses_saturating_subtraction() {
        let backwards = CueSegment {
            file_index: 0,
            track_number: 1,
            title: None,
            performer: None,
            start_ms: 2_000,
            end_ms: 500,
        };
        assert_eq!(backwards.duration_ms(), 0);

        let forward = CueSegment {
            file_index: 0,
            track_number: 1,
            title: None,
            performer: None,
            start_ms: 500,
            end_ms: 2_000,
        };
        assert_eq!(forward.duration_ms(), 1_500);
    }

    #[test]
    fn builds_segment_identity_and_path() {
        assert_eq!(segment_track_uid("Music\\Album\\", 1), "cue:music/album#01");
        assert_eq!(
            segment_track_uid("C:\\Music\\Album", 12),
            "cue:c:/music/album#12"
        );
        assert_eq!(
            segment_track_uid("Music/Album/", 123),
            "cue:music/album#123"
        );
        assert_eq!(
            segment_path("Music\\Album\\Track.flac", 1),
            "Music\\Album\\Track.flac::track=01"
        );
        assert_eq!(
            segment_path("D:\\Audio\\Track.FLAC", 100),
            "D:\\Audio\\Track.FLAC::track=100"
        );
    }

    #[test]
    fn file_duration_shorter_than_start_is_zero_length() {
        let text = "FILE \"a.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:01:00\n";
        let sheet = parse_ok(text);
        let (segments, warnings) = expand_segments(&sheet, &[Some(500)]);

        assert_eq!(segments.len(), 1);
        assert_eq!(segments[0].start_ms, 1_000);
        assert_eq!(segments[0].end_ms, 1_000);
        assert_eq!(segments[0].duration_ms(), 0);
        assert_eq!(warnings, vec!["track 1: unknown end position"]);
    }

    #[test]
    fn builds_and_parses_segment_path_with_range() {
        let source = "D:\\Music\\Album\\disc.flac";
        let path = segment_path_with_range(source, 2, 0, 200_000);
        let parsed = parse_segment_path(&path).expect("range path should parse");
        assert_eq!(parsed.source_path, source);
        assert_eq!(parsed.track_number, 2);
        assert_eq!(parsed.start_ms, 0);
        assert_eq!(parsed.end_ms, 200_000);
    }

    #[test]
    fn keeps_special_characters_in_range_source_path() {
        let source = "D:\\我的 音乐\\专辑 & 精选 [Disc 1]\\曲目.flac";
        let path = segment_path_with_range(source, 1, 1_500, 61_000);
        assert!(path.starts_with(source));
        let parsed = parse_segment_path(&path).expect("range path should parse");
        assert_eq!(parsed.source_path, source);
        assert_eq!(parsed.track_number, 1);
        assert_eq!(parsed.start_ms, 1_500);
        assert_eq!(parsed.end_ms, 61_000);
    }

    #[test]
    fn parses_three_digit_track_number_in_range() {
        let source = "C:\\Music\\Album\\disc.flac";
        let path = segment_path_with_range(source, 123, 0, 1);
        let parsed = parse_segment_path(&path).expect("range path should parse");
        assert_eq!(parsed.source_path, source);
        assert_eq!(parsed.track_number, 123);
        assert_eq!(parsed.start_ms, 0);
        assert_eq!(parsed.end_ms, 1);
    }

    #[test]
    fn rejects_path_without_track_marker() {
        assert!(parse_segment_path("D:\\Music\\Album\\disc.flac").is_none());
        assert!(parse_segment_path("D:\\Music\\Album\\disc.flac::start=0::end=200000").is_none());
    }

    #[test]
    fn rejects_range_path_missing_start_or_end() {
        assert!(parse_segment_path("D:\\a.flac::track=01::end=200000").is_none());
        assert!(parse_segment_path("D:\\a.flac::track=01::start=0").is_none());
        assert!(parse_segment_path("D:\\a.flac::track=01").is_none());
    }

    #[test]
    fn rejects_non_numeric_range_fields() {
        assert!(parse_segment_path("D:\\a.flac::track=xx::start=0::end=1").is_none());
        assert!(parse_segment_path("D:\\a.flac::track=01::start=x::end=1").is_none());
        assert!(parse_segment_path("D:\\a.flac::track=01::start=0::end=x").is_none());
        assert!(parse_segment_path("D:\\a.flac::track=-1::start=0::end=1").is_none());
    }

    #[test]
    fn rejects_range_with_end_before_start() {
        assert!(parse_segment_path("D:\\a.flac::track=01::start=200000::end=0").is_none());
        let equal = parse_segment_path("D:\\a.flac::track=01::start=5::end=5")
            .expect("equal start and end should parse");
        assert_eq!(equal.start_ms, 5);
        assert_eq!(equal.end_ms, 5);
    }

    #[test]
    fn rejects_incomplete_range_suffix() {
        assert!(parse_segment_path("D:\\a::b.flac::track=01::start=0").is_none());
        assert!(parse_segment_path("D:\\a.flac::track=01::start=0::end=1::extra=2").is_none());
        assert!(parse_segment_path("D:\\a::track=b.flac").is_none());
        // 源路径自身含 `::track=` 时取最后一个标记，仍能正确解析。
        let source = "D:\\a::track=old.flac";
        let path = segment_path_with_range(source, 5, 10, 20);
        let parsed = parse_segment_path(&path).expect("last marker should be used");
        assert_eq!(parsed.source_path, source);
        assert_eq!(parsed.track_number, 5);
    }

    #[test]
    fn rejects_empty_source_path_in_range() {
        assert!(parse_segment_path("::track=01::start=0::end=200000").is_none());
    }

    #[test]
    fn builds_range_path_in_expected_format() {
        assert_eq!(
            segment_path_with_range("D:\\Music\\Album\\disc.flac", 2, 0, 200_000),
            "D:\\Music\\Album\\disc.flac::track=02::start=0::end=200000"
        );
        assert_eq!(
            segment_path_with_range("Music/Album/Track.flac", 7, 1_000, 2_000),
            "Music/Album/Track.flac::track=07::start=1000::end=2000"
        );
    }
}
