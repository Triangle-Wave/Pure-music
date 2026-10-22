//! SACD ISO 同目录 XML 元数据的宽松解析。
//!
//! SACD 镜像常附带描述专辑与曲目的 XML，不同抓轨工具的元素名与命名空间并
//! 不统一。本模块按元素本地名（去掉命名空间前缀后小写）匹配常见同义词，
//! 用事件流逐元素解析，只保留专辑与曲目字段。读取或解析失败返回 `None`，
//! 由调用方回退到默认标题。

use std::fs;
use std::path::{Path, PathBuf};

use flutter_rust_bridge::frb;
use quick_xml::events::{BytesRef, BytesStart, Event};
use quick_xml::reader::Reader;

/// 单个字段允许的最大字符数，异常 XML 的超长文本直接丢弃。
const MAX_FIELD_CHARS: usize = 1024;

/// 单个元素内累计文本的上限（字节），避免畸形输入撑大内存。
const MAX_TEXT_BYTES: usize = 16 * 1024;

/// 曲目容器元素本地名。
const TRACK_CONTAINERS: [&str; 4] = ["track", "song", "chapter", "audio"];

/// 轨号元素与属性的本地名。
const TRACK_NUMBER_FIELDS: [&str; 5] = ["number", "no", "index", "sequence", "tracknumber"];

/// ISO 同目录 XML 中解析出的专辑与曲目信息。
#[derive(Debug, Default, Clone, PartialEq, Eq)]
#[frb(ignore)]
pub(crate) struct SacdXmlMetadata {
    /// 专辑名。
    pub(crate) album: Option<String>,
    /// 专辑艺术家。
    pub(crate) album_artist: Option<String>,
    /// 曲目，按 XML 出现顺序排列。
    pub(crate) tracks: Vec<SacdXmlTrack>,
}

impl SacdXmlMetadata {
    /// 是否至少解析出一个专辑字段或一条曲目。
    fn has_content(&self) -> bool {
        self.album.is_some() || self.album_artist.is_some() || !self.tracks.is_empty()
    }
}

/// XML 中的单条曲目。
#[derive(Debug, Default, Clone, PartialEq, Eq)]
#[frb(ignore)]
pub(crate) struct SacdXmlTrack {
    /// XML 给出的轨号；缺失时为按出现顺序补的序号。
    pub(crate) number: Option<u32>,
    /// 曲名。
    pub(crate) title: Option<String>,
    /// 曲目艺术家。
    pub(crate) artist: Option<String>,
    /// 时长（秒）。
    pub(crate) duration_secs: Option<u64>,
}

impl SacdXmlTrack {
    /// 是否含有可用的曲目字段。
    fn has_content(&self) -> bool {
        self.title.is_some()
            || self.artist.is_some()
            || self.duration_secs.is_some()
            || self.number.is_some()
    }
}

/// 判断路径是否为 XML 文件（扩展名大小写不敏感）。
pub(crate) fn is_xml_path(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("xml"))
}

