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
}