/// 读取 ISO 同目录下第一个可用的 XML 元数据。
///
/// 按文件名（小写）排序扫描同目录的 `*.xml`，跳过读取或解析失败的候选，
/// 采用第一个至少解析出专辑字段或曲目的结果。目录不可读时返回 `None`。
pub(crate) fn load_sacd_xml_metadata(iso_path: &Path) -> Option<SacdXmlMetadata> {
    let folder = iso_path.parent()?;
    let entries = match fs::read_dir(folder) {
        Ok(entries) => entries,
        Err(error) => {
            log::warn!(
                target: "tag",
                "读取 SACD XML 目录失败: folder={}: {error}",
                folder.display()
            );
            return None;
        }
    };

    let mut candidates: Vec<PathBuf> = Vec::new();
    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => continue,
        };
        match entry.file_type() {
            Ok(kind) if kind.is_file() => {}
            _ => continue,
        }
        let path = entry.path();
        if is_xml_path(&path) {
            candidates.push(path);
        }
    }
    candidates.sort_by_key(|path| {
        path.file_name()
            .map(|name| name.to_string_lossy().to_lowercase())
            .unwrap_or_default()
    });

    for candidate in candidates {
        let bytes = match fs::read(&candidate) {
            Ok(bytes) => bytes,
            Err(error) => {
                log::warn!(
                    target: "tag",
                    "跳过不可读的 SACD XML: xml={}: {error}",
                    candidate.display()
                );
                continue;
            }
        };
        let Some(text) = decode_xml(&bytes) else {
            log::warn!(
                target: "tag",
                "跳过编码无法识别的 SACD XML: xml={}",
                candidate.display()
            );
            continue;
        };
        match parse_xml(&text) {
            Some(metadata) if metadata.has_content() => return Some(metadata),
            Some(_) => log::warn!(
                target: "tag",
                "跳过没有专辑或曲目字段的 SACD XML: xml={}",
                candidate.display()
            ),
            None => log::warn!(
                target: "tag",
                "跳过解析失败的 SACD XML: xml={}",
                candidate.display()
            ),
        }
    }

    None
}

/// 按轨号查找 XML 曲目；轨号匹配失败时按出现顺序回退。
pub(crate) fn track_for<'a>(
    metadata: &'a SacdXmlMetadata,
    number: u32,
    index: usize,
) -> Option<&'a SacdXmlTrack> {
    metadata
        .tracks
        .iter()
        .find(|track| track.number == Some(number))
        .or_else(|| metadata.tracks.get(index))
}

/// 解析 XML 文本；完全无可识别内容时返回 `None`。
pub(crate) fn parse_xml(xml: &str) -> Option<SacdXmlMetadata> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    reader.config_mut().check_end_names = true;

    let mut state = ParseState::default();
    loop {
        match reader.read_event() {
            Ok(Event::Eof) => break,
            Ok(Event::Start(start)) => state.start(&start),
            Ok(Event::Empty(start)) => {
                state.start(&start);
                state.end();
            }
            Ok(Event::End(_)) => state.end(),
            Ok(Event::Text(text)) => state.push_text(&*text),
            Ok(Event::CData(data)) => state.push_text(&*data),
            Ok(Event::GeneralRef(reference)) => state.push_reference(&reference),
            Ok(_) => {}
            Err(error) => {
                // 半截 XML 也可能已经给出专辑与曲目，保留已解析部分。
                let partial = state.metadata.has_content() || state.current_track.is_some();
                if !partial {
                    log::debug!(target: "tag", "SACD XML 解析中断: {error}");
                    return None;
                }
                break;
            }
        }
    }

    state.finish_track();
    if state.metadata.has_content() {
        Some(state.metadata)
    } else {
        None
    }
}

/// 把 XML 字节解码为字符串。
///
/// 依次尝试 UTF-8 BOM、UTF-16 LE/BE BOM、无 BOM 的 UTF-8，最后按 GB18030
/// 解码；全部失败返回 `None`。
fn decode_xml(bytes: &[u8]) -> Option<String> {
    if let Some(body) = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8(body.to_vec())
            .ok()
            .map(|text| text.trim_start_matches('\u{feff}').to_string());
    }
    if let Some(body) = bytes.strip_prefix(&[0xFF, 0xFE]) {
        return decode_utf16(body, true);
    }
    if let Some(body) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        return decode_utf16(body, false);
    }
    if let Ok(text) = std::str::from_utf8(bytes) {
        return Some(text.to_string());
    }
    let (decoded, _, had_errors) = encoding_rs::GB18030.decode(bytes);
    if had_errors {
        None
    } else {
        Some(decoded.into_owned())
    }
}

/// 解码 UTF-16 字节流，长度为奇数或含非法代理项时返回 `None`。
fn decode_utf16(bytes: &[u8], little_endian: bool) -> Option<String> {
    if !bytes.len().is_multiple_of(2) {
        return None;
    }
    let units: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|pair| {
            if little_endian {
                u16::from_le_bytes([pair[0], pair[1]])
            } else {
                u16::from_be_bytes([pair[0], pair[1]])
            }
        })
        .collect();
    String::from_utf16(&units).ok()
}

/// 解析状态：元素栈、当前曲目与文本缓冲。
struct ParseState {
    metadata: SacdXmlMetadata,
    stack: Vec<Frame>,
    current_track: Option<SacdXmlTrack>,
    album_artist_rank: u8,
    track_artist_rank: u8,
    text: String,
}

impl Default for ParseState {
    fn default() -> Self {
        Self {
            metadata: SacdXmlMetadata::default(),
            stack: Vec::new(),
            current_track: None,
            album_artist_rank: u8::MAX,
            track_artist_rank: u8::MAX,
            text: String::new(),
        }
    }
}

/// 元素栈帧：该元素负责的字段，以及它是否开启了曲目容器。
#[derive(Debug, Clone, Copy)]
struct Frame {
    field: Field,
    opens_track: bool,
}

/// 当前元素对应的目标字段。艺术家字段携带优先级，数字越小越优先。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Field {
    Album,
    AlbumArtist(u8),
    TrackNumber,
    TrackTitle,
    TrackArtist(u8),
    TrackDuration,
    None,
}

impl ParseState {
    fn start(&mut self, start: &BytesStart<'_>) {
        self.flush_text();
        let name = local_name(start.name().0).to_ascii_lowercase();
        let opens_track = is_track_container(&name) && self.current_track.is_none();
        if opens_track {
            self.current_track = Some(SacdXmlTrack::default());
            self.track_artist_rank = u8::MAX;
        }
        self.apply_attributes(start);
        let field = if is_track_container(&name) {
            // 容器自身直接携带文本时按曲名处理，子元素字段优先。
            Field::TrackTitle
        } else {
            classify_field(&name, self.current_track.is_some())
        };
        self.stack.push(Frame { field, opens_track });
    }

    fn end(&mut self) {
        self.flush_text();
        let Some(frame) = self.stack.pop() else {
            return;
        };
        if frame.opens_track {
            self.finish_track();
        }
    }

    /// 把 track 容器开始前的文本交给父元素。
    fn flush_text(&mut self) {
        if self.text.is_empty() {
            return;
        }
        let text = std::mem::take(&mut self.text);
        let Some(frame) = self.stack.last().copied() else {
            return;
        };
        self.assign(frame.field, &text);
    }

    fn push_text(&mut self, text: &str) {
        if self.text.len() >= MAX_TEXT_BYTES {
            return;
        }
        match self.stack.last() {
            Some(frame) if frame.field != Field::None => {}
            _ => return,
        }
        self.text.push_str(text);
    }

    fn push_reference(&mut self, reference: &BytesRef<'_>) {
        match self.stack.last() {
            Some(frame) if frame.field != Field::None => {}
            _ => return,
        }
        if self.text.len() >= MAX_TEXT_BYTES {
            return;
        }
        match reference.resolve_char_ref() {
            Ok(Some(character)) => self.text.push(character),
            Ok(None) => {
                let name: &str = &*reference;
                let replacement = match name {
                    "amp" => Some('&'),
                    "lt" => Some('<'),
                    "gt" => Some('>'),
                    "quot" => Some('"'),
                    "apos" => Some('\''),
                    _ => None,
                };
                if let Some(character) = replacement {
                    self.text.push(character);
                }
            }
            Err(_) => {}
        }
    }

    fn apply_attributes(&mut self, start: &BytesStart<'_>) {
        for attribute in start.attributes() {
            let attribute = match attribute {
                Ok(attribute) => attribute,
                Err(_) => continue,
            };
            let key = local_name(attribute.key.0).to_ascii_lowercase();
            let value = attribute.value.trim();
            self.assign_attribute(&key, value);
        }
    }

    fn assign_attribute(&mut self, key: &str, value: &str) {
        if TRACK_NUMBER_FIELDS.contains(&key) {
            if let Some(track) = self.current_track.as_mut() {
                if track.number.is_none() {
                    track.number = parse_track_number(value);
                }
            }
            return;
        }
        if matches!(key, "duration" | "length" | "time") {
            if let Some(track) = self.current_track.as_mut() {
                if track.duration_secs.is_none() {
                    track.duration_secs = parse_duration_secs(value);
                }
            }
            return;
        }
        let in_track = self.current_track.is_some();
        match key {
            "title" | "name" | "tracktitle" => {
                if in_track {
                    self.assign(Field::TrackTitle, value);
                } else {
                    self.assign(Field::Album, value);
                }
            }
            "artist" | "performer" | "composer" | "trackartist" => {
                if in_track {
                    self.assign(Field::TrackArtist(track_artist_rank(key)), value);
                } else {
                    self.assign(Field::AlbumArtist(album_artist_rank(key)), value);
                }
            }
            "album" | "albumtitle" | "disc" => self.assign(Field::Album, value),
            "albumartist" => self.assign(Field::AlbumArtist(0), value),
            _ => {}
        }
    }

    fn assign(&mut self, field: Field, value: &str) {
        let value = value.trim();
        if value.is_empty() || value.chars().count() > MAX_FIELD_CHARS {
            return;
        }
        match field {
            Field::Album => {
                if self.metadata.album.is_none() {
                    self.metadata.album = Some(value.to_string());
                }
            }
            Field::AlbumArtist(rank) => {
                if self.metadata.album_artist.is_none() || rank < self.album_artist_rank {
                    self.metadata.album_artist = Some(value.to_string());
                    self.album_artist_rank = rank;
                }
            }
            Field::TrackNumber => {
                if let Some(track) = self.current_track.as_mut() {
                    if track.number.is_none() {
                        track.number = parse_track_number(value);
                    }
                }
            }
            Field::TrackTitle => {
                if let Some(track) = self.current_track.as_mut() {
                    if track.title.is_none() {
                        track.title = Some(value.to_string());
                    }
                }
            }
            Field::TrackArtist(rank) => {
                if let Some(track) = self.current_track.as_mut() {
                    if track.artist.is_none() || rank < self.track_artist_rank {
                        track.artist = Some(value.to_string());
                        self.track_artist_rank = rank;
                    }
                }
            }
            Field::TrackDuration => {
                if let Some(track) = self.current_track.as_mut() {
                    if track.duration_secs.is_none() {
                        track.duration_secs = parse_duration_secs(value);
                    }
                }
            }
            Field::None => {}
        }
    }

    /// 结束当前曲目，缺轨号时按出现顺序补号；没有任何字段的容器丢弃。
    fn finish_track(&mut self) {
        let Some(mut track) = self.current_track.take() else {
            return;
        };
        self.track_artist_rank = u8::MAX;
        if !track.has_content() {
            return;
        }
        if track.number.is_none() {
            track.number = Some(self.metadata.tracks.len() as u32 + 1);
        }
        self.metadata.tracks.push(track);
    }
}

fn local_name(name: &str) -> &str {
    name.rsplit(':').next().unwrap_or(name)
}

fn is_track_container(name: &str) -> bool {
    TRACK_CONTAINERS.contains(&name)
}

fn classify_field(name: &str, in_track: bool) -> Field {
    if in_track {
        if TRACK_NUMBER_FIELDS.contains(&name) {
            return Field::TrackNumber;
        }
        return match name {
            "title" | "name" | "tracktitle" => Field::TrackTitle,
            "artist" | "performer" | "composer" | "trackartist" => {
                Field::TrackArtist(track_artist_rank(name))
            }
            "duration" | "length" | "time" => Field::TrackDuration,
            _ => Field::None,
        };
    }
    match name {
        "album" | "albumtitle" | "disc" | "title" => Field::Album,
        "albumartist" => Field::AlbumArtist(0),
        "artist" => Field::AlbumArtist(1),
        "performer" => Field::AlbumArtist(2),
        _ => Field::None,
    }
}

/// 曲目艺术家的优先级：artist 优先于 performer，performer 优先于 composer。
fn track_artist_rank(name: &str) -> u8 {
    match name {
        "artist" | "trackartist" => 0,
        "performer" => 1,
        "composer" => 2,
        _ => u8::MAX,
    }
}

/// 专辑艺术家的优先级：albumartist 优先于 artist，artist 优先于 performer。
fn album_artist_rank(name: &str) -> u8 {
    match name {
        "albumartist" => 0,
        "artist" => 1,
        "performer" => 2,
        _ => u8::MAX,
    }
}

/// 解析轨号：优先整体数字，否则取第一段连续数字。
fn parse_track_number(value: &str) -> Option<u32> {
    let value = value.trim();
    if let Ok(number) = value.parse::<u32>() {
        return Some(number);
    }
    let digits: String = value
        .chars()
        .skip_while(|character| !character.is_ascii_digit())
        .take_while(|character| character.is_ascii_digit())
        .collect();
    digits.parse::<u32>().ok()
}

/// 解析时长：支持秒数、`mm:ss`、`hh:mm:ss` 与 ISO 8601（`PT3M45S`）。
fn parse_duration_secs(value: &str) -> Option<u64> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    let is_iso = value
        .get(..2)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("pt"));
    if is_iso {
        return parse_iso_duration_secs(value.get(2..)?);
    }
    if value.contains(':') {
        let mut total = 0_u64;
        let mut parts = 0_u32;
        for part in value.split(':') {
            let part: u64 = part.trim().parse().ok()?;
            total = total.checked_mul(60)?.checked_add(part)?;
            parts += 1;
        }
        return if parts >= 2 { Some(total) } else { None };
    }
    value.parse::<u64>().ok()
}

/// 解析 ISO 8601 时长中带单位的部分，未带单位时按秒处理。
fn parse_iso_duration_secs(value: &str) -> Option<u64> {
    let mut total = 0_u64;
    let mut number = 0_u64;
    let mut has_digit = false;
    let mut found_unit = false;
    for character in value.chars() {
        if let Some(digit) = character.to_digit(10) {
            number = number.checked_mul(10)?.checked_add(u64::from(digit))?;
            has_digit = true;
            continue;
        }
        if !has_digit {
            continue;
        }
        let multiplier = match character.to_ascii_uppercase() {
            'H' => 3600,
            'M' => 60,
            'S' => 1,
            _ => {
                number = 0;
                has_digit = false;
                continue;
            }
        };
        total = total.checked_add(number.checked_mul(multiplier)?)?;
        number = 0;
        has_digit = false;
        found_unit = true;
    }
    if has_digit {
        total = total.checked_add(number)?;
    }
    if found_unit || has_digit {
        Some(total)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn parses_album_and_track_fields() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
        <SACD>
          <AlbumTitle>Kind of Blue</AlbumTitle>
          <Artist>Miles Davis</Artist>
          <TrackList>
            <Track>
              <Number>1</Number>
              <Title>So What</Title>
              <Artist>Miles Davis</Artist>
              <Duration>09:22</Duration>
            </Track>
            <Track>
              <Number>2</Number>
              <Title>Freddie Freeloader</Title>
            </Track>
          </TrackList>
        </SACD>"#;
        let metadata = parse_xml(xml).expect("应解析出元数据");
        assert_eq!(metadata.album.as_deref(), Some("Kind of Blue"));
        assert_eq!(metadata.album_artist.as_deref(), Some("Miles Davis"));
        assert_eq!(metadata.tracks.len(), 2);
        assert_eq!(metadata.tracks[0].number, Some(1));
        assert_eq!(metadata.tracks[0].title.as_deref(), Some("So What"));
        assert_eq!(metadata.tracks[0].artist.as_deref(), Some("Miles Davis"));
        assert_eq!(metadata.tracks[0].duration_secs, Some(562));
        assert_eq!(metadata.tracks[1].number, Some(2));
    }

    #[test]
    fn ignores_namespace_prefixes() {
        let xml = r#"<sacd:disc xmlns:sacd="urn:test">
          <sacd:album>Test Album</sacd:album>
          <sacd:albumartist>Test Artist</sacd:albumartist>
          <sacd:song>
            <sacd:no>3</sacd:no>
            <sacd:name>Third</sacd:name>
          </sacd:song>
        </sacd:disc>"#;
        let metadata = parse_xml(xml).expect("应解析出元数据");
        assert_eq!(metadata.album.as_deref(), Some("Test Album"));
        assert_eq!(metadata.album_artist.as_deref(), Some("Test Artist"));
        assert_eq!(metadata.tracks.len(), 1);
        assert_eq!(metadata.tracks[0].number, Some(3));
        assert_eq!(metadata.tracks[0].title.as_deref(), Some("Third"));
    }

    #[test]
    fn numbers_tracks_in_order_when_number_missing() {
        let xml = r#"<root><album>Order</album>
          <track><title>First</title></track>
          <track><title>Second</title></track>
          <track><title>Third</title></track></root>"#;
        let metadata = parse_xml(xml).expect("应解析出元数据");
        let numbers: Vec<Option<u32>> = metadata.tracks.iter().map(|track| track.number).collect();
        assert_eq!(numbers, vec![Some(1), Some(2), Some(3)]);
    }

    #[test]
    fn reads_track_number_and_title_attributes() {
        let xml = r#"<root><album>Hits</album>
          <track number="7" title="Seven" artist="Someone" /></root>"#;
        let metadata = parse_xml(xml).expect("应解析出元数据");
        assert_eq!(metadata.tracks.len(), 1);
        assert_eq!(metadata.tracks[0].number, Some(7));
        assert_eq!(metadata.tracks[0].title.as_deref(), Some("Seven"));
        assert_eq!(metadata.tracks[0].artist.as_deref(), Some("Someone"));
    }

    #[test]
    fn track_lookup_falls_back_to_order() {
        let xml = r#"<root><album>Fallback</album>
          <track><number>10</number><title>A</title></track>
          <track><number>20</number><title>B</title></track></root>"#;
        let metadata = parse_xml(xml).expect("应解析出元数据");
        assert_eq!(
            track_for(&metadata, 20, 1).and_then(|track| track.title.as_deref()),
            Some("B")
        );
        assert_eq!(
            track_for(&metadata, 99, 1).and_then(|track| track.title.as_deref()),
            Some("B")
        );
    }

    #[test]
    fn returns_none_for_broken_or_empty_xml() {
        assert!(parse_xml("<album><title>broken</album>").is_none());
        assert!(parse_xml("<root><unknown>value</unknown></root>").is_none());
    }

    #[test]
    fn decodes_utf8_bom() {
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(b"<album>Bom</album>");
        let text = decode_xml(&bytes).expect("应识别 UTF-8 BOM");
        assert_eq!(parse_xml(&text).and_then(|metadata| metadata.album).as_deref(), Some("Bom"));
    }

    #[test]
    fn detects_xml_extension_case_insensitively() {
        assert!(is_xml_path(Path::new("album.xml")));
        assert!(is_xml_path(Path::new("album.XML")));
        assert!(!is_xml_path(Path::new("album.txt")));
    }

    #[test]
    fn parses_iso_and_colon_durations() {
        assert_eq!(parse_duration_secs("PT3M45S"), Some(225));
        assert_eq!(parse_duration_secs("1:02:03"), Some(3723));
        assert_eq!(parse_duration_secs("95"), Some(95));
    }
}
