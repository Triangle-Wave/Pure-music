use std::{
    collections::{HashMap, HashSet, VecDeque},
    fs::{self},
    io::{self, Cursor},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc, Mutex, OnceLock,
    },
    time::{Duration, UNIX_EPOCH},
};

use dsf_meta::DsfFile;
use id3::TagLike;
use image::{imageops, DynamicImage};
use lofty::config::{ParseOptions, ParsingMode, WriteOptions};
use lofty::picture::{MimeType, Picture, PictureType};
use lofty::prelude::{Accessor, AudioFile, ItemKey, TaggedFileExt};
use lofty::probe::Probe;
use lofty::tag::{ItemValue, Tag, TagItem, TagType};
use ratag::tag::{Basic as RatagBasic, Picture as RatagPicture};
use windows::{
    core::Interface,
    core::HSTRING,
    Storage::{
        FileProperties::ThumbnailMode,
        StorageFile,
        Streams::{DataReader, IInputStream},
    },
    Win32::System::WinRT::{RoInitialize, RoUninitialize, RO_INIT_MULTITHREADED},
    Win32::{Storage::FileSystem::GetDriveTypeW, System::WindowsProgramming::DRIVE_REMOTE},
};

use crate::frb_generated::StreamSink;
use crate::api::sacd::{is_sacd_iso, read_sacd_toc, SacdAreaKind};
use crate::sacd_metadata::{is_xml_path, load_sacd_xml_metadata, track_for};

use super::library_db;

mod format_detection;
use format_detection::{
    is_asf_path, is_dff_path, is_dsf_path, is_generic_id3_path, is_iso_path, is_midi_path,
    is_supported_audio_path, is_symphonia_path, SUPPORTED_FORMATS,
};

mod format_readers;
mod cue;
mod source_duration;
use cue::{
    expand_segments, is_cue_path, parse_cue_file, parse_segment_path, sacd_segment_path,
    segment_path_with_range,
};
use format_readers::{
    read_by_asf, read_by_dff, read_by_dsf, read_by_id3, read_by_midi, read_by_symphonia,
};
use source_duration::{header_duration_ms, probe_container_duration_ms};

mod dff;
use dff::read_dff_metadata;

mod dsf;
use dsf::DsfAudioProperties;

pub mod index_state;
pub use index_state::IndexActionState;
pub use index_state::IndexPhase;

mod symphonia;
use symphonia::read_symphonia_metadata;

mod midi;
#[cfg(test)]
use midi::parse_midi_metadata;
use midi::read_midi_metadata;

pub mod extra_metadata;
use extra_metadata::should_show_recording_date;
pub use extra_metadata::{AudioExtraItem, AudioExtraMetadata};

/// 将迭代器中的字符串去重后用 "/" 拼接。
/// FLAC Vorbis Comment 可能包含重复的多值标签（如多个相同的 ARTIST）。
fn join_deduped<'a>(items: impl IntoIterator<Item = &'a str>) -> String {
    let mut seen = HashSet::new();
    let mut result = String::new();
    for item in items {
        if seen.insert(item.to_string()) {
            if !result.is_empty() {
                result.push('/');
            }
            result.push_str(item);
        }
    }
    result
}

fn file_name(path: &Path) -> Option<String> {
    path.file_name()
        .map(|name| name.to_string_lossy().to_string())
}

fn estimated_bitrate(path: &Path, duration: u64) -> Option<u32> {
    if duration == 0 {
        return None;
    }
    fs::metadata(path)
        .ok()
        .map(|metadata| metadata.len().saturating_mul(8) / duration / 1000)
        .and_then(|value| u32::try_from(value).ok())
}

fn optional_nonempty(value: Option<String>) -> Option<String> {
    value.filter(|value| !value.trim().is_empty())
}

pub(super) fn id3_text(tag: &id3::Tag, id: &str) -> Option<String> {
    optional_nonempty(
        tag.get(id)
            .and_then(|frame| frame.content().text())
            .map(str::to_string),
    )
}

fn lofty_text(tag: &Tag, key: &ItemKey) -> Option<String> {
    optional_nonempty(
        tag.get(key)
            .and_then(|item| item.value().text())
            .map(str::to_string),
    )
}

fn lofty_joined_text(tag: &Tag, key: &ItemKey) -> Option<String> {
    optional_nonempty(Some(join_deduped(tag.get_strings(key))))
}

fn unknown_if_empty(value: Option<String>) -> String {
    optional_nonempty(value).unwrap_or_else(|| "UNKNOWN".to_string())
}

fn read_id3_from_bytes(bytes: &[u8]) -> Option<id3::Tag> {
    id3::Tag::read_from2(Cursor::new(bytes)).ok()
}

/// DSD 原生采样位深：DSD 以 1 bit 采样，DSF、DFF 与 SACD ISO 均适用。
const DSD_NATIVE_BIT_DEPTH: u8 = 1;

/// DSD 原生码率（kbps）：`sample_rate * channels * 1 / 1000`。
///
/// DSF/DFF 的容器位深字段不代表采样位深，Lofty 按其计算会得到放大数倍的码率。
/// 采样率、声道数为 0、乘积溢出或换算后不足 1 kbps 时返回 `None`，
/// 避免产生 `Some(0)` 脏值。
fn dsd_native_bitrate(sample_rate: Option<u32>, channels: Option<u8>) -> Option<u32> {
    let sample_rate = sample_rate.filter(|value| *value > 0)?;
    let channels = u32::from(channels.filter(|value| *value > 0)?);
    sample_rate
        .checked_mul(channels)
        .and_then(|value| value.checked_mul(u32::from(DSD_NATIVE_BIT_DEPTH)))
        .map(|value| value / 1000)
        .filter(|value| *value > 0)
}

fn read_dsf_audio_properties(file: &DsfFile) -> DsfAudioProperties {
    let fmt = file.fmt_chunk();
    let sample_rate = fmt.sampling_frequency();
    let channels = fmt.channel_num();
    // DSF 头里的 bits_per_sample 是字节序标记（1=LSB first，8=MSB first），
    // 不是位深；DSD 原生采样固定为 1 bit。
    let bit_depth = DSD_NATIVE_BIT_DEPTH;
    let duration = if sample_rate == 0 {
        0
    } else {
        fmt.sample_count() / u64::from(sample_rate)
    };
    let bitrate = dsd_native_bitrate(Some(sample_rate), u8::try_from(channels).ok());

    DsfAudioProperties {
        duration,
        bitrate,
        sample_rate: (sample_rate > 0).then_some(sample_rate),
        channels: u8::try_from(channels).ok(),
        bit_depth: Some(bit_depth),
    }
}

fn id3_tag_items(tag: &id3::Tag) -> Vec<(String, String)> {
    let mut items = Vec::new();
    let mut push = |key: &str, value: Option<String>| {
        if let Some(value) = optional_nonempty(value) {
            items.push((key.to_string(), value));
        }
    };
    push("year", tag.year().map(|value| value.to_string()));
    push("genre", tag.genre().map(str::to_string));
    push(
        "comment",
        tag.comments().next().map(|value| value.text.clone()),
    );
    push("track", tag.track().map(|value| value.to_string()));
    push("disc", tag.disc().map(|value| value.to_string()));
    push(
        "copyright",
        tag.get("TCOP")
            .and_then(|frame| frame.content().text())
            .map(str::to_string),
    );
    push(
        "composer",
        tag.get("TCOM")
            .and_then(|frame| frame.content().text())
            .map(str::to_string),
    );
    push("album_artist", tag.album_artist().map(str::to_string));
    items
}

fn parse_alternative_number(value: &str) -> Option<u32> {
    value.split('/').next()?.trim().parse().ok()
}

fn is_image_attachment(name: &str, media_type: Option<&str>) -> bool {
    media_type.is_some_and(|value| {
        value.eq_ignore_ascii_case("image/jpeg")
            || value.eq_ignore_ascii_case("image/png")
            || value.eq_ignore_ascii_case("image/webp")
    }) || Path::new(name).extension().is_some_and(|ext| {
        matches!(
            ext.to_str()
                .map(|value| value.to_ascii_lowercase())
                .as_deref(),
            Some("jpg") | Some("jpeg") | Some("png") | Some("webp")
        )
    })
}

fn read_by_alternative(path: &Path, modified: u64, created: u64) -> Option<Audio> {
    if is_dsf_path(path) {
        return read_by_dsf(path, modified, created);
    }
    if is_dff_path(path) {
        return read_by_dff(path, modified, created);
    }
    if is_asf_path(path) {
        return read_by_asf(path, modified, created);
    }
    if is_midi_path(path) {
        return read_by_midi(path, modified, created);
    }
    if is_generic_id3_path(path) {
        return read_by_id3(path, modified, created);
    }
    if is_symphonia_path(path) {
        if let Some(metadata) = read_by_symphonia(path, modified, created) {
            return Some(metadata);
        }
    }
    read_by_id3(path, modified, created)
}

fn take_extra_item(items: &mut Vec<(String, String)>, key: &str) -> Option<String> {
    let index = items
        .iter()
        .position(|(item_key, _)| item_key.eq_ignore_ascii_case(key))?;
    Some(items.remove(index).1)
}

fn build_alternative_extra_metadata(
    extension: String,
    file_size: u64,
    channels: Option<u8>,
    bit_depth: Option<u8>,
    mut items: Vec<(String, String)>,
) -> AudioExtraMetadata {
    let replaygain_track_gain = take_extra_item(&mut items, "replaygain_track_gain");
    let replaygain_track_peak = take_extra_item(&mut items, "replaygain_track_peak");
    let replaygain_album_gain = take_extra_item(&mut items, "replaygain_album_gain");
    let replaygain_album_peak = take_extra_item(&mut items, "replaygain_album_peak");
    AudioExtraMetadata {
        extension,
        file_size,
        channels,
        bit_depth,
        items: items
            .into_iter()
            .map(|(key, value)| AudioExtraItem { key, value })
            .collect(),
        replaygain_track_gain,
        replaygain_track_peak,
        replaygain_album_gain,
        replaygain_album_peak,
    }
}

fn read_asf_extra_metadata(
    path: &Path,
    extension: String,
    file_size: u64,
) -> Option<AudioExtraMetadata> {
    let metadata = RatagBasic::from_file(path).ok()?;
    let mut items = Vec::new();
    let artist = join_deduped(metadata.artists.iter().map(String::as_str));
    let genre = join_deduped(metadata.genres.iter().map(String::as_str));
    for (key, value) in [
        ("artist", (!artist.is_empty()).then_some(artist)),
        ("album_artist", metadata.album_artist),
        ("genre", (!genre.is_empty()).then_some(genre)),
        ("track", metadata.track.map(|value| value.to_string())),
        ("disc", metadata.disc.map(|value| value.to_string())),
        ("year", metadata.year.map(|value| value.to_string())),
    ] {
        if let Some(value) = value {
            items.push((key.to_string(), value));
        }
    }
    Some(build_alternative_extra_metadata(
        extension, file_size, None, None, items,
    ))
}

fn read_alternative_extra_metadata(
    path: &Path,
    extension: String,
    file_size: u64,
) -> Option<AudioExtraMetadata> {
    if is_dsf_path(path) {
        return Some(read_dsf_extra_metadata(
            &path.to_string_lossy(),
            extension,
            file_size,
        ));
    }
    if is_dff_path(path) {
        let metadata = read_dff_metadata(path)?;
        return Some(build_alternative_extra_metadata(
            extension,
            file_size,
            metadata.channels,
            Some(1),
            metadata.items,
        ));
    }
    if is_asf_path(path) {
        return read_asf_extra_metadata(path, extension, file_size);
    }
    if is_midi_path(path) {
        let metadata = read_midi_metadata(path)?;
        return Some(build_alternative_extra_metadata(
            extension,
            file_size,
            None,
            None,
            metadata.items,
        ));
    }
    if is_generic_id3_path(path) {
        let tag = id3::Tag::read_from_path(path).ok()?;
        return Some(build_alternative_extra_metadata(
            extension,
            file_size,
            None,
            None,
            id3_tag_items(&tag),
        ));
    }
    if is_symphonia_path(path) {
        if let Some(metadata) = read_symphonia_metadata(path) {
            return Some(build_alternative_extra_metadata(
                extension,
                file_size,
                metadata.channels,
                metadata.bit_depth,
                metadata.items,
            ));
        }
    }
    let tag = id3::Tag::read_from_path(path).ok()?;
    Some(build_alternative_extra_metadata(
        extension,
        file_size,
        None,
        None,
        id3_tag_items(&tag),
    ))
}

fn push_dsf_item(items: &mut Vec<AudioExtraItem>, key: &str, value: Option<&str>) {
    if let Some(value) = value.filter(|value| !value.trim().is_empty()) {
        items.push(AudioExtraItem {
            key: key.to_string(),
            value: value.to_string(),
        });
    }
}

fn read_dsf_extra_metadata(path: &str, extension: String, file_size: u64) -> AudioExtraMetadata {
    let mut items = Vec::new();
    if let Ok(file) = DsfFile::open(Path::new(path)) {
        if let Some(tag) = file.id3_tag().as_ref() {
            let year = tag.year().map(|value| value.to_string());
            push_dsf_item(&mut items, "year", year.as_deref());
            push_dsf_item(&mut items, "genre", tag.genre());
            push_dsf_item(
                &mut items,
                "disc",
                tag.disc().map(|value| value.to_string()).as_deref(),
            );
            push_dsf_item(
                &mut items,
                "track",
                tag.track().map(|value| value.to_string()).as_deref(),
            );
            push_dsf_item(&mut items, "artist", tag.artist());
            push_dsf_item(&mut items, "album_artist", tag.album_artist());
        }
        let properties = read_dsf_audio_properties(&file);
        return AudioExtraMetadata {
            extension,
            file_size,
            channels: properties.channels,
            bit_depth: properties.bit_depth,
            items,
            replaygain_track_gain: None,
            replaygain_track_peak: None,
            replaygain_album_gain: None,
            replaygain_album_peak: None,
        };
    }

    AudioExtraMetadata {
        extension,
        file_size,
        channels: None,
        bit_depth: None,
        items,
        replaygain_track_gain: None,
        replaygain_track_peak: None,
        replaygain_album_gain: None,
        replaygain_album_peak: None,
    }
}

fn read_dsf_picture(path: &Path) -> Option<Vec<u8>> {
    let file = DsfFile::open(path).ok()?;
    let picture = file
        .id3_tag()
        .as_ref()?
        .pictures()
        .next()
        .map(|picture| picture.data.clone());
    picture
}

fn read_dff_picture(path: &Path) -> Option<Vec<u8>> {
    read_dff_metadata(path)?.picture
}

fn read_asf_picture(path: &Path) -> Option<Vec<u8>> {
    let pictures = RatagPicture::read_cover(path).ok()?;
    let picture = pictures.picture()?;
    (!picture.is_uri).then(|| picture.data.clone())
}

fn read_id3_picture(path: &Path) -> Option<Vec<u8>> {
    id3::Tag::read_from_path(path)
        .ok()?
        .pictures()
        .next()
        .map(|picture| picture.data.clone())
}

/// for Flutter
pub fn read_audio_extra_metadata(path: String) -> AudioExtraMetadata {
    let file_size = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    let extension = Path::new(&path)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string();

    let mut items: Vec<AudioExtraItem> = vec![];
    let mut replaygain_track_gain: Option<String> = None;
    let mut replaygain_track_peak: Option<String> = None;
    let mut replaygain_album_gain: Option<String> = None;
    let mut replaygain_album_peak: Option<String> = None;

    let options = ParseOptions::new()
        .parsing_mode(ParsingMode::Relaxed)
        .read_tags(true)
        .read_cover_art(false)
        .read_properties(true);

    let tagged_file = match Probe::open(&path).and_then(|p| p.options(options).read()) {
        Ok(val) => val,
        Err(err) => {
            if let Some(metadata) =
                read_alternative_extra_metadata(Path::new(&path), extension.clone(), file_size)
            {
                return metadata;
            }
            log::warn!(target: "tag", "metadata read failed: {}", err);
            return AudioExtraMetadata {
                extension,
                file_size,
                channels: None,
                bit_depth: None,
                items: vec![],
                replaygain_track_gain: None,
                replaygain_track_peak: None,
                replaygain_album_gain: None,
                replaygain_album_peak: None,
            };
        }
    };

    let props = tagged_file.properties();
    let channels = props.channels();
    // 详情页与索引使用同一位深口径：DSD 流固定 1 bit。
    let bit_depth = if is_dsf_path(Path::new(&path)) || is_dff_path(Path::new(&path)) {
        Some(DSD_NATIVE_BIT_DEPTH)
    } else {
        props.bit_depth()
    };

    if let Some(tag) = tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag())
    {
        let mut push_kv = |key: &str, val: Option<&str>| {
            if let Some(v) = val {
                if !v.trim().is_empty() {
                    items.push(AudioExtraItem {
                        key: key.to_string(),
                        value: v.to_string(),
                    });
                }
            }
        };

        let track_artist = join_deduped(tag.get_strings(&ItemKey::TrackArtist));
        let album_artist = join_deduped(tag.get_strings(&ItemKey::AlbumArtist));

        push_kv(
            "genre",
            tag.get(&ItemKey::Genre).and_then(|v| v.value().text()),
        );
        let recording_date = tag
            .get(&ItemKey::RecordingDate)
            .and_then(|v| v.value().text());
        let year = tag
            .get(&ItemKey::Year)
            .or_else(|| tag.get(&ItemKey::RecordingDate))
            .and_then(|v| v.value().text());
        if should_show_recording_date(recording_date, year) {
            push_kv("date", recording_date);
        }
        push_kv("year", year);
        push_kv(
            "release_date",
            tag.get(&ItemKey::ReleaseDate)
                .and_then(|v| v.value().text()),
        );
        push_kv(
            "disc",
            tag.get(&ItemKey::DiscNumber).and_then(|v| v.value().text()),
        );
        push_kv(
            "disc_total",
            tag.get(&ItemKey::DiscTotal).and_then(|v| v.value().text()),
        );
        push_kv(
            "track_total",
            tag.get(&ItemKey::TrackTotal).and_then(|v| v.value().text()),
        );
        push_kv(
            "artist",
            if track_artist.is_empty() {
                None
            } else {
                Some(track_artist.as_str())
            },
        );
        push_kv(
            "album_artist",
            if album_artist.is_empty() {
                None
            } else {
                Some(album_artist.as_str())
            },
        );
        push_kv(
            "composer",
            tag.get(&ItemKey::Composer).and_then(|v| v.value().text()),
        );
        push_kv(
            "lyricist",
            tag.get(&ItemKey::Lyricist).and_then(|v| v.value().text()),
        );
        push_kv(
            "label",
            tag.get(&ItemKey::Label).and_then(|v| v.value().text()),
        );
        push_kv(
            "comment",
            tag.get(&ItemKey::Comment).and_then(|v| v.value().text()),
        );
        push_kv(
            "encoded_by",
            tag.get(&ItemKey::EncodedBy).and_then(|v| v.value().text()),
        );
        push_kv(
            "encoder",
            tag.get(&ItemKey::EncoderSoftware)
                .and_then(|v| v.value().text())
                .or_else(|| tag.get(&ItemKey::EncodedBy).and_then(|v| v.value().text())),
        );
        push_kv(
            "encoder_settings",
            tag.get(&ItemKey::EncoderSettings)
                .and_then(|v| v.value().text()),
        );
        replaygain_track_gain = tag
            .get(&ItemKey::ReplayGainTrackGain)
            .and_then(|v| v.value().text())
            .map(|s| s.to_string());
        replaygain_track_peak = tag
            .get(&ItemKey::ReplayGainTrackPeak)
            .and_then(|v| v.value().text())
            .map(|s| s.to_string());
        replaygain_album_gain = tag
            .get(&ItemKey::ReplayGainAlbumGain)
            .and_then(|v| v.value().text())
            .map(|s| s.to_string());
        replaygain_album_peak = tag
            .get(&ItemKey::ReplayGainAlbumPeak)
            .and_then(|v| v.value().text())
            .map(|s| s.to_string());
        push_kv(
            "bpm",
            tag.get(&ItemKey::Bpm)
                .and_then(|v| v.value().text())
                .or_else(|| tag.get(&ItemKey::IntegerBpm).and_then(|v| v.value().text())),
        );
        push_kv(
            "language",
            tag.get(&ItemKey::Language).and_then(|v| v.value().text()),
        );
        push_kv(
            "copyright",
            tag.get(&ItemKey::CopyrightMessage)
                .and_then(|v| v.value().text()),
        );
        push_kv(
            "license",
            tag.get(&ItemKey::License)
                .or_else(|| tag.get(&ItemKey::Unknown("LICENSE".to_string())))
                .and_then(|v| v.value().text()),
        );
    }

    AudioExtraMetadata {
        extension,
        file_size,
        channels,
        bit_depth,
        items,
        replaygain_track_gain,
        replaygain_track_peak,
        replaygain_album_gain,
        replaygain_album_peak,
    }
}

const CURRENT_INDEX_VERSION: u64 = 113;
const MAX_TAG_READER_WORKERS: usize = 4;
const RESERVED_LOGICAL_CORES: usize = 2;
const INDEX_PROGRESS_MIN_BATCH: usize = 16;
const INDEX_PROGRESS_TARGET_UPDATES: usize = 200;
const MAX_REMOTE_DIRECTORIES: usize = 10_000;
const NETWORK_FOLDER_ERROR: &str = "网络共享文件夹不能作为本地曲库文件夹，请通过远程音乐添加";
const REMOTE_FOLDER_ERROR: &str = "SMB 远程来源必须使用 Windows 网络共享路径";

fn is_network_path(path: &Path) -> bool {
    let raw = path.to_string_lossy();
    let lower = raw.to_ascii_lowercase();
    if lower.starts_with(r"\\?") {
        return lower.starts_with(r"\\?\unc");
    }
    if lower.starts_with(r"\\") || lower.starts_with("//") {
        return true;
    }

    let bytes = lower.as_bytes();
    if bytes.len() < 3 || bytes[1] != b':' || !matches!(bytes[2], b'\\' | b'/') {
        return false;
    }
    let Some(drive) = raw.chars().next() else {
        return false;
    };
    let root = HSTRING::from(format!("{drive}:\\"));
    unsafe { GetDriveTypeW(&root) == DRIVE_REMOTE }
}

fn reject_network_folder(path: &Path) -> io::Result<()> {
    if is_network_path(path) {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            NETWORK_FOLDER_ERROR,
        ))
    } else {
        Ok(())
    }
}

fn validate_scan_roots(folders: &[String], remote: bool) -> io::Result<()> {
    for folder in folders {
        let path = Path::new(folder);
        if remote {
            if !is_network_path(path) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    REMOTE_FOLDER_ERROR,
                ));
            }
        } else {
            reject_network_folder(path)?;
        }
    }
    Ok(())
}

#[derive(Debug)]
struct Audio {
    title: String,
    artist: String,
    album: String,
    album_artist: Option<String>,
    genre: Option<String>,
    year: Option<String>,
    composer: Option<String>,
    bpm: Option<String>,
    track: Option<u32>,
    disc: Option<u32>,
    /// in secs
    duration: u64,
    /// kbps
    bitrate: Option<u32>,
    sample_rate: Option<u32>,
    bit_depth: Option<u8>,
    /// absolute path
    path: String,
    /// secs since UNIX_EPOCH
    modified: u64,
    /// secs since UNIX_EPOCH
    created: u64,
    /// 标签获取方式
    by: Option<String>,
    size: u64,
    valid: bool,
    media_id: Option<String>,
}

impl Audio {
    fn new_with_path(path: impl AsRef<Path>, by: Option<String>) -> Option<Self> {
        let path = path.as_ref();
        Some(Audio {
            title: path.file_name()?.to_string_lossy().to_string(),
            artist: "UNKNOWN".to_string(),
            album: "UNKNOWN".to_string(),
            album_artist: None,
            genre: None,
            year: None,
            composer: None,
            bpm: None,
            track: None,
            disc: None,
            duration: 0,
            bitrate: None,
            sample_rate: None,
            bit_depth: None,
            path: path.to_string_lossy().to_string(),
            modified: 0,
            created: 0,
            by,
            size: 0,
            valid: true,
            media_id: None,
        })
    }

    fn to_json_value(&self) -> serde_json::Value {
        serde_json::json!({
            "title": self.title,
            "artist": self.artist,
            "album": self.album,
            "album_artist": self.album_artist,
            "genre": self.genre,
            "year": self.year,
            "composer": self.composer,
            "bpm": self.bpm,
            "track": self.track,
            "disc": self.disc,
            "duration": self.duration,
            "bitrate": self.bitrate,
            "sample_rate": self.sample_rate,
            "bit_depth": self.bit_depth,
            "path": self.path,
            "modified": self.modified,
            "created": self.created,
            "by": self.by,
            "size": self.size,
            "valid": self.valid,
            "media_id": self.media_id
        })
    }

    /// 不支持：None  
    /// 所有格式先由 Lofty 读取，再按格式使用其他解析器和 Windows API 回退。
    /// 再不能的话：title: filename 代替
    fn read_from_path(path: impl AsRef<Path>) -> Option<Self> {
        let path = path.as_ref();
        let ext_lower = path
            .extension()?
            .to_ascii_lowercase()
            .to_string_lossy()
            .to_string();
        if !SUPPORTED_FORMATS.contains(&ext_lower) {
            return None;
        }

        let file_metadata = match fs::metadata(path) {
            Ok(val) => val,
            Err(err) => {
                log::warn!(target: "tag", "{}", err);
                return None;
            }
        };
        let modified = file_metadata
            .modified()
            .unwrap_or(UNIX_EPOCH)
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO)
            .as_secs();
        let created = file_metadata
            .created()
            .unwrap_or(UNIX_EPOCH)
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO)
            .as_secs();

        let finalize = |mut value: Audio| {
            value.size = file_metadata.len();
            value.valid = true;
            if value.media_id.is_none() {
                value.media_id = library_db::stable_file_id_for_path(path);
            }
            value
        };

        if let Some(value) = Self::read_by_lofty(path, modified, created) {
            return Some(finalize(value));
        }
        if let Some(value) = read_by_alternative(path, modified, created) {
            return Some(finalize(value));
        }
        match Self::read_by_win_music_properties(path, modified, created) {
            Ok(value) => Some(finalize(value)),
            Err(err) => {
                log::warn!(target: "tag", "metadata fallback failed: {}", err);
                let mut value = Self::new_with_path(path, None)?;
                value.modified = modified;
                value.created = created;
                Some(finalize(value))
            }
        }
    }

    /// 使用 lofty 获取音乐标签。只在文件名不正确、没有标签或包含不支持的编码时返回 None
    fn read_by_lofty(path: impl AsRef<Path>, modified: u64, created: u64) -> Option<Self> {
        let path = path.as_ref();
        let options = ParseOptions::new()
            .parsing_mode(ParsingMode::Relaxed)
            .read_tags(true)
            .read_cover_art(false)
            .read_properties(true);
        let tagged_file = match Probe::open(path).and_then(|probe| probe.options(options).read()) {
            Ok(val) => val,
            Err(err) => {
                log::warn!(target: "tag", "metadata parse failed: {}", err);
                return None;
            }
        };

        let properties = tagged_file.properties();
        // DSF 的 bit_depth 字段实为字节序标记，DFF 无 PCM 位深语义；DSD 流统一按 1 bit 处理。
        let is_dsd = is_dsf_path(path) || is_dff_path(path);
        let bit_depth = if is_dsd {
            Some(DSD_NATIVE_BIT_DEPTH)
        } else {
            properties.bit_depth()
        };
        // Lofty 的容器位深对 DSD 不代表采样位深，按其计算会放大码率；统一按原生 1 bit 计算。
        let bitrate = if is_dsd {
            dsd_native_bitrate(properties.sample_rate(), properties.channels())
        } else {
            properties.audio_bitrate()
        };

        if let Some(tag) = tagged_file
            .primary_tag()
            .or_else(|| tagged_file.first_tag())
        {
            let artist = {
                let joined = join_deduped(tag.get_strings(&ItemKey::TrackArtist));
                if joined.is_empty() {
                    "UNKNOWN".to_string()
                } else {
                    joined
                }
            };

            let album_artist = {
                let joined = join_deduped(tag.get_strings(&ItemKey::AlbumArtist));
                if joined.is_empty() {
                    None
                } else {
                    Some(joined)
                }
            };
            let genre = lofty_joined_text(tag, &ItemKey::Genre);
            let year = lofty_text(tag, &ItemKey::Year)
                .or_else(|| lofty_text(tag, &ItemKey::RecordingDate));
            let composer = lofty_joined_text(tag, &ItemKey::Composer);
            let bpm =
                lofty_text(tag, &ItemKey::Bpm).or_else(|| lofty_text(tag, &ItemKey::IntegerBpm));

            return Some(Audio {
                title: tag
                    .title()
                    .unwrap_or(path.file_name()?.to_string_lossy())
                    .to_string(),
                artist,
                album: tag
                    .album()
                    .map(|a| a.to_string())
                    .unwrap_or_else(|| "UNKNOWN".to_string()),
                album_artist,
                genre,
                year,
                composer,
                bpm,
                track: tag.track(),
                disc: tag.disk(),
                duration: properties.duration().as_secs(),
                bitrate,
                sample_rate: properties.sample_rate(),
                bit_depth,
                path: path.to_string_lossy().to_string(),
                modified,
                created,
                by: Some("Lofty".to_string()),
                size: 0,
                valid: true,
                media_id: None,
            });
        }

        Some(Audio {
            title: path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default(),
            artist: std::borrow::Cow::Borrowed("UNKNOWN").to_string(),
            album: std::borrow::Cow::Borrowed("UNKNOWN").to_string(),
            album_artist: None,
            genre: None,
            year: None,
            composer: None,
            bpm: None,
            track: None,
            disc: None,
            duration: properties.duration().as_secs(),
            bitrate,
            sample_rate: properties.sample_rate(),
            bit_depth,
            path: path.to_string_lossy().to_string(),
            modified,
            created,
            by: Some("Lofty".to_string()),
            size: 0,
            valid: true,
            media_id: None,
        })
    }

    /// 使用 Windows Api 获取音乐标签。会因为各种原因返回 Err
    fn read_by_win_music_properties(
        path: impl AsRef<Path>,
        modified: u64,
        created: u64,
    ) -> Result<Self, windows::core::Error> {
        let path = path.as_ref();
        let storage_file = StorageFile::GetFileFromPathAsync(&HSTRING::from(path))?.get()?;
        let music_properties = storage_file
            .Properties()?
            .GetMusicPropertiesAsync()?
            .get()?;

        let duration: Duration = music_properties.Duration()?.into();

        let mut title = music_properties
            .Title()
            .or_else(|_| storage_file.Name())?
            .to_string();
        if title.is_empty() {
            title = storage_file.Name()?.to_string();
        }

        let mut artist = music_properties
            .Artist()
            .unwrap_or(HSTRING::from("UNKNOWN"))
            .to_string();
        if artist.is_empty() {
            artist = "UNKNOWN".to_string();
        }

        let mut album = music_properties
            .Album()
            .unwrap_or(HSTRING::from("UNKNOWN"))
            .to_string();
        if album.is_empty() {
            album = "UNKNOWN".to_string();
        }

        let album_artist = music_properties
            .AlbumArtist()
            .unwrap_or(HSTRING::from(""))
            .to_string();
        let album_artist = if album_artist.is_empty() {
            None
        } else {
            Some(album_artist)
        };

        Ok(Audio {
            title,
            artist,
            album,
            album_artist,
            genre: None,
            year: None,
            composer: None,
            bpm: None,
            track: Some(music_properties.TrackNumber()?),
            disc: None,
            duration: duration.as_secs(),
            bitrate: Some(music_properties.Bitrate()? / 1000),
            sample_rate: None,
            bit_depth: None,
            path: path.to_string_lossy().to_string(),
            modified,
            created,
            by: Some("Windows".to_string()),
            size: 0,
            valid: true,
            media_id: None,
        })
    }
}

struct WinRtWorkerGuard;

impl WinRtWorkerGuard {
    fn initialize() -> Option<Self> {
        unsafe { RoInitialize(RO_INIT_MULTITHREADED) }
            .ok()
            .map(|_| Self)
    }
}

impl Drop for WinRtWorkerGuard {
    fn drop(&mut self) {
        unsafe { RoUninitialize() };
    }
}

/// 通过 Windows 媒体属性读取源文件时长，单位毫秒。
///
/// 不依赖扩展名白名单；文件缺少媒体属性处理器或属性为空时返回错误。
fn windows_media_duration_ms(path: &Path) -> anyhow::Result<u64> {
    let _winrt = WinRtWorkerGuard::initialize();
    let storage_file = StorageFile::GetFileFromPathAsync(&HSTRING::from(path))?.get()?;
    let music_properties = storage_file
        .Properties()?
        .GetMusicPropertiesAsync()?
        .get()?;
    let duration: Duration = music_properties.Duration()?.into();
    let duration_ms = u64::try_from(duration.as_millis()).unwrap_or(u64::MAX);
    if duration_ms == 0 {
        anyhow::bail!("media properties report zero duration");
    }
    Ok(duration_ms)
}

fn tag_reader_worker_count_for(logical_cores: usize, job_count: usize) -> usize {
    (logical_cores.saturating_sub(RESERVED_LOGICAL_CORES) / 2)
        .max(1)
        .min(MAX_TAG_READER_WORKERS)
        .min(job_count)
}

fn tag_reader_worker_count(job_count: usize) -> usize {
    tag_reader_worker_count_for(
        std::thread::available_parallelism()
            .map(|count| count.get())
            .unwrap_or(1),
        job_count,
    )
}

fn read_audio_paths_parallel<F>(paths: &[PathBuf], mut on_progress: F) -> Vec<Option<Audio>>
where
    F: FnMut(usize),
{
    if paths.is_empty() {
        return Vec::new();
    }
    let worker_count = tag_reader_worker_count(paths.len());
    if worker_count <= 1 {
        return paths
            .iter()
            .enumerate()
            .map(|(index, path)| {
                let audio = Audio::read_from_path(path);
                on_progress(index + 1);
                audio
            })
            .collect();
    }

    let next_index = AtomicUsize::new(0);
    let (sender, receiver) = mpsc::channel();
    let mut results: Vec<Option<Audio>> =
        std::iter::repeat_with(|| None).take(paths.len()).collect();
    std::thread::scope(|scope| {
        for _ in 0..worker_count {
            let sender = sender.clone();
            let next_index = &next_index;
            scope.spawn(move || {
                let _winrt = WinRtWorkerGuard::initialize();
                loop {
                    let index = next_index.fetch_add(1, Ordering::Relaxed);
                    if index >= paths.len() {
                        break;
                    }
                    if sender
                        .send((index, Audio::read_from_path(&paths[index])))
                        .is_err()
                    {
                        break;
                    }
                }
            });
        }
        drop(sender);
        for completed in 1..=paths.len() {
            let Ok((index, audio)) = receiver.recv() else {
                break;
            };
            results[index] = audio;
            on_progress(completed);
        }
    });
    results
}

fn should_emit_index_progress(completed: usize, total: usize) -> bool {
    let batch = total
        .div_ceil(INDEX_PROGRESS_TARGET_UPDATES)
        .max(INDEX_PROGRESS_MIN_BATCH);
    completed >= total || completed.is_multiple_of(batch)
}

#[derive(Debug)]
struct AudioFolder {
    path: String,
    /// secs since UNIX_EPOCH
    modified: u64,
    /// biggest created in audios. secs since UNIX_EPOCH
    latest: u64,
    audios: Vec<Audio>,
}

impl AudioFolder {
    fn to_json_value(&self) -> serde_json::Value {
        let mut audios_json: Vec<serde_json::Value> = Vec::new();
        for audio in &self.audios {
            audios_json.push(audio.to_json_value());
        }

        serde_json::json!({
            "path": self.path,
            "modified": self.modified,
            "latest": self.latest,
            "audios": audios_json,
        })
    }

    /// 扫描路径为 path 的文件夹
    fn read_from_folder(path: impl AsRef<Path>) -> Result<AudioFolder, io::Error> {
        let path = path.as_ref();
        let mut audio_paths: Vec<PathBuf> = Vec::new();
        let mut cue_paths: Vec<PathBuf> = Vec::new();
        let mut iso_paths: Vec<PathBuf> = Vec::new();
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            if !entry.file_type()?.is_file() {
                continue;
            }
            let entry_path = entry.path();
            if is_cue_path(&entry_path) {
                cue_paths.push(entry_path);
            } else if is_iso_path(&entry_path) {
                iso_paths.push(entry_path);
            } else if is_supported_audio_path(&entry_path) {
                audio_paths.push(entry_path);
            }
        }

        let (cue_audios, referenced) = read_cue_folder(&cue_paths, &audio_paths);
        let sacd_audios = read_sacd_folder(&iso_paths);
        let unreferenced_paths: Vec<PathBuf> = audio_paths
            .into_iter()
            .filter(|audio_path| !referenced.contains(&path_key(audio_path)))
            .collect();
        let read_results = read_audio_paths_parallel(&unreferenced_paths, |_| {});
        if let Some(failed_path) = read_results
            .iter()
            .position(Option::is_none)
            .and_then(|index| unreferenced_paths.get(index))
        {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                format!("failed to read audio: {}", failed_path.display()),
            ));
        }
        let mut audios: Vec<Audio> = read_results.into_iter().flatten().collect();
        audios.extend(cue_audios);
        audios.extend(sacd_audios);
        let latest = audios.iter().map(|audio| audio.created).max().unwrap_or(0);

        if !audios.is_empty() {
            return Ok(AudioFolder {
                path: path.to_string_lossy().to_string(),
                modified: folder_change_stamp(path),
                latest,
                audios,
            });
        }

        Err(io::Error::new(
            io::ErrorKind::NotFound,
            path.to_string_lossy() + " has no music.",
        ))
    }
}

fn _get_picture_by_windows(path: &str) -> Result<Vec<u8>, windows::core::Error> {
    let file = StorageFile::GetFileFromPathAsync(&HSTRING::from(path))?.get()?;
    let thumbnail = file
        .GetThumbnailAsyncOverloadDefaultSizeDefaultOptions(ThumbnailMode::MusicView)?
        .get()?;

    let size = thumbnail.Size()? as u32;
    let stream: IInputStream = thumbnail.cast()?;

    let mut buffer = vec![0u8; size as usize];
    let data_reader = DataReader::CreateDataReader(&stream)?;
    data_reader.LoadAsync(size)?.get()?;
    data_reader.ReadBytes(&mut buffer)?;

    data_reader.Close()?;
    stream.Close()?;

    Ok(buffer)
}

fn read_picture_by_alternative(path: &Path) -> Option<Vec<u8>> {
    if is_dsf_path(path) {
        return read_dsf_picture(path);
    }
    if is_dff_path(path) {
        return read_dff_picture(path);
    }
    if is_asf_path(path) {
        return read_asf_picture(path);
    }
    if is_generic_id3_path(path) {
        return read_id3_picture(path);
    }
    if is_symphonia_path(path) {
        if let Some(picture) = read_symphonia_metadata(path).and_then(|metadata| metadata.picture) {
            return Some(picture);
        }
    }
    read_id3_picture(path)
}

fn _get_picture_by_lofty(path: &str) -> Option<Vec<u8>> {
    let options = ParseOptions::new()
        .parsing_mode(ParsingMode::Relaxed)
        .read_tags(true)
        .read_cover_art(true)
        .read_properties(false);

    let tagged_file = match Probe::open(path).and_then(|p| p.options(options).read()) {
        Ok(f) => f,
        Err(_) => return read_picture_by_alternative(Path::new(path)),
    };

    let picture = tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag())
        .and_then(|tag| tag.pictures().first())
        .map(|picture| picture.data().to_vec());

    picture.or_else(|| read_picture_by_alternative(Path::new(path)))
}

pub(crate) fn get_embedded_picture_from_path(
    path: &str,
    width: u32,
    height: u32,
) -> Option<Vec<u8>> {
    let picture = _get_picture_by_lofty(path)?;
    let loaded = image::load_from_memory(&picture).ok()?;
    let ratio = loaded.width() as f32 / loaded.height() as f32;
    let (result_width, result_height) = if ratio > 1.0 {
        (width, (width as f32 / ratio).round() as u32)
    } else {
        ((height as f32 * ratio).round() as u32, height)
    };
    let resized = imageops::resize(
        &loaded,
        result_width.max(1),
        result_height.max(1),
        imageops::FilterType::Triangle,
    );
    let mut output = Cursor::new(Vec::new());
    resized
        .write_to(&mut output, image::ImageFormat::Png)
        .ok()?;
    Some(output.into_inner())
}

const PICTURE_CACHE_CAPACITY: usize = 96;
type PictureCache = OnceLock<Mutex<VecDeque<(String, Vec<u8>)>>>;
static PICTURE_CACHE: PictureCache = OnceLock::new();

fn _picture_cache_key(path: &str, width: u32, height: u32) -> String {
    let modified_secs = fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{path}|{modified_secs}|{width}x{height}")
}

fn evict_picture_cache_for_path(path: &str) {
    let Ok(mut cache) = PICTURE_CACHE
        .get_or_init(|| Mutex::new(VecDeque::new()))
        .lock()
    else {
        return;
    };
    let prefix = format!("{path}|");
    cache.retain(|(key, _)| !key.starts_with(&prefix));
}

/// for Flutter  
/// 一次调用完成封面读取+颜色提取，避免 image bytes 穿越 FFI 两次
pub fn get_picture_and_colors(
    path: String,
    width: u32,
    height: u32,
    num_colors: i32,
) -> (Option<Vec<u8>>, Vec<u32>) {
    let pic = match _get_picture_by_lofty(&path) {
        Some(p) => p,
        None => match _get_picture_by_windows(&path) {
            Ok(val) => val,
            Err(err) => {
                log::warn!(target: "tag", "fail to get pic: {}", err);
                return (None, vec![]);
            }
        },
    };
    let loaded = match image::load_from_memory(&pic) {
        Ok(loaded) => loaded,
        Err(err) => {
            log::warn!(target: "tag", "fail to decode cover: {}", err);
            return (None, vec![]);
        }
    };
    drop(pic);
    let colors = match super::color_extraction::extract_mesh_colors_from_decoded_image(
        &loaded, num_colors,
    ) {
        Ok(colors) => colors,
        Err(err) => {
            log::warn!(target: "tag", "fail to extract colors: {}", err);
            vec![]
        }
    };
    let ratio = loaded.width() as f32 / loaded.height() as f32;
    let (rw, rh) = if ratio > 1.0 {
        (width, (width as f32 / ratio).round() as u32)
    } else {
        ((height as f32 * ratio).round() as u32, height)
    };
    let resized = image::imageops::resize(
        &loaded,
        rw.max(1),
        rh.max(1),
        image::imageops::FilterType::Triangle,
    );
    drop(loaded);
    let mut buf = std::io::Cursor::new(Vec::new());
    let resized_png = if resized.write_to(&mut buf, image::ImageFormat::Png).is_ok() {
        Some(buf.into_inner())
    } else {
        None
    };

    (resized_png, colors)
}

/// for Flutter  
/// 如果无法通过 Lofty 获取则通过 Windows 获取
pub fn get_picture_from_path(path: String, width: u32, height: u32) -> Option<Vec<u8>> {
    let cache_key = _picture_cache_key(&path, width, height);
    if let Ok(cache_lock) = PICTURE_CACHE
        .get_or_init(|| Mutex::new(VecDeque::new()))
        .lock()
    {
        if let Some(pos) = cache_lock.iter().position(|(k, _)| k == &cache_key) {
            let mut cache = cache_lock;
            if let Some((k, v)) = cache.remove(pos) {
                let val = v.clone();
                cache.push_front((k, v));
                return Some(val);
            }
        }
    }

    let pic_option =
        _get_picture_by_lofty(&path).or_else(|| match _get_picture_by_windows(&path) {
            Ok(val) => Some(val),
            Err(err) => {
                log::warn!(target: "tag", "fail to get pic: {}", err);
                None
            }
        });

    if let Some(pic) = &pic_option {
        if let Ok(loaded_pic) = image::load_from_memory(pic) {
            // 计算新的宽高，保持原比例
            let pic_ratio = loaded_pic.width() as f32 / loaded_pic.height() as f32;

            let (result_width, result_height) = if pic_ratio > 1.0 {
                (width, (width as f32 / pic_ratio).round() as u32)
            } else {
                ((height as f32 * pic_ratio).round() as u32, height)
            };

            let resized_img = imageops::resize(
                &loaded_pic,
                result_width,
                result_height,
                imageops::FilterType::Triangle,
            );

            let mut output = Cursor::new(Vec::new());
            let rgb = image::DynamicImage::ImageRgba8(resized_img).to_rgb8();
            if rgb.write_to(&mut output, image::ImageFormat::Jpeg).is_ok() {
                let out = output.into_inner();
                if let Ok(mut cache) = PICTURE_CACHE
                    .get_or_init(|| Mutex::new(VecDeque::new()))
                    .lock()
                {
                    if let Some(pos) = cache.iter().position(|(k, _)| k == &cache_key) {
                        cache.remove(pos);
                    }
                    cache.push_front((cache_key, out.clone()));
                    while cache.len() > PICTURE_CACHE_CAPACITY {
                        cache.pop_back();
                    }
                }
                return Some(out);
            }
            // 已经能解码时不要把原图大图送回界面
            return None;
        }
    }

    pic_option
}

fn is_lyric_item_key(key: &ItemKey) -> bool {
    let normalized = format!("{key:?}").to_ascii_lowercase();
    normalized.contains("lyric") || normalized.contains("uslt") || normalized.contains("sylt")
}

fn _get_lyric_from_lofty(path: &str) -> Option<String> {
    let path_ref = Path::new(&path);
    let options = ParseOptions::new()
        .parsing_mode(ParsingMode::Relaxed)
        .read_tags(true);
    let probe = match Probe::open(path_ref) {
        Ok(v) => v,
        Err(err) => {
            log::warn!(target: "tag", "lofty probe open error: {:?}", err.kind());
            return None;
        }
    };
    let tagged_file = match probe.options(options).read() {
        Ok(f) => f,
        Err(err) => {
            log::warn!(target: "tag", "lofty probe read error: {:?}", err.kind());
            return None;
        }
    };
    let tag = match tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag())
    {
        Some(t) => t,
        None => {
            log::debug!(target: "tag", "lofty: no primary/first tag found");
            return None;
        }
    };
    // 遍历所有 ItemKey::Lyrics（可能有多个 USLT/LYRICS 帧）
    for item in tag.get_items(&ItemKey::Lyrics) {
        if let Some(lyric) = item.value().text() {
            let text = lyric.to_string();
            if !text.trim().is_empty() {
                return Some(text);
            }
            log::debug!(target: "tag", "lofty: lyric text is empty");
        } else {
            log::debug!(target: "tag", "lofty: lyric value text() returned None");
        }
    }

    log::debug!(target: "tag", "lofty: no ItemKey::Lyrics found, scanning lyric-named items");

    for item in tag.items() {
        if !is_lyric_item_key(item.key()) {
            continue;
        }
        if let Some(val) = item.value().text() {
            let text = val.to_string().trim().to_string();
            if text.is_empty() {
                continue;
            }
            // 判断是否像歌词：包含时间戳标记 [mm:ss 或包含换行符
            let has_timestamp = text.contains('[') && (text.contains(':') || text.contains('.'));
            let has_newlines = text.contains('\n');
            if has_timestamp || has_newlines {
                log::debug!(
                    target: "tag",
                    "lofty: found lyric-like content in key={:?}, len={}",
                    item.key(),
                    text.len()
                );
                return Some(text);
            }
        }
    }
    log::debug!(target: "tag", "no lyric-like content found in any tag item");
    None
}

/// for Flutter   
/// 只读取 ID3V2、VorbisComment、Mp4Ilst 存储的内嵌歌词
pub fn get_lyric_from_path(path: String) -> Option<String> {
    _get_lyric_from_lofty(&path)
}

#[derive(Clone)]
pub struct WriteTagPayload {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub genre: Option<String>,
    pub year: Option<String>,
    pub track: Option<String>,
    pub track_total: Option<String>,
    pub disc: Option<String>,
    pub disc_total: Option<String>,
    pub composer: Option<String>,
    pub lyricist: Option<String>,
    pub label: Option<String>,
    pub comment: Option<String>,
    pub bpm: Option<String>,
    pub language: Option<String>,
    pub copyright: Option<String>,
    pub license: Option<String>,
}

/// 获取或创建音频文件的主标签。若无现有标签则插入新标签后再获取。
macro_rules! get_or_create_tag {
    ($tagged_file:expr) => {
        if let Some(tag) = $tagged_file.primary_tag_mut() {
            tag
        } else if let Some(tag) = $tagged_file.first_tag_mut() {
            tag
        } else {
            let tag_type = $tagged_file.primary_tag_type();
            $tagged_file.insert_tag(Tag::new(tag_type));
            if let Some(tag) = $tagged_file.primary_tag_mut() {
                tag
            } else if let Some(tag) = $tagged_file.first_tag_mut() {
                tag
            } else {
                return Err("failed to create tag".to_string());
            }
        }
    };
}

/// for Flutter
/// 通用标签写入函数。only_changed=true 时只写非 None 字段
pub fn write_audio_tags(
    path: String,
    payload: WriteTagPayload,
    only_changed: bool,
) -> Result<(), String> {
    let path_ref = Path::new(&path);
    let options = ParseOptions::new()
        .parsing_mode(ParsingMode::Relaxed)
        .read_cover_art(true)
        .read_properties(false)
        .read_tags(true);

    let mut tagged_file = match Probe::open(path_ref) {
        Ok(v) => match v.options(options).read() {
            Ok(f) => f,
            Err(err) => return Err(format!("Error reading file: {:?}", err.kind())),
        },
        Err(err) => return Err(format!("Error opening file: {:?}", err.kind())),
    };

    let tag = get_or_create_tag!(tagged_file);

    macro_rules! write_field {
        ($val:expr, $key:expr) => {
            if let Some(v) = &$val {
                let trimmed = v.trim().to_string();
                if trimmed.is_empty() {
                    let _ = tag.remove_key(&$key);
                } else {
                    tag.insert_text($key, trimmed);
                }
            }
        };
    }

    if !only_changed {
        let _ = tag.remove_key(&ItemKey::TrackTitle);
        let _ = tag.remove_key(&ItemKey::TrackArtist);
        let _ = tag.remove_key(&ItemKey::AlbumTitle);
        let _ = tag.remove_key(&ItemKey::AlbumArtist);
        let _ = tag.remove_key(&ItemKey::Genre);
        let _ = tag.remove_key(&ItemKey::Year);
        let _ = tag.remove_key(&ItemKey::RecordingDate);
        let _ = tag.remove_key(&ItemKey::TrackNumber);
        let _ = tag.remove_key(&ItemKey::TrackTotal);
        let _ = tag.remove_key(&ItemKey::DiscNumber);
        let _ = tag.remove_key(&ItemKey::DiscTotal);
        let _ = tag.remove_key(&ItemKey::Composer);
        let _ = tag.remove_key(&ItemKey::Lyricist);
        let _ = tag.remove_key(&ItemKey::Label);
        let _ = tag.remove_key(&ItemKey::Comment);
        let _ = tag.remove_key(&ItemKey::Bpm);
        let _ = tag.remove_key(&ItemKey::IntegerBpm);
        let _ = tag.remove_key(&ItemKey::Language);
        let _ = tag.remove_key(&ItemKey::CopyrightMessage);
        let _ = tag.remove_key(&ItemKey::License);
        let _ = tag.remove_key(&ItemKey::Unknown("LICENSE".to_string()));
    }

    write_field!(payload.title, ItemKey::TrackTitle);
    write_field!(payload.artist, ItemKey::TrackArtist);
    write_field!(payload.album, ItemKey::AlbumTitle);
    write_field!(payload.album_artist, ItemKey::AlbumArtist);
    write_field!(payload.genre, ItemKey::Genre);
    write_field!(payload.year, ItemKey::RecordingDate);
    write_field!(payload.track, ItemKey::TrackNumber);
    write_field!(payload.track_total, ItemKey::TrackTotal);
    write_field!(payload.disc, ItemKey::DiscNumber);
    write_field!(payload.disc_total, ItemKey::DiscTotal);
    write_field!(payload.composer, ItemKey::Composer);
    write_field!(payload.lyricist, ItemKey::Lyricist);
    write_field!(payload.label, ItemKey::Label);
    write_field!(payload.comment, ItemKey::Comment);
    write_field!(payload.bpm, ItemKey::IntegerBpm);
    write_field!(payload.language, ItemKey::Language);
    write_field!(payload.copyright, ItemKey::CopyrightMessage);
    if let Some(value) = &payload.license {
        let trimmed = value.trim().to_string();
        let _ = tag.remove_key(&ItemKey::License);
        let custom_key = ItemKey::Unknown("LICENSE".to_string());
        let _ = tag.remove_key(&custom_key);
        if !trimmed.is_empty() {
            if tag.tag_type() == TagType::Id3v2 {
                tag.insert_unchecked(TagItem::new(custom_key, ItemValue::Text(trimmed)));
            } else {
                tag.insert_text(ItemKey::License, trimmed);
            }
        }
    }

    tagged_file
        .save_to_path(&path, WriteOptions::default())
        .map_err(|e| format!("Error saving tags: {:?}", e.kind()))?;
    Ok(())
}

/// for Flutter
/// 写入歌词到音频文件标签（ID3/VorbisComment/MP4 等），使用 Lofty 的 `ItemKey::Lyrics` 映射
/// 使用 ParsingMode::Relaxed 兼容更多有问题的标签文件
pub fn write_lyric_to_path(path: String, lyric: String) -> Result<(), String> {
    let path_ref = Path::new(&path);
    let options = ParseOptions::new()
        .parsing_mode(ParsingMode::Relaxed)
        .read_cover_art(true)
        .read_properties(false)
        .read_tags(true);

    let mut tagged_file = match Probe::open(path_ref) {
        Ok(v) => match v.options(options).read() {
            Ok(f) => f,
            Err(err) => return Err(format!("Error reading file: {:?}", err.kind())),
        },
        Err(err) => return Err(format!("Error opening file: {:?}", err.kind())),
    };

    let tag = get_or_create_tag!(tagged_file);

    let _ = tag.remove_key(&ItemKey::Lyrics);
    tag.insert_text(ItemKey::Lyrics, lyric.clone());
    tagged_file
        .save_to_path(&path, WriteOptions::default())
        .map_err(|e| format!("Error saving lyrics: {:?}", e.kind()))?;
    match _get_lyric_from_lofty(&path) {
        Some(saved) if lyrics_text_equiv(&saved, &lyric) => Ok(()),
        Some(_) => Err("written lyrics do not match the saved tag".to_string()),
        None => Err("written lyrics could not be read back".to_string()),
    }
}

fn lyrics_text_equiv(a: &str, b: &str) -> bool {
    a.replace("\r\n", "\n").replace('\r', "\n").trim()
        == b.replace("\r\n", "\n").replace('\r', "\n").trim()
}

/// for Flutter
/// 写入内嵌封面图片到音频文件标签。
/// `bytes` 为空时移除封面。图片最长边超过 1600 时等比缩放。
/// 保留原始格式（PNG/JPEG/GIF），无法识别格式时降级为 JPEG。
pub fn write_audio_cover(path: String, bytes: Vec<u8>) -> Result<(), String> {
    let path_ref = Path::new(&path);
    let options = ParseOptions::new()
        .parsing_mode(ParsingMode::Relaxed)
        .read_cover_art(true)
        .read_properties(false)
        .read_tags(true);

    let mut tagged_file = match Probe::open(path_ref) {
        Ok(v) => match v.options(options).read() {
            Ok(f) => f,
            Err(err) => return Err(format!("Error reading file: {:?}", err.kind())),
        },
        Err(err) => return Err(format!("Error opening file: {:?}", err.kind())),
    };

    let tag = get_or_create_tag!(tagged_file);

    tag.remove_picture_type(PictureType::CoverFront);

    if !bytes.is_empty() {
        let img =
            image::load_from_memory(&bytes).map_err(|e| format!("Error decoding image: {e}"))?;

        const MAX_SIDE: u32 = 1600;
        let img = if img.width() > MAX_SIDE || img.height() > MAX_SIDE {
            img.resize(MAX_SIDE, MAX_SIDE, imageops::FilterType::Lanczos3)
        } else {
            img
        };

        // 按原始格式编码，无法识别时降级 JPEG
        let (encoded, mime) = detect_and_encode(&img, &bytes)?;

        let picture = Picture::new_unchecked(PictureType::CoverFront, Some(mime), None, encoded);
        tag.push_picture(picture);
    }

    tagged_file
        .save_to_path(&path, WriteOptions::default())
        .map_err(|e| format!("Error saving cover: {:?}", e.kind()))?;
    evict_picture_cache_for_path(&path);
    Ok(())
}

/// 根据原始字节的 magic bytes 检测图片格式，按原格式编码返回。
/// 支持 PNG、JPEG、GIF；无法识别时降级为 JPEG。
fn detect_and_encode(img: &DynamicImage, raw_bytes: &[u8]) -> Result<(Vec<u8>, MimeType), String> {
    let format = if raw_bytes.len() >= 8 && raw_bytes[..8] == *b"\x89PNG\r\n\x1a\n" {
        Some(image::ImageFormat::Png)
    } else if raw_bytes.len() >= 3 && raw_bytes[..3] == *b"\xFF\xD8\xFF" {
        Some(image::ImageFormat::Jpeg)
    } else {
        None
    };

    match format {
        Some(f @ image::ImageFormat::Png) => {
            let mut buf = Vec::new();
            img.write_to(&mut Cursor::new(&mut buf), f)
                .map_err(|e| format!("Error encoding PNG: {e}"))?;
            Ok((buf, MimeType::Png))
        }
        Some(f @ image::ImageFormat::Jpeg) => {
            let mut buf = Vec::new();
            img.write_to(&mut Cursor::new(&mut buf), f)
                .map_err(|e| format!("Error encoding JPEG: {e}"))?;
            Ok((buf, MimeType::Jpeg))
        }
        _ => {
            // 不支持的格式降级为 JPEG
            let mut buf = Vec::new();
            img.write_to(&mut Cursor::new(&mut buf), image::ImageFormat::Jpeg)
                .map_err(|e| format!("Error encoding JPEG fallback: {e}"))?;
            Ok((buf, MimeType::Jpeg))
        }
    }
}

/// 归一化路径用于比较：反斜杠转斜杠、去掉尾部斜杠、转小写。
fn path_key(path: &Path) -> String {
    let unified = path.to_string_lossy().replace('\\', "/");
    unified.trim_end_matches('/').to_lowercase()
}

fn system_time_secs(time: io::Result<std::time::SystemTime>) -> u64 {
    time.unwrap_or(UNIX_EPOCH)
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_secs()
}

/// 目录变更戳：目录 mtime 与同目录 XML 元数据指纹中的最大值。
///
/// 只改 XML 内容不会改变目录 mtime，因此把每个 XML 的修改时间与文件长度混入
/// 同一个数值，索引据此判断目录是否需要重建。目录或条目不可读时退回目录 mtime。
fn folder_change_stamp(path: &Path) -> u64 {
    let mut stamp = system_time_secs(fs::metadata(path).and_then(|metadata| metadata.modified()));
    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(_) => return stamp,
    };
    for entry in entries.flatten() {
        match entry.file_type() {
            Ok(kind) if kind.is_file() => {}
            _ => continue,
        }
        let entry_path = entry.path();
        if !is_xml_path(&entry_path) {
            continue;
        }
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        let modified = system_time_secs(metadata.modified());
        let fingerprint = modified
            .saturating_mul(1_u64 << 20)
            .saturating_add(metadata.len() & 0xF_FFFF);
        stamp = stamp.max(fingerprint);
    }
    stamp
}

/// CUE 展开所需的源文件属性，标签不可读时保留文件元数据。
struct CueSourceInfo {
    path: PathBuf,
    bitrate: Option<u32>,
    sample_rate: Option<u32>,
    bit_depth: Option<u8>,
    modified: u64,
    created: u64,
    size: u64,
}

/// 把 CUE 展开成虚拟曲目。
///
/// 返回展开出的曲目与 CUE 引用的源文件归一化路径（这些源文件不再单独入库）。
/// 单个 CUE 损坏或源文件缺失只跳过对应内容，不中断整批扫描。
fn read_cue_folder(
    cue_paths: &[PathBuf],
    _audio_paths: &[PathBuf],
) -> (Vec<Audio>, HashSet<String>) {
    let mut audios: Vec<Audio> = Vec::new();
    let mut referenced: HashSet<String> = HashSet::new();

    for cue_path in cue_paths {
        let sheet = match parse_cue_file(cue_path) {
            Ok(sheet) => sheet,
            Err(error) => {
                log::warn!(
                    target: "tag",
                    "skip cue {}: {}",
                    cue_path.display(),
                    error
                );
                continue;
            }
        };
        let Some(cue_dir) = cue_path.parent() else {
            log::warn!(
                target: "tag",
                "skip cue without parent folder: {}",
                cue_path.display()
            );
            continue;
        };
        let album_fallback = cue_path
            .file_stem()
            .map(|stem| stem.to_string_lossy().to_string())
            .filter(|stem| !stem.is_empty())
            .unwrap_or_else(|| "UNKNOWN".to_string());
        let album = sheet.title.clone().unwrap_or(album_fallback);

        let mut sources: Vec<Option<CueSourceInfo>> = Vec::with_capacity(sheet.files.len());
        let mut file_durations_ms: Vec<Option<u64>> = Vec::with_capacity(sheet.files.len());
        for (file_index, file) in sheet.files.iter().enumerate() {
            let source_path = cue_dir.join(file.name.as_str());
            let metadata = match fs::metadata(&source_path) {
                Ok(metadata) if metadata.is_file() => metadata,
                Ok(_) => {
                    log::warn!(
                        target: "tag",
                        "cue source is not a file: {}",
                        source_path.display()
                    );
                    sources.push(None);
                    file_durations_ms.push(None);
                    continue;
                }
                Err(error) => {
                    log::warn!(
                        target: "tag",
                        "cue source missing: {} ({}): {}",
                        source_path.display(),
                        cue_path.display(),
                        error
                    );
                    sources.push(None);
                    file_durations_ms.push(None);
                    continue;
                }
            };
            referenced.insert(path_key(&source_path));

            let (mut duration_ms, bitrate, sample_rate, bit_depth) =
                match Audio::read_from_path(&source_path) {
                    Some(audio) => (
                        if audio.duration == 0 {
                            None
                        } else {
                            Some(audio.duration.saturating_mul(1000))
                        },
                        audio.bitrate,
                        audio.sample_rate,
                        audio.bit_depth,
                    ),
                    None => {
                        log::warn!(
                            target: "tag",
                            "cue source metadata fallback: {}",
                            source_path.display()
                        );
                        (None, None, None, None)
                    }
                };
            let file_has_tracks = sheet
                .tracks
                .iter()
                .any(|track| track.file_index == file_index);
            if duration_ms.is_none() && file_has_tracks {
                let extension = source_path
                    .extension()
                    .and_then(|ext| ext.to_str())
                    .unwrap_or("<none>");
                let builtin_note = if is_supported_audio_path(&source_path) {
                    format!("built-in readers: no duration reported for .{extension}")
                } else {
                    format!("built-in readers: .{extension} is outside the supported format set")
                };
                let (probed_ms, attempts) = probe_container_duration_ms(
                    &source_path,
                    builtin_note,
                    windows_media_duration_ms,
                    header_duration_ms,
                );
                duration_ms = probed_ms;
                if let Some(resolved_ms) = duration_ms {
                    log::info!(
                        target: "tag",
                        "cue source duration fallback: {} -> {} ms",
                        source_path.display(),
                        resolved_ms
                    );
                } else {
                    log::warn!(
                        target: "tag",
                        "cue source duration unresolved: {}; attempts: {}; last track ends at its start",
                        source_path.display(),
                        attempts.join(" | ")
                    );
                }
            }
            file_durations_ms.push(duration_ms);
            sources.push(Some(CueSourceInfo {
                path: source_path,
                bitrate,
                sample_rate,
                bit_depth,
                modified: system_time_secs(metadata.modified()),
                created: system_time_secs(metadata.created()),
                size: metadata.len(),
            }));
        }

        let (segments, warnings) = expand_segments(&sheet, &file_durations_ms);
        for warning in warnings {
            log::warn!(target: "tag", "cue {}: {}", cue_path.display(), warning);
        }

        for segment in segments {
            let Some(Some(source)) = sources.get(segment.file_index) else {
                continue;
            };
            let title = segment
                .title
                .clone()
                .or_else(|| sheet.title.clone())
                .unwrap_or_else(|| format!("Track {:02}", segment.track_number));
            let artist = segment
                .performer
                .clone()
                .or_else(|| sheet.performer.clone())
                .unwrap_or_else(|| "UNKNOWN".to_string());
            let source_path = source.path.to_string_lossy().to_string();
            audios.push(Audio {
                title,
                artist,
                album: album.clone(),
                album_artist: sheet.performer.clone(),
                genre: None,
                year: None,
                composer: None,
                bpm: None,
                track: Some(segment.track_number),
                disc: None,
                duration: segment.duration_ms().saturating_add(500) / 1000,
                bitrate: source.bitrate,
                sample_rate: source.sample_rate,
                bit_depth: source.bit_depth,
                path: segment_path_with_range(
                    &source_path,
                    segment.track_number,
                    segment.start_ms,
                    segment.end_ms,
                ),
                modified: source.modified,
                created: source.created,
                by: Some("cue".to_string()),
                size: source.size,
                valid: true,
                media_id: None,
            });
        }
    }

    (audios, referenced)
}

/// 把 SACD ISO 展开成虚拟曲目。
///
/// 优先使用双声道区，没有双声道区时退回第一个音频区。普通 ISO 静默跳过；
/// SACD 目录解析失败只告警并跳过该镜像，不中断整批扫描。专辑与曲目字段优先
/// 取 ISO 同目录 XML，没有可用 XML 时回退到 ISO 文件名与 `Track NN`、`UNKNOWN`。
fn read_sacd_folder(iso_paths: &[PathBuf]) -> Vec<Audio> {
    let mut audios: Vec<Audio> = Vec::new();

    for iso_path in iso_paths {
        if !is_sacd_iso(iso_path) {
            continue;
        }
        let toc = match read_sacd_toc(iso_path) {
            Ok(toc) => toc,
            Err(error) => {
                log::warn!(
                    target: "tag",
                    "skip sacd {}: {}",
                    iso_path.display(),
                    error
                );
                continue;
            }
        };
        let area = match toc
            .areas
            .iter()
            .find(|area| area.kind == SacdAreaKind::TwoChannel)
        {
            Some(area) => area,
            None => match toc.areas.first() {
                Some(area) => area,
                None => continue,
            },
        };
        if area.tracks.is_empty() {
            continue;
        }
        let area_label = match area.kind {
            SacdAreaKind::TwoChannel => "2ch",
            SacdAreaKind::MultiChannel => "mch",
        };
        let metadata = match fs::metadata(iso_path) {
            Ok(metadata) => metadata,
            Err(error) => {
                log::warn!(
                    target: "tag",
                    "skip sacd {}: {}",
                    iso_path.display(),
                    error
                );
                continue;
            }
        };
        let modified = system_time_secs(metadata.modified());
        let created = system_time_secs(metadata.created());
        let size = metadata.len();
        let album = iso_path
            .file_stem()
            .map(|stem| stem.to_string_lossy().to_string())
            .filter(|stem| !stem.is_empty())
            .unwrap_or_else(|| "UNKNOWN".to_string());
        let iso_path_str = iso_path.to_string_lossy().to_string();

        let xml_metadata = load_sacd_xml_metadata(iso_path);
        if xml_metadata.is_none() {
            log::warn!(
                target: "tag",
                "SACD 没有可用的同目录 XML 元数据，回退默认值: iso={}, folder={}",
                iso_path.display(),
                iso_path
                    .parent()
                    .map(|parent| parent.display().to_string())
                    .unwrap_or_default()
            );
        }
        let album = xml_metadata
            .as_ref()
            .and_then(|metadata| metadata.album.clone())
            .unwrap_or(album);
        let album_artist = xml_metadata
            .as_ref()
            .and_then(|metadata| metadata.album_artist.clone());

        for (index, track) in area.tracks.iter().enumerate() {
            let number = u32::from(track.number);
            let xml_track = xml_metadata
                .as_ref()
                .and_then(|metadata| track_for(metadata, number, index));
            let title = xml_track
                .and_then(|entry| entry.title.clone())
                .unwrap_or_else(|| format!("Track {number:02}"));
            let artist = xml_track
                .and_then(|entry| entry.artist.clone())
                .unwrap_or_else(|| "UNKNOWN".to_string());
            let duration = if track.duration_ms > 0 {
                track.duration_ms.saturating_add(500) / 1000
            } else {
                xml_track
                    .and_then(|entry| entry.duration_secs)
                    .unwrap_or(0)
            };
            let end_ms = track.start_ms.saturating_add(track.duration_ms);
            audios.push(Audio {
                title,
                artist,
                album: album.clone(),
                album_artist: album_artist.clone(),
                genre: None,
                year: None,
                composer: None,
                bpm: None,
                track: Some(number),
                disc: None,
                duration,
                bitrate: None,
                sample_rate: None,
                bit_depth: Some(DSD_NATIVE_BIT_DEPTH),
                path: sacd_segment_path(
                    &iso_path_str,
                    area_label,
                    number,
                    track.start_ms,
                    end_ms,
                ),
                modified,
                created,
                by: Some("sacd".to_string()),
                size,
                valid: true,
                media_id: None,
            });
        }
    }

    audios
}

/// 递归收集所有子文件夹中的音频文件路径，按父目录分组。
/// 一次遍历同时完成「统计总数」和「收集路径」，避免二次目录遍历。
fn collect_audio_files_by_folder(
    folder: impl AsRef<Path>,
    count: &mut u64,
    by_folder: &mut HashMap<String, Vec<PathBuf>>,
    cue_by_folder: &mut HashMap<String, Vec<PathBuf>>,
    sacd_by_folder: &mut HashMap<String, Vec<PathBuf>>,
    seen: &mut HashSet<String>,
    directory_count: &mut usize,
    max_directories: Option<usize>,
) -> io::Result<()> {
    let folder_str = folder.as_ref().to_string_lossy().to_string();
    if !seen.insert(folder_str.clone()) {
        return Ok(());
    }
    *directory_count += 1;
    if max_directories.is_some_and(|limit| *directory_count > limit) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "SMB 远程曲库目录数量超过限制",
        ));
    }
    for entry in fs::read_dir(folder.as_ref())? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            collect_audio_files_by_folder(
                entry.path(),
                count,
                by_folder,
                cue_by_folder,
                sacd_by_folder,
                seen,
                directory_count,
                max_directories,
            )?;
        } else if file_type.is_file() {
            let path = entry.path();
            if is_cue_path(&path) {
                *count += 1;
                cue_by_folder
                    .entry(folder_str.clone())
                    .or_default()
                    .push(path);
            } else if is_iso_path(&path) {
                *count += 1;
                sacd_by_folder
                    .entry(folder_str.clone())
                    .or_default()
                    .push(path);
            } else if is_supported_audio_path(&path) {
                *count += 1;
                by_folder
                    .entry(folder_str.clone())
                    .or_default()
                    .push(path);
            }
        }
    }
    Ok(())
}

/// for Flutter  
/// 扫描给定路径下所有子文件夹（包括自己）的音乐文件并把索引保存在 index_path/index.json。
pub fn build_index_from_folders_recursively(
    folders: Vec<String>,
    index_path: String,
    sink: StreamSink<IndexActionState>,
) -> Result<(), io::Error> {
    build_index_from_folders(folders, index_path, sink, false)
}

/// for Flutter
/// SMB 远程来源专用入口：只接受 Windows 网络路径，并限制目录数量。
pub fn build_remote_index_from_folders_recursively(
    folders: Vec<String>,
    index_path: String,
    sink: StreamSink<IndexActionState>,
) -> Result<(), io::Error> {
    build_index_from_folders(folders, index_path, sink, true)
}

fn build_index_from_folders(
    folders: Vec<String>,
    index_path: String,
    sink: StreamSink<IndexActionState>,
    remote: bool,
) -> Result<(), io::Error> {
    validate_scan_roots(&folders, remote)?;
    let index_dir = PathBuf::from(&index_path);
    let mut audio_folders: Vec<AudioFolder> = vec![];
    let mut scanned: u64 = 0;
    let mut unreadable_total: u64 = 0;
    let mut seen: HashSet<String> = HashSet::new();
    let mut directory_count = 0_usize;
    let mut total: u64 = 0;
    let mut by_folder: HashMap<String, Vec<PathBuf>> = HashMap::new();
    let mut cue_by_folder: HashMap<String, Vec<PathBuf>> = HashMap::new();
    let mut sacd_by_folder: HashMap<String, Vec<PathBuf>> = HashMap::new();
    for item in &folders {
        collect_audio_files_by_folder(
            Path::new(item),
            &mut total,
            &mut by_folder,
            &mut cue_by_folder,
            &mut sacd_by_folder,
            &mut seen,
            &mut directory_count,
            remote.then_some(MAX_REMOTE_DIRECTORIES),
        )?;
    }

    // 先展开全部 CUE：得到虚拟曲目和它们引用的源文件，源文件在后续音频扫描中跳过。
    let mut virtual_audios_by_folder: HashMap<String, Vec<Audio>> = HashMap::new();
    let mut referenced: HashSet<String> = HashSet::new();
    for (dir_path, cue_paths) in &cue_by_folder {
        let _ = sink.add(IndexActionState {
            progress: if total == 0 {
                0.0
            } else {
                scanned as f64 / total as f64
            },
            message: String::from("正在扫描 ") + dir_path,
            phase: IndexPhase::Scanning,
            unreadable_total,
        });

        let (audios, cue_referenced) = read_cue_folder(cue_paths, &[]);
        referenced.extend(cue_referenced);
        scanned += cue_paths.len() as u64;
        if !audios.is_empty() {
            virtual_audios_by_folder.insert(dir_path.clone(), audios);
        }
    }

    // 再展开 SACD ISO：按区展开成虚拟曲目，普通 ISO 静默跳过。
    for (dir_path, iso_paths) in &sacd_by_folder {
        let _ = sink.add(IndexActionState {
            progress: if total == 0 {
                0.0
            } else {
                scanned as f64 / total as f64
            },
            message: String::from("正在扫描 ") + dir_path,
            phase: IndexPhase::Scanning,
            unreadable_total,
        });

        let audios = read_sacd_folder(iso_paths);
        scanned += iso_paths.len() as u64;
        if !audios.is_empty() {
            virtual_audios_by_folder
                .entry(dir_path.clone())
                .or_default()
                .extend(audios);
        }
    }

    let mut dir_paths: Vec<String> = by_folder
        .keys()
        .chain(cue_by_folder.keys())
        .chain(sacd_by_folder.keys())
        .cloned()
        .collect();
    dir_paths.sort();
    dir_paths.dedup();

    for dir_path in &dir_paths {
        let mut audios: Vec<Audio> = virtual_audios_by_folder
            .remove(dir_path)
            .unwrap_or_default();
        let audio_count = by_folder.get(dir_path).map_or(0, |paths| paths.len());
        let file_paths: Vec<PathBuf> = match by_folder.get(dir_path) {
            Some(paths) => paths
                .iter()
                .filter(|path| !referenced.contains(&path_key(path.as_path())))
                .cloned()
                .collect(),
            None => Vec::new(),
        };
        let skipped = audio_count.saturating_sub(file_paths.len());

        if !file_paths.is_empty() {
            let _ = sink.add(IndexActionState {
                progress: if total == 0 {
                    0.0
                } else {
                    scanned as f64 / total as f64
                },
                message: String::from("正在扫描 ") + dir_path,
                phase: IndexPhase::Scanning,
                unreadable_total,
            });

            let scanned_before = scanned + skipped as u64;
            let read_results = read_audio_paths_parallel(&file_paths, |completed| {
                let completed = scanned_before + completed as u64;
                if should_emit_index_progress(completed as usize, total as usize) {
                    let _ = sink.add(IndexActionState {
                        progress: if total == 0 {
                            1.0
                        } else {
                            completed as f64 / total as f64
                        },
                        message: String::new(),
                        phase: IndexPhase::Scanning,
                        unreadable_total,
                    });
                }
            });
            let failed = read_results.iter().filter(|audio| audio.is_none()).count();
            if failed > 0 {
                unreadable_total += failed as u64;
                log::warn!(
                    target: "tag",
                    "skipped {} unreadable files while indexing {}",
                    failed,
                    dir_path
                );
            }
            audios.extend(read_results.into_iter().flatten());
        }
        scanned += audio_count as u64;

        if !audios.is_empty() {
            let modified = folder_change_stamp(Path::new(dir_path.as_str()));
            let latest = audios.iter().map(|audio| audio.created).max().unwrap_or(0);
            audio_folders.push(AudioFolder {
                path: dir_path.clone(),
                modified,
                latest,
                audios,
            });
        }
    }

    let mut audio_folders_json: Vec<serde_json::Value> = vec![];
    for item in &audio_folders {
        audio_folders_json.push(item.to_json_value());
    }
    let json_value = serde_json::json!({
        "version": CURRENT_INDEX_VERSION,
        "folders": audio_folders_json,
    });

    let _ = sink.add(IndexActionState {
        progress: 1.0,
        message: String::from("正在保存索引"),
        phase: IndexPhase::Saving,
        unreadable_total,
    });

    library_db::write_index_snapshot(&index_dir, &json_value).map_err(io::Error::other)?;

    let _ = sink.add(IndexActionState {
        progress: 1.0,
        message: String::from("曲库扫描完成"),
        phase: IndexPhase::Complete,
        unreadable_total,
    });

    Ok(())
}

fn _update_index_below_1_1_0(
    index: &serde_json::Value,
    index_path: &PathBuf,
    sink: &StreamSink<IndexActionState>,
) -> Result<(), io::Error> {
    let mut audio_folders_json: Vec<serde_json::Value> = vec![];
    let folders = index
        .as_array()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "index is not an array"))?;
    for item in folders {
        let path = item["path"]
            .as_str()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing 'path' field"))?;
        reject_network_folder(Path::new(path))?;
        let _ = sink.add(IndexActionState {
            progress: audio_folders_json.len() as f64 / folders.len() as f64,
            message: String::from("正在扫描 ") + path,
            phase: IndexPhase::Scanning,
            unreadable_total: 0,
        });
        let folder_path = Path::new(path);
        match AudioFolder::read_from_folder(folder_path) {
            Ok(audio_folder) => audio_folders_json.push(audio_folder.to_json_value()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        }
        let _ = sink.add(IndexActionState {
            progress: audio_folders_json.len() as f64 / folders.len() as f64,
            message: String::new(),
            phase: IndexPhase::Scanning,
            unreadable_total: 0,
        });
    }
    let index_dir = index_path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "index path has no parent"))?;
    let migrated = serde_json::json!({
        "version": CURRENT_INDEX_VERSION,
        "folders": audio_folders_json,
    });
    library_db::write_index_snapshot(index_dir, &migrated).map_err(io::Error::other)?;

    Ok(())
}

fn discover_new_audio_folders(
    root: &Path,
    existing_paths: &HashSet<String>,
    new_entries: &mut Vec<serde_json::Value>,
    scanned: &mut HashSet<String>,
) -> io::Result<()> {
    let dir_str = root.to_string_lossy().to_string();
    if !scanned.insert(dir_str.clone()) {
        return Ok(());
    }

    if !existing_paths.contains(&dir_str) {
        match AudioFolder::read_from_folder(root) {
            Ok(audio_folder) => {
                new_entries.push(audio_folder.to_json_value());
                return Ok(());
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }

    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    for entry in entries {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            discover_new_audio_folders(&entry.path(), existing_paths, new_entries, scanned)?;
        }
    }
    Ok(())
}

fn add_missing_audio_files(
    folder_path: &str,
    audios: &mut Vec<serde_json::Value>,
    latest: u64,
) -> io::Result<(u64, bool, u64)> {
    let existing_audio_paths: HashSet<String> = audios
        .iter()
        .filter_map(|item| item["path"].as_str().map(|path| path.to_string()))
        .collect();
    let mut new_latest = latest;
    let dir = match fs::read_dir(folder_path) {
        Ok(value) => value,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok((new_latest, false, 0));
        }
        Err(error) => return Err(error),
    };
    let mut paths = Vec::new();
    for entry in dir {
        let entry = entry?;
        if entry.file_type()?.is_file()
            && is_supported_audio_path(&entry.path())
            && !existing_audio_paths.contains(&entry.path().to_string_lossy().to_string())
        {
            paths.push(entry.path());
        }
    }
    let read_results = read_audio_paths_parallel(&paths, |_| {});
    let mut added = false;
    let mut unreadable = 0_u64;
    for new_audio in read_results.into_iter() {
        let Some(new_audio) = new_audio else {
            unreadable += 1;
            continue;
        };
        if new_audio.created > new_latest {
            new_latest = new_audio.created;
        }
        audios.push(new_audio.to_json_value());
        added = true;
    }
    Ok((new_latest, added, unreadable))
}

/// for Flutter   
/// 读取 index_path/index.json，检查更新。不可能重新读取被修改的文件夹下所有的音乐标签，这样太耗时。  
///
/// [LOWEST_VERSION] 指定可以继承的 index 的最低版本。
/// 如果 index version < [LOWEST_VERSION] 或者是 index 根本没有 version 再或者格式不符合要求，就转到
/// [_update_index_below_1_1_0] 更新 index；
/// 如果 index version >= [LOWEST_VERSION] 则进行更新。
///
/// 文件夹或文件暂时不见了只标无效，不删库。显式刷新时用修改时间和文件大小判断，只重读真正变过的标签。
/// 1. 文件不存在则 valid=false，保留播放次数
/// 2. 修改时间或大小变化才重读标签；缺 size/media_id 只补身份不读标签
/// 3. 补上索引里没有的新文件；同 media_id 的无效记录在改名后丢掉，播放次数在入库时接回
fn should_scan_indexed_audio_files(
    old_folder_modified: u64,
    new_folder_modified: u64,
    explicit_refresh: bool,
) -> bool {
    explicit_refresh || new_folder_modified != old_folder_modified
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum IndexedAudioUpdate {
    Skip,
    BackfillIdentity,
    RereadTags,
}

fn audio_json_is_valid(audio_item: &serde_json::Value) -> bool {
    audio_item
        .get("valid")
        .and_then(|value| value.as_bool())
        .unwrap_or(true)
}

fn set_audio_json_valid(audio_item: &mut serde_json::Value, valid: bool) {
    if let Some(object) = audio_item.as_object_mut() {
        object.insert("valid".to_string(), serde_json::json!(valid));
    }
}

fn backfill_audio_identity(
    audio_item: &mut serde_json::Value,
    metadata: &fs::Metadata,
    path: &Path,
) {
    if let Some(object) = audio_item.as_object_mut() {
        object.insert("size".to_string(), serde_json::json!(metadata.len()));
        let media_id_missing = !object
            .get("media_id")
            .and_then(|value| value.as_str())
            .is_some_and(|value| !value.is_empty());
        if media_id_missing {
            if let Some(media_id) = library_db::stable_file_id_for_path(path) {
                object.insert("media_id".to_string(), serde_json::json!(media_id));
            }
        }
    }
}

fn indexed_audio_update_from_parts(
    audio_item: &serde_json::Value,
    new_modified: u64,
    new_size: u64,
) -> IndexedAudioUpdate {
    if !audio_item
        .as_object()
        .is_some_and(|item| item.contains_key("disc"))
    {
        return IndexedAudioUpdate::RereadTags;
    }
    let old_modified = audio_item["modified"].as_u64().unwrap_or(0);
    let size_known = audio_item
        .as_object()
        .is_some_and(|item| item.contains_key("size"));
    let old_size = audio_item.get("size").and_then(|value| value.as_u64());
    if old_modified != new_modified || (size_known && old_size != Some(new_size)) {
        return IndexedAudioUpdate::RereadTags;
    }
    let media_id_missing = !audio_item
        .get("media_id")
        .and_then(|value| value.as_str())
        .is_some_and(|value| !value.is_empty());
    if !size_known || media_id_missing {
        IndexedAudioUpdate::BackfillIdentity
    } else {
        IndexedAudioUpdate::Skip
    }
}

fn indexed_audio_update(
    audio_item: &serde_json::Value,
    metadata: &fs::Metadata,
) -> IndexedAudioUpdate {
    let Ok(modified) = metadata.modified() else {
        return IndexedAudioUpdate::Skip;
    };
    let new_modified = modified
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_secs();
    indexed_audio_update_from_parts(audio_item, new_modified, metadata.len())
}

fn drop_invalid_duplicates_by_media_id(folders: &mut [serde_json::Value]) -> usize {
    let mut valid_ids = HashSet::new();
    for folder in folders.iter() {
        let Some(audios) = folder.get("audios").and_then(|value| value.as_array()) else {
            continue;
        };
        for audio in audios {
            if !audio_json_is_valid(audio) {
                continue;
            }
            if let Some(media_id) = audio.get("media_id").and_then(|value| value.as_str()) {
                if !media_id.is_empty() {
                    valid_ids.insert(media_id.to_string());
                }
            }
        }
    }
    if valid_ids.is_empty() {
        return 0;
    }
    let mut dropped = 0_usize;
    for folder in folders.iter_mut() {
        let Some(audios) = folder
            .get_mut("audios")
            .and_then(|value| value.as_array_mut())
        else {
            continue;
        };
        let before = audios.len();
        audios.retain(|audio| {
            if audio_json_is_valid(audio) {
                return true;
            }
            let Some(media_id) = audio.get("media_id").and_then(|value| value.as_str()) else {
                return true;
            };
            media_id.is_empty() || !valid_ids.contains(media_id)
        });
        dropped += before - audios.len();
    }
    dropped
}

fn probe_indexed_path<T>(result: io::Result<T>) -> io::Result<Option<T>> {
    match result {
        Ok(value) => Ok(Some(value)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

/// 目录内是否直接包含 CUE 或 ISO 虚拟容器；读取失败按不包含处理。
fn folder_contains_virtual_container(path: &Path) -> bool {
    let Ok(entries) = fs::read_dir(path) else {
        return false;
    };
    entries.filter_map(Result::ok).any(|entry| {
        entry
            .file_type()
            .is_ok_and(|file_type| file_type.is_file())
            && {
                let entry_path = entry.path();
                is_cue_path(&entry_path) || is_iso_path(&entry_path)
            }
    })
}

/// 条目中是否存在虚拟轨；其 path 为可解析的合成路径（CUE 或 SACD）。
fn has_virtual_tracks(audios: &[serde_json::Value]) -> bool {
    audios.iter().any(|audio| {
        audio
            .get("path")
            .and_then(|value| value.as_str())
            .is_some_and(|path| parse_segment_path(path).is_some())
    })
}

/// 同目录 CUE 的 FILE 源文件路径键集合；只解析 cue 文本，不读音频标签。
fn cue_referenced_source_keys(folder_path: &Path) -> HashSet<String> {
    let Ok(entries) = fs::read_dir(folder_path) else {
        return HashSet::new();
    };
    let mut keys = HashSet::new();
    for entry in entries.flatten() {
        if !entry.file_type().is_ok_and(|kind| kind.is_file()) {
            continue;
        }
        let cue_path = entry.path();
        if !is_cue_path(&cue_path) {
            continue;
        }
        let Ok(sheet) = parse_cue_file(&cue_path) else {
            continue;
        };
        for file in sheet.files {
            keys.insert(path_key(&folder_path.join(file.name.as_str())));
        }
    }
    keys
}

/// 索引里是否还留着被同目录 CUE 引用的整轨条目（旧版本写入的源文件记录）。
///
/// 只有已经生成过虚拟轨的目录才继续做磁盘检查：目录戳未变时不新增 CUE，
/// 普通目录因此在内存里直接返回，不额外访问磁盘。
fn folder_has_cue_source_residue(folder_path: &Path, audios: &[serde_json::Value]) -> bool {
    if !has_virtual_tracks(audios) {
        return false;
    }
    let mut plain_paths: HashSet<String> = HashSet::new();
    for audio in audios {
        let Some(path) = audio.get("path").and_then(|value| value.as_str()) else {
            continue;
        };
        if parse_segment_path(path).is_none() {
            plain_paths.insert(path_key(Path::new(path)));
        }
    }
    if plain_paths.is_empty() {
        return false;
    }
    cue_referenced_source_keys(folder_path)
        .iter()
        .any(|key| plain_paths.contains(key))
}

/// 增量更新对单个已索引目录的处理方式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum IndexedFolderScan {
    /// 目录与容器状态都没变，沿用索引条目。
    Skip,
    /// 逐条比较音频的修改时间与大小。
    Incremental,
    /// 目录含 CUE/ISO 或索引残留整轨条目，整体重建目录条目。
    RebuildVirtual,
}

/// 判断已索引目录在增量更新中的处理方式。
///
/// 目录变更戳未变时普通目录直接跳过；含 CUE/ISO 的目录只在索引里仍然留着被
/// CUE 引用的整轨条目时才重建，重建后条目全是虚拟轨，下一次即回到跳过，
/// 因此不会每次启动都重扫全部 CUE 目录。
fn indexed_folder_scan(
    folder_path: &Path,
    audios: &[serde_json::Value],
    old_folder_modified: u64,
    new_folder_modified: u64,
    explicit_refresh: bool,
) -> IndexedFolderScan {
    if should_scan_indexed_audio_files(
        old_folder_modified,
        new_folder_modified,
        explicit_refresh,
    ) {
        return if folder_contains_virtual_container(folder_path) || has_virtual_tracks(audios) {
            IndexedFolderScan::RebuildVirtual
        } else {
            IndexedFolderScan::Incremental
        };
    }
    if folder_has_cue_source_residue(folder_path, audios) {
        IndexedFolderScan::RebuildVirtual
    } else {
        IndexedFolderScan::Skip
    }
}

#[cfg(test)]
mod tag_reader_tests {
    use std::{
        iter,
        path::{Path, PathBuf},
        time::{SystemTime, UNIX_EPOCH},
    };

    use id3::TagLike;
    use lofty::file::FileType;
    use lofty::prelude::ItemKey;

    use super::cue::is_cue_path;
    use super::{
        detect_and_encode, drop_invalid_duplicates_by_media_id, dsd_native_bitrate,
        folder_contains_virtual_container, folder_has_cue_source_residue, has_virtual_tracks,
        indexed_audio_update_from_parts, indexed_folder_scan, is_iso_path, is_lyric_item_key,
        join_deduped, parse_midi_metadata, path_key, probe_indexed_path, read_audio_extra_metadata,
        read_by_asf, read_cue_folder, read_sacd_folder, should_emit_index_progress,
        should_scan_indexed_audio_files, should_show_recording_date, tag_reader_worker_count_for,
        Audio, AudioFolder, IndexedAudioUpdate, IndexedFolderScan, SUPPORTED_FORMATS,
    };

    fn asf_object(guid: [u8; 16], data: Vec<u8>) -> Vec<u8> {
        let mut object = guid.to_vec();
        object.extend_from_slice(&((24 + data.len()) as u64).to_le_bytes());
        object.extend(data);
        object
    }

    fn utf16le_null_terminated(value: &str) -> Vec<u8> {
        value
            .encode_utf16()
            .chain(iter::once(0))
            .flat_map(u16::to_le_bytes)
            .collect()
    }

    fn asf_content_description(title: &str, artist: &str) -> Vec<u8> {
        let values = [
            utf16le_null_terminated(title),
            utf16le_null_terminated(artist),
            utf16le_null_terminated(""),
            utf16le_null_terminated(""),
            utf16le_null_terminated(""),
        ];
        let mut data = Vec::with_capacity(10 + values.iter().map(Vec::len).sum::<usize>());
        for value in &values {
            data.extend_from_slice(&(value.len() as u16).to_le_bytes());
        }
        for value in values {
            data.extend(value);
        }
        data
    }

    fn minimal_asf(title: &str, artist: &str) -> Vec<u8> {
        const FILE_HEADER_GUID: [u8; 16] = [
            0x30, 0x26, 0xb2, 0x75, 0x8e, 0x66, 0xcf, 0x11, 0xa6, 0xd9, 0x00, 0xaa, 0x00, 0x62,
            0xce, 0x6c,
        ];
        const CONTENT_DESCRIPTION_GUID: [u8; 16] = [
            0x33, 0x26, 0xb2, 0x75, 0x8e, 0x66, 0xcf, 0x11, 0xa6, 0xd9, 0x00, 0xaa, 0x00, 0x62,
            0xce, 0x6c,
        ];

        let content = asf_object(
            CONTENT_DESCRIPTION_GUID,
            asf_content_description(title, artist),
        );
        let mut file_header_data = Vec::new();
        file_header_data.extend_from_slice(&1_u32.to_le_bytes());
        file_header_data.extend_from_slice(&0_u16.to_le_bytes());
        file_header_data.extend(content);
        asf_object(FILE_HEADER_GUID, file_header_data)
    }

    fn temp_asf_path(suffix: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "pure_music_asf_{}_{}.{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            suffix
        ))
    }

    #[test]
    fn reads_asf_metadata_through_existing_audio_reader() {
        let path = temp_asf_path("wma");
        std::fs::write(&path, minimal_asf("Feature title", "Artist A / Artist B")).unwrap();

        let audio = read_by_asf(&path, 11, 22).expect("valid ASF metadata");

        assert_eq!(audio.title, "Feature title");
        assert_eq!(audio.artist, "Artist A / Artist B");
        assert_eq!(audio.album, "UNKNOWN");
        assert_eq!(audio.track, None);
        assert_eq!(audio.duration, 0);
        assert_eq!(audio.modified, 11);
        assert_eq!(audio.created, 22);
        assert_eq!(audio.by.as_deref(), Some("ratag"));

        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn reads_positive_asf_extra_metadata_fields() {
        let path = temp_asf_path("wma");
        std::fs::write(&path, minimal_asf("Feature title", "Artist A / Artist B")).unwrap();

        let metadata = read_audio_extra_metadata(path.to_string_lossy().to_string());
        let fields = metadata
            .items
            .into_iter()
            .map(|item| (item.key, item.value))
            .collect::<std::collections::HashMap<_, _>>();

        assert_eq!(metadata.extension, "wma");
        assert_eq!(
            fields.get("artist").map(String::as_str),
            Some("Artist A / Artist B")
        );
        assert_eq!(metadata.file_size > 0, true);

        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn missing_asf_text_fields_use_safe_defaults() {
        let path = temp_asf_path("asf");
        std::fs::write(&path, minimal_asf("", "")).unwrap();

        let audio = read_by_asf(&path, 33, 44).expect("valid ASF metadata");

        assert_eq!(audio.title, path.file_name().unwrap().to_string_lossy());
        assert_eq!(audio.artist, "UNKNOWN");
        assert_eq!(audio.album, "UNKNOWN");
        assert_eq!(audio.duration, 0);
        assert_eq!(audio.modified, 33);
        assert_eq!(audio.created, 44);

        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn invalid_asf_input_returns_none_from_audio_reader() {
        let path = temp_asf_path("asf");
        std::fs::write(&path, b"not an ASF file").unwrap();

        assert!(read_by_asf(&path, 0, 0).is_none());

        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn asf_artist_joining_deduplicates_in_source_order() {
        assert_eq!(
            join_deduped(["Artist A", "Artist B", "Artist A", "Artist B"].into_iter()),
            "Artist A/Artist B"
        );
    }

    #[test]
    fn reads_positive_id3_extra_metadata_fields() {
        let path = std::env::temp_dir().join(format!(
            "pure_music_valid_id3_extra_{}_{}.mp3",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut tag = id3::Tag::new();
        tag.set_genre("Rock");
        tag.set_year(2024);
        tag.set_text("TCOM", "Composer");
        tag.set_text("TBPM", "128");
        tag.set_track(4);
        tag.set_disc(2);
        std::fs::write(&path, []).unwrap();
        tag.write_to_path(&path, id3::Version::Id3v24).unwrap();

        let indexed = Audio::read_from_path(&path).expect("indexed ID3 tag");
        assert_eq!(indexed.genre.as_deref(), Some("Rock"));
        assert_eq!(indexed.year.as_deref(), Some("2024"));
        assert_eq!(indexed.composer.as_deref(), Some("Composer"));
        assert_eq!(indexed.bpm.as_deref(), Some("128"));

        let metadata = read_audio_extra_metadata(path.to_string_lossy().to_string());
        let fields = metadata
            .items
            .into_iter()
            .map(|item| (item.key, item.value))
            .collect::<std::collections::HashMap<_, _>>();

        assert_eq!(metadata.extension, "mp3");
        assert_eq!(fields.get("genre").map(String::as_str), Some("Rock"));
        assert_eq!(fields.get("year").map(String::as_str), Some("2024"));
        assert_eq!(fields.get("disc").map(String::as_str), Some("2"));

        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn index_snapshot_serializes_catalog_tags() {
        let audio = Audio {
            title: "Track".to_string(),
            artist: "Artist".to_string(),
            album: "Album".to_string(),
            album_artist: None,
            genre: Some("Rock".to_string()),
            year: Some("2024".to_string()),
            composer: Some("Composer".to_string()),
            bpm: Some("128".to_string()),
            track: Some(1),
            disc: None,
            duration: 180,
            bitrate: Some(320),
            sample_rate: Some(44_100),
            bit_depth: Some(24),
            path: "C:/Music/track.flac".to_string(),
            modified: 1,
            created: 2,
            by: Some("Lofty".to_string()),
            size: 3,
            valid: true,
            media_id: None,
        };

        let snapshot = audio.to_json_value();
        assert_eq!(snapshot["genre"], "Rock");
        assert_eq!(snapshot["year"], "2024");
        assert_eq!(snapshot["composer"], "Composer");
        assert_eq!(snapshot["bpm"], "128");
        assert_eq!(snapshot["bit_depth"], 24);
    }

    #[test]
    fn gif_cover_falls_back_to_jpeg() {
        let img = image::DynamicImage::new_rgb8(2, 2);
        let (bytes, mime) = detect_and_encode(&img, b"GIF89a").expect("jpeg fallback");
        assert_eq!(mime, lofty::picture::MimeType::Jpeg);
        assert!(!bytes.is_empty());
    }

    #[test]
    fn reserves_two_logical_cores_for_playback_and_ui() {
        assert_eq!(tag_reader_worker_count_for(16, 100), 4);
        assert_eq!(tag_reader_worker_count_for(8, 100), 3);
        assert_eq!(tag_reader_worker_count_for(6, 100), 2);
        assert_eq!(tag_reader_worker_count_for(4, 100), 1);
        assert_eq!(tag_reader_worker_count_for(2, 100), 1);
        assert_eq!(tag_reader_worker_count_for(16, 1), 1);
    }

    #[test]
    fn scans_audio_files_when_folder_timestamp_is_unchanged() {
        assert!(should_scan_indexed_audio_files(100, 100, true));
    }

    #[test]
    fn scans_folder_when_timestamp_moves_backwards() {
        assert!(should_scan_indexed_audio_files(101, 100, false));
    }

    #[test]
    fn only_not_found_marks_an_indexed_path_missing() {
        assert!(
            probe_indexed_path::<()>(Err(std::io::Error::from(std::io::ErrorKind::NotFound)))
                .unwrap()
                .is_none()
        );
        let error = probe_indexed_path::<()>(Err(std::io::Error::from(
            std::io::ErrorKind::PermissionDenied,
        )))
        .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
    }

    #[test]
    fn caps_progress_updates_for_large_indexes() {
        let update_count = (1..=50_000)
            .filter(|completed| should_emit_index_progress(*completed, 50_000))
            .count();
        assert_eq!(update_count, 200);
        assert!(should_emit_index_progress(16, 100));
        assert!(should_emit_index_progress(100, 100));
    }

    #[test]
    fn hides_duplicate_recording_date_when_used_as_year() {
        assert!(!should_show_recording_date(
            Some("2026-06-11"),
            Some("2026-06-11")
        ));
    }

    #[test]
    fn only_scans_lyric_named_fallback_fields() {
        assert!(!is_lyric_item_key(&ItemKey::TrackArtist));
        assert!(is_lyric_item_key(&ItemKey::Unknown(
            "UNSYNCEDLYRICS".to_string()
        )));
    }

    #[test]
    fn includes_every_lofty_extension_and_excludes_wavpack_correction_files() {
        let lofty_extensions = [
            "aac", "ape", "aiff", "aif", "afc", "aifc", "mp3", "mp2", "mp1", "wav", "wave", "wv",
            "opus", "flac", "ogg", "mp4", "m4a", "m4b", "m4p", "m4r", "m4v", "3gp", "mpc", "mp+",
            "mpp", "spx",
        ];
        for extension in lofty_extensions {
            assert!(FileType::from_ext(extension).is_some(), "{extension}");
            assert!(SUPPORTED_FORMATS.contains(extension), "{extension}");
        }
        for extension in [
            "mpa", "oga", "asf", "wma", "adts", "3g2", "mka", "mkv", "webm", "weba", "caf", "ac3",
            "a52", "amr", "3ga", "mid", "midi", "kar", "rmi", "dsf", "dff",
        ] {
            assert!(SUPPORTED_FORMATS.contains(extension), "{extension}");
        }
        assert!(!SUPPORTED_FORMATS.contains("wvc"));
    }

    #[test]
    fn reads_sequential_midi_title_and_accumulates_fractional_tracks() {
        let bytes = [
            0x4d, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06, 0x00, 0x02, 0x00, 0x02, 0x01, 0xe0,
            0x4d, 0x54, 0x72, 0x6b, 0x00, 0x00, 0x00, 0x0c, 0x00, 0xff, 0x03, 0x03, 0x4f, 0x6e,
            0x65, 0x83, 0x60, 0xff, 0x2f, 0x00, 0x4d, 0x54, 0x72, 0x6b, 0x00, 0x00, 0x00, 0x0c,
            0x00, 0xff, 0x03, 0x03, 0x54, 0x77, 0x6f, 0x83, 0x60, 0xff, 0x2f, 0x00,
        ];
        let metadata = parse_midi_metadata(&bytes).expect("valid MIDI metadata");
        assert_eq!(metadata.title.as_deref(), Some("One"));
        assert_eq!(metadata.duration, 1);
        assert_eq!(
            metadata
                .items
                .iter()
                .filter(|(key, _)| key == "track_name")
                .count(),
            2
        );

        let mut rmi = b"RIFF".to_vec();
        let riff_size = 4 + 8 + bytes.len() + (bytes.len() & 1);
        rmi.extend_from_slice(&(riff_size as u32).to_le_bytes());
        rmi.extend_from_slice(b"RMIDdata");
        rmi.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
        rmi.extend_from_slice(&bytes);
        if bytes.len() & 1 == 1 {
            rmi.push(0);
        }
        let rmi_metadata = parse_midi_metadata(&rmi).expect("valid RIFF MIDI metadata");
        assert_eq!(rmi_metadata.title.as_deref(), Some("One"));
        assert_eq!(rmi_metadata.duration, 1);
    }

    fn sample_audio_json(
        modified: u64,
        size: Option<u64>,
        media_id: Option<&str>,
    ) -> serde_json::Value {
        let mut value = serde_json::json!({
            "title": "t",
            "artist": "a",
            "album": "al",
            "disc": 1,
            "modified": modified,
            "path": "C:/Music/t.mp3",
            "valid": true
        });
        if let Some(size) = size {
            value["size"] = serde_json::json!(size);
        }
        if let Some(media_id) = media_id {
            value["media_id"] = serde_json::json!(media_id);
        }
        value
    }

    #[test]
    fn unchanged_mtime_and_size_skip_tag_reread() {
        let audio = sample_audio_json(100, Some(2048), Some("win:1:2"));
        assert_eq!(
            indexed_audio_update_from_parts(&audio, 100, 2048),
            IndexedAudioUpdate::Skip
        );
    }

    #[test]
    fn same_second_size_change_rereads_tags() {
        let audio = sample_audio_json(100, Some(2048), Some("win:1:2"));
        assert_eq!(
            indexed_audio_update_from_parts(&audio, 100, 4096),
            IndexedAudioUpdate::RereadTags
        );
    }

    #[test]
    fn missing_size_backfills_without_reread() {
        let audio = sample_audio_json(100, None, Some("win:1:2"));
        assert_eq!(
            indexed_audio_update_from_parts(&audio, 100, 2048),
            IndexedAudioUpdate::BackfillIdentity
        );
    }

    #[test]
    fn skip_rate_for_unchanged_library_is_100_percent() {
        let mut skipped = 0_u32;
        let mut reread = 0_u32;
        for index in 0..10_000 {
            let audio = sample_audio_json(100, Some(2048), Some("win:1:2"));
            match indexed_audio_update_from_parts(&audio, 100, 2048) {
                IndexedAudioUpdate::Skip => skipped += 1,
                IndexedAudioUpdate::RereadTags => reread += 1,
                IndexedAudioUpdate::BackfillIdentity => {}
            }
            let _ = index;
        }
        assert_eq!(skipped, 10_000);
        assert_eq!(reread, 0);
    }

    #[test]
    fn renamed_file_drops_invalid_duplicate_by_media_id() {
        let mut folders = vec![serde_json::json!({
            "path": "C:/Music",
            "audios": [
                {
                    "path": "C:/Music/old.mp3",
                    "media_id": "win:1:2",
                    "valid": false
                },
                {
                    "path": "C:/Music/new.mp3",
                    "media_id": "win:1:2",
                    "valid": true
                }
            ]
        })];
        assert_eq!(drop_invalid_duplicates_by_media_id(&mut folders), 1);
        assert_eq!(folders[0]["audios"].as_array().unwrap().len(), 1);
        assert_eq!(folders[0]["audios"][0]["path"], "C:/Music/new.mp3");
    }

    struct TempCueDir(PathBuf);

    impl Drop for TempCueDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn temp_cue_dir() -> TempCueDir {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|value| value.as_nanos())
            .unwrap_or(0);
        TempCueDir(std::env::temp_dir().join(format!(
            "pure_music_cue_scan_{}_{}",
            std::process::id(),
            nanos
        )))
    }

    fn write_test_file(path: &Path, bytes: &[u8]) {
        if let Err(error) = std::fs::write(path, bytes) {
            panic!("write {} failed: {error}", path.display());
        }
    }

    /// 44 字节 RIFF/WAVE 头，data 块为空。
    fn minimal_wav_bytes() -> Vec<u8> {
        let mut bytes = Vec::with_capacity(44);
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&36_u32.to_le_bytes());
        bytes.extend_from_slice(b"WAVE");
        bytes.extend_from_slice(b"fmt ");
        bytes.extend_from_slice(&16_u32.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&44_100_u32.to_le_bytes());
        bytes.extend_from_slice(&88_200_u32.to_le_bytes());
        bytes.extend_from_slice(&2_u16.to_le_bytes());
        bytes.extend_from_slice(&16_u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&0_u32.to_le_bytes());
        bytes
    }

    /// 24bit/44.1kHz 立体声 WAV，data 为 1 秒静音。
    fn wav_24bit_bytes() -> Vec<u8> {
        const SAMPLE_RATE: u32 = 44_100;
        const BLOCK_ALIGN: u16 = 6;
        let data_len = SAMPLE_RATE * u32::from(BLOCK_ALIGN);
        let mut bytes = Vec::with_capacity(44 + data_len as usize);
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
        bytes.extend_from_slice(b"WAVE");
        bytes.extend_from_slice(b"fmt ");
        bytes.extend_from_slice(&16_u32.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&2_u16.to_le_bytes());
        bytes.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
        bytes.extend_from_slice(&(SAMPLE_RATE * u32::from(BLOCK_ALIGN)).to_le_bytes());
        bytes.extend_from_slice(&BLOCK_ALIGN.to_le_bytes());
        bytes.extend_from_slice(&24_u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&data_len.to_le_bytes());
        bytes.resize(44 + data_len as usize, 0);
        bytes
    }

    const SACD_TEST_SECTOR_SIZE: usize = 2048;
    const SACD_TEST_IMAGE_SECTORS: usize = 640;
    const SACD_TEST_MASTER_TOC_LSN: usize = 510;
    const SACD_TEST_AREA_TOC_LSN: usize = 544;
    const SACD_TEST_AREA_TOC_SECTORS: u16 = 5;

    /// 测试用最小 SACD 镜像构造器，按 2048 字节扇区写入。
    struct SacdImageBuilder {
        data: Vec<u8>,
    }

    impl SacdImageBuilder {
        fn new() -> Self {
            Self {
                data: vec![0u8; SACD_TEST_IMAGE_SECTORS * SACD_TEST_SECTOR_SIZE],
            }
        }

        fn sector_mut(&mut self, lsn: usize) -> &mut [u8] {
            let start = lsn * SACD_TEST_SECTOR_SIZE;
            let end = start + SACD_TEST_SECTOR_SIZE;
            match self.data.get_mut(start..end) {
                Some(sector) => sector,
                None => panic!("测试镜像扇区越界"),
            }
        }

        fn into_data(self) -> Vec<u8> {
            self.data
        }
    }

    fn put_be_u16(sector: &mut [u8], offset: usize, value: u16) {
        if let Some(target) = sector.get_mut(offset..offset + 2) {
            target.copy_from_slice(&value.to_be_bytes());
        }
    }

    fn put_be_u32(sector: &mut [u8], offset: usize, value: u32) {
        if let Some(target) = sector.get_mut(offset..offset + 4) {
            target.copy_from_slice(&value.to_be_bytes());
        }
    }

    fn put_timecode(sector: &mut [u8], offset: usize, minutes: u8, seconds: u8, frames: u8) {
        if let Some(target) = sector.get_mut(offset..offset + 4) {
            target[0] = minutes;
            target[1] = seconds;
            target[2] = frames;
            target[3] = 0;
        }
    }

    /// 构造 1 个 2CH 区、2 条轨道的裸 DSD 最小镜像。
    fn minimal_sacd_iso_bytes() -> Vec<u8> {
        let mut image = SacdImageBuilder::new();
        {
            let sector = image.sector_mut(SACD_TEST_MASTER_TOC_LSN);
            sector[0..8].copy_from_slice(b"SACDMTOC");
            sector[8] = 1;
            sector[9] = 0x14;
            put_be_u16(sector, 16, 1);
            put_be_u16(sector, 18, 1);
            put_be_u32(sector, 64, SACD_TEST_AREA_TOC_LSN as u32);
            sector[80] = 0x80;
            put_be_u16(sector, 84, SACD_TEST_AREA_TOC_SECTORS);
        }
        {
            let sector = image.sector_mut(SACD_TEST_AREA_TOC_LSN);
            sector[0..8].copy_from_slice(b"TWOCHTOC");
            sector[8] = 1;
            sector[9] = 0x14;
            put_be_u16(sector, 10, SACD_TEST_AREA_TOC_SECTORS);
            sector[21] = 2;
            sector[32] = 2;
            sector[64] = 5;
            sector[65] = 45;
            sector[66] = 50;
            sector[69] = 2;
            put_be_u32(sector, 72, 1000);
            put_be_u32(sector, 76, 4500);
        }
        {
            let sector = image.sector_mut(SACD_TEST_AREA_TOC_LSN + 1);
            sector[0..8].copy_from_slice(b"SACDTRL1");
            put_be_u32(sector, 8, 1000);
            put_be_u32(sector, 12, 3000);
            put_be_u32(sector, 8 + 255 * 4, 2000);
            put_be_u32(sector, 12 + 255 * 4, 1500);
        }
        {
            let sector = image.sector_mut(SACD_TEST_AREA_TOC_LSN + 2);
            sector[0..8].copy_from_slice(b"SACDTRL2");
            put_timecode(sector, 8, 0, 0, 0);
            put_timecode(sector, 12, 3, 0, 0);
            put_timecode(sector, 8 + 255 * 4, 1, 30, 25);
            put_timecode(sector, 12 + 255 * 4, 2, 15, 0);
        }
        image.into_data()
    }

    #[test]
    fn normalizes_path_keys_used_for_reference_dedup() {
        assert_eq!(path_key(Path::new("D:\\Music\\Album\\")), "d:/music/album");
        assert_eq!(path_key(Path::new("D:/Music/Album")), "d:/music/album");
        assert_eq!(path_key(Path::new("Music\\Album")), "music/album");
        assert_eq!(path_key(Path::new("/music/album///")), "/music/album");
    }

    #[test]
    fn detects_cue_files_case_insensitively() {
        assert!(is_cue_path(Path::new("album.cue")));
        assert!(is_cue_path(Path::new("ALBUM.CUE")));
        assert!(is_cue_path(Path::new("D:\\Music\\Album.CuE")));
        assert!(!is_cue_path(Path::new("cue")));
        assert!(!is_cue_path(Path::new("album.flac")));
        assert!(!is_cue_path(Path::new("album.cue.bak")));
    }

    #[test]
    fn expands_cue_folder_into_virtual_tracks() {
        let temp = temp_cue_dir();
        if let Err(error) = std::fs::create_dir_all(&temp.0) {
            panic!("create temp dir failed: {error}");
        }
        let wav_path = temp.0.join("disc.wav");
        let cue_path = temp.0.join("album.cue");
        write_test_file(&wav_path, &minimal_wav_bytes());
        write_test_file(
            &cue_path,
            b"PERFORMER \"Album Artist\"\nTITLE \"Test Album\"\nFILE \"disc.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"First\"\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    TITLE \"Second\"\n    INDEX 01 00:01:00\n",
        );

        let source = Audio::read_from_path(&wav_path).expect("cue source metadata");
        let (audios, referenced) = read_cue_folder(std::slice::from_ref(&cue_path), &[]);

        assert_eq!(audios.len(), 2);
        assert_eq!(referenced.len(), 1);
        assert!(referenced.contains(&path_key(&wav_path)));

        let first = match audios.first() {
            Some(audio) => audio,
            None => panic!("first virtual track missing"),
        };
        assert_eq!(first.title, "First");
        assert_eq!(first.artist, "Album Artist");
        assert_eq!(first.album, "Test Album");
        assert_eq!(first.album_artist.as_deref(), Some("Album Artist"));
        assert_eq!(first.track, Some(1));
        assert_eq!(first.duration, 1);
        assert_eq!(first.size, 44);
        assert_eq!(first.bit_depth, source.bit_depth);
        assert_eq!(first.by.as_deref(), Some("cue"));
        assert!(first.valid);
        assert!(first.media_id.is_none());
        assert!(first.path.contains("::track=01"));
        assert!(first.path.contains("::start=0"));
        assert!(first.path.contains("::end=1000"));

        let second = match audios.get(1) {
            Some(audio) => audio,
            None => panic!("second virtual track missing"),
        };
        assert_eq!(second.title, "Second");
        assert_eq!(second.track, Some(2));
        assert!(second.path.contains("::track=02"));
        assert!(second.path.contains("::start=1000"));
        assert!(second.path.contains("::end="));
    }

    #[test]
    fn cue_virtual_tracks_inherit_24_bit_source_depth() {
        let temp = temp_cue_dir();
        if let Err(error) = std::fs::create_dir_all(&temp.0) {
            panic!("create temp dir failed: {error}");
        }
        let wav_path = temp.0.join("disc.wav");
        let cue_path = temp.0.join("album.cue");
        write_test_file(&wav_path, &wav_24bit_bytes());
        write_test_file(
            &cue_path,
            b"FILE \"disc.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"First\"\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    TITLE \"Second\"\n    INDEX 01 00:00:01\n",
        );

        let source = Audio::read_from_path(&wav_path).expect("24-bit cue source metadata");
        assert_eq!(source.bit_depth, Some(24));

        let (audios, referenced) = read_cue_folder(std::slice::from_ref(&cue_path), &[]);
        assert_eq!(audios.len(), 2);
        assert_eq!(referenced.len(), 1);
        for audio in &audios {
            assert_eq!(audio.bit_depth, Some(24));
        }
    }

    #[test]
    fn dsd_native_bitrate_rejects_zero_inputs() {
        assert_eq!(dsd_native_bitrate(Some(2_822_400), Some(2)), Some(5_644));
        assert_eq!(dsd_native_bitrate(Some(0), Some(2)), None);
        assert_eq!(dsd_native_bitrate(Some(2_822_400), Some(0)), None);
        assert_eq!(dsd_native_bitrate(None, Some(2)), None);
        assert_eq!(dsd_native_bitrate(Some(500), Some(1)), None);
        assert_eq!(dsd_native_bitrate(Some(u32::MAX), Some(u8::MAX)), None);
    }

    #[test]
    fn detects_virtual_tracks_from_synthetic_paths() {
        assert!(!has_virtual_tracks(&[serde_json::json!({
            "path": "C:/Music/t.mp3"
        })]));
        assert!(has_virtual_tracks(&[serde_json::json!({
            "path": "D:\\Music\\album.flac::track=01::start=0::end=200000"
        })]));
        assert!(has_virtual_tracks(&[serde_json::json!({
            "path": "D:\\Music\\album.iso::track=01::start=0::end=90000::sacd=2ch"
        })]));
        assert!(!has_virtual_tracks(&[
            serde_json::json!({ "path": "D:\\Music\\album.flac::track=01::start=0" }),
            serde_json::json!({ "path": 42 }),
            serde_json::json!({ "title": "missing path" }),
        ]));
        assert!(!has_virtual_tracks(&[]));
    }

    #[test]
    fn detects_virtual_containers_only_in_the_scanned_folder() {
        let temp = temp_cue_dir();
        assert!(!folder_contains_virtual_container(&temp.0));
        if let Err(error) = std::fs::create_dir_all(&temp.0) {
            panic!("create temp dir failed: {error}");
        }
        write_test_file(&temp.0.join("disc.flac"), b"audio");
        assert!(!folder_contains_virtual_container(&temp.0));

        // 子目录里的容器不属于当前目录的扫描范围。
        let sub_dir = temp.0.join("sub");
        if let Err(error) = std::fs::create_dir_all(&sub_dir) {
            panic!("create temp sub dir failed: {error}");
        }
        write_test_file(&sub_dir.join("album.cue"), b"");
        assert!(!folder_contains_virtual_container(&temp.0));

        write_test_file(&temp.0.join("album.CUE"), b"");
        assert!(folder_contains_virtual_container(&temp.0));

        let iso_dir = temp_cue_dir();
        if let Err(error) = std::fs::create_dir_all(&iso_dir.0) {
            panic!("create temp iso dir failed: {error}");
        }
        write_test_file(&iso_dir.0.join("disc.iso"), b"");
        assert!(folder_contains_virtual_container(&iso_dir.0));
    }

    #[test]
    fn detects_iso_files_case_insensitively() {
        assert!(is_iso_path(Path::new("disc.iso")));
        assert!(is_iso_path(Path::new("DISC.ISO")));
        assert!(is_iso_path(Path::new("D:\\Music\\Album.Iso")));
        assert!(!is_iso_path(Path::new("iso")));
        assert!(!is_iso_path(Path::new("disc.iso.bak")));
        assert!(!is_iso_path(Path::new("disc.flac")));
    }

    #[test]
    fn empty_sacd_folder_yields_no_tracks() {
        assert!(read_sacd_folder(&[]).is_empty());
    }

    #[test]
    fn expands_sacd_iso_into_virtual_tracks() {
        let temp = temp_cue_dir();
        if let Err(error) = std::fs::create_dir_all(&temp.0) {
            panic!("create temp dir failed: {error}");
        }
        let iso_path = temp.0.join("album.iso");
        write_test_file(&iso_path, &minimal_sacd_iso_bytes());

        let audios = read_sacd_folder(std::slice::from_ref(&iso_path));

        assert_eq!(audios.len(), 2);
        let first = match audios.first() {
            Some(audio) => audio,
            None => panic!("first sacd track missing"),
        };
        assert_eq!(first.title, "Track 01");
        assert_eq!(first.artist, "UNKNOWN");
        assert_eq!(first.album, "album");
        assert!(first.album_artist.is_none());
        assert_eq!(first.track, Some(1));
        assert!(first.disc.is_none());
        assert_eq!(first.duration, 90);
        assert_eq!(first.by.as_deref(), Some("sacd"));
        assert!(first.bitrate.is_none());
        assert!(first.sample_rate.is_none());
        assert_eq!(first.bit_depth, Some(1));
        assert!(first.valid);
        assert!(first.media_id.is_none());
        assert!(first.path.contains("::track=01"));
        assert!(first.path.contains("::start=0"));
        assert!(first.path.contains("::end=90333"));
        assert!(first.path.ends_with("::sacd=2ch"));

        let second = match audios.get(1) {
            Some(audio) => audio,
            None => panic!("second sacd track missing"),
        };
        assert_eq!(second.title, "Track 02");
        assert_eq!(second.track, Some(2));
        assert_eq!(second.duration, 135);
        assert!(second.path.contains("::start=180000"));
        assert!(second.path.contains("::end=315000"));
        assert!(second.path.ends_with("::sacd=2ch"));
    }

    #[test]
    fn skips_non_sacd_iso_files() {
        let temp = temp_cue_dir();
        if let Err(error) = std::fs::create_dir_all(&temp.0) {
            panic!("create temp dir failed: {error}");
        }
        let iso_path = temp.0.join("plain.iso");
        write_test_file(&iso_path, &vec![0u8; SACD_TEST_SECTOR_SIZE * 8]);

        assert!(read_sacd_folder(std::slice::from_ref(&iso_path)).is_empty());
    }

    fn cue_folder_with_source() -> (TempCueDir, PathBuf) {
        let temp = temp_cue_dir();
        if let Err(error) = std::fs::create_dir_all(&temp.0) {
            panic!("create temp dir failed: {error}");
        }
        let wav_path = temp.0.join("disc.wav");
        write_test_file(&wav_path, &minimal_wav_bytes());
        write_test_file(
            &temp.0.join("album.cue"),
            b"PERFORMER \"Album Artist\"\nTITLE \"Test Album\"\nFILE \"disc.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"First\"\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    TITLE \"Second\"\n    INDEX 01 00:01:00\n",
        );
        (temp, wav_path)
    }

    #[test]
    fn incremental_scan_rebuilds_cue_folder_with_legacy_full_track_entry() {
        let (temp, wav_path) = cue_folder_with_source();
        let source = wav_path.to_string_lossy().to_string();
        let audios = vec![
            serde_json::json!({"path": source.clone(), "by": "Lofty", "valid": true}),
            serde_json::json!({
                "path": format!("{source}::track=01::start=0::end=1000"),
                "by": "cue",
                "valid": true
            }),
            serde_json::json!({
                "path": format!("{source}::track=02::start=1000::end=2000"),
                "by": "cue",
                "valid": true
            }),
        ];

        assert!(folder_has_cue_source_residue(&temp.0, &audios));
        assert_eq!(
            indexed_folder_scan(&temp.0, &audios, 100, 100, false),
            IndexedFolderScan::RebuildVirtual
        );

        let rebuilt = match AudioFolder::read_from_folder(&temp.0) {
            Ok(folder) => folder,
            Err(error) => panic!("rebuild cue folder failed: {error}"),
        };
        let rebuilt_audios: Vec<serde_json::Value> =
            rebuilt.audios.iter().map(Audio::to_json_value).collect();
        assert_eq!(rebuilt_audios.len(), 2);
        assert!(rebuilt_audios.iter().all(|audio| audio["by"] == "cue"));
        assert_eq!(
            indexed_folder_scan(&temp.0, &rebuilt_audios, 100, 100, false),
            IndexedFolderScan::Skip
        );
        assert_eq!(
            indexed_folder_scan(&temp.0, &rebuilt_audios, 100, 100, true),
            IndexedFolderScan::RebuildVirtual
        );
    }

    #[test]
    fn incremental_scan_keeps_cue_folder_with_unreferenced_tracks() {
        let (temp, _wav_path) = cue_folder_with_source();
        write_test_file(&temp.0.join("extra.wav"), &minimal_wav_bytes());
        let extra = temp.0.join("extra.wav").to_string_lossy().to_string();
        let virtual_track = format!(
            "{}::track=01::start=0::end=1000",
            temp.0.join("disc.wav").to_string_lossy()
        );
        let audios = vec![
            serde_json::json!({"path": virtual_track, "by": "cue", "valid": true}),
            serde_json::json!({"path": extra, "by": "Lofty", "valid": true}),
        ];

        assert!(!folder_has_cue_source_residue(&temp.0, &audios));
        assert_eq!(
            indexed_folder_scan(&temp.0, &audios, 100, 100, false),
            IndexedFolderScan::Skip
        );
    }

    #[test]
    fn incremental_scan_skips_unchanged_folder_without_virtual_tracks() {
        let audios = vec![serde_json::json!({"path": "C:/Music/t.mp3", "by": "Lofty"})];
        assert_eq!(
            indexed_folder_scan(Path::new("C:/Music/not-a-real-dir"), &audios, 7, 7, false),
            IndexedFolderScan::Skip
        );
    }
}

fn index_folder_snapshots_unchanged(folders: &[library_db::IndexFolderSnapshot]) -> bool {
    folders
        .iter()
        .all(|folder| folder_change_stamp(Path::new(folder.path.as_str())) == folder.modified)
}

pub fn update_index(
    index_path: String,
    force_metadata_check: bool,
    sink: StreamSink<IndexActionState>,
) -> anyhow::Result<()> {
    let index_dir = PathBuf::from(&index_path);
    let sqlite_snapshot = library_db::read_current_index_snapshot(&index_dir)?;
    let sqlite_snapshot_current = sqlite_snapshot.is_some();
    if !force_metadata_check {
        if let Some(snapshot) = sqlite_snapshot.as_ref() {
            for folder in &snapshot.folders {
                reject_network_folder(Path::new(&folder.path))?;
            }
            if snapshot.version == CURRENT_INDEX_VERSION
                && snapshot.mixed_virtual_folders.is_empty()
                && index_folder_snapshots_unchanged(&snapshot.folders)
            {
                log::debug!(target: "library", "index update fast path: unchanged");
                let _ = sink.add(IndexActionState {
                    progress: 1.0,
                    message: String::from("音乐库更新完成"),
                    phase: IndexPhase::Complete,
                    unreadable_total: 0,
                });
                return Ok(());
            }
        }
    }
    let mut index_path = PathBuf::from(index_path);
    index_path.push("index.json");
    let index = fs::read(&index_path)?;
    let mut index: serde_json::Value = serde_json::from_slice(&index)?;

    let version = index["version"].as_u64();
    if version.is_none() {
        return Ok(_update_index_below_1_1_0(&index, &index_path, &sink)?);
    }
    let refresh_all_metadata = version.is_some_and(|value| value < CURRENT_INDEX_VERSION);
    let mut index_changed = refresh_all_metadata;
    index["version"] = serde_json::json!(CURRENT_INDEX_VERSION);

    let folders = index["folders"]
        .as_array_mut()
        .ok_or_else(|| anyhow::anyhow!("missing 'folders' field"))?;
    let mut folder_probe_error = None;
    for item in folders.iter() {
        let Some(path) = item["path"].as_str() else {
            folder_probe_error = Some(io::Error::new(
                io::ErrorKind::InvalidData,
                "indexed folder is missing path",
            ));
            break;
        };
        reject_network_folder(Path::new(path))?;
        if let Err(error) = probe_indexed_path(fs::metadata(path)) {
            folder_probe_error = Some(error);
            break;
        }
    }
    if let Some(error) = folder_probe_error {
        return Err(error.into());
    }
    let mut skipped_tag_reads = 0_u64;
    let mut tag_rereads = 0_u64;
    let mut invalidated = 0_u64;
    let mut revived = 0_u64;
    let mut unreadable_total = 0_u64;
    let total = folders
        .iter()
        .filter_map(|folder| folder["audios"].as_array())
        .map(|audios| audios.len() as u64)
        .sum::<u64>();
    let mut checked = 0_u64;
    let mut discovery_roots = Vec::new();

    for folder_item in folders.iter_mut() {
        let folder_path = match folder_item["path"].as_str() {
            Some(p) => p.to_string(),
            None => continue,
        };
        reject_network_folder(Path::new(&folder_path))?;
        let latest = folder_item["latest"].as_u64().unwrap_or(0);
        let old_folder_modified = folder_item["modified"].as_u64().unwrap_or(0);

        let folder_audio_count = folder_item["audios"]
            .as_array()
            .map(|audios| audios.len() as u64)
            .unwrap_or(0);
        if probe_indexed_path(fs::metadata(&folder_path))?.is_none() {
            if let Some(audios) = folder_item
                .get_mut("audios")
                .and_then(|value| value.as_array_mut())
            {
                for audio in audios.iter_mut() {
                    if audio_json_is_valid(audio) {
                        set_audio_json_valid(audio, false);
                        invalidated += 1;
                        index_changed = true;
                    }
                }
            }
            checked += folder_audio_count;
            continue;
        }
        let new_folder_modified = folder_change_stamp(Path::new(folder_path.as_str()));
        let indexed_audios: &[serde_json::Value] = folder_item
            .get("audios")
            .and_then(|value| value.as_array())
            .map(Vec::as_slice)
            .unwrap_or_default();
        let folder_scan = indexed_folder_scan(
            Path::new(&folder_path),
            indexed_audios,
            old_folder_modified,
            new_folder_modified,
            force_metadata_check || refresh_all_metadata,
        );
        if folder_scan == IndexedFolderScan::Skip {
            checked += folder_audio_count;
            skipped_tag_reads += folder_audio_count;
            continue;
        }
        discovery_roots.push(PathBuf::from(&folder_path));

        let _ = sink.add(IndexActionState {
            progress: if total == 0 {
                0.0
            } else {
                checked as f64 / total as f64
            },
            message: String::from("正在更新 ") + &folder_path,
            phase: IndexPhase::Scanning,
            unreadable_total,
        });

        if new_folder_modified != old_folder_modified {
            folder_item["modified"] = serde_json::json!(new_folder_modified);
            index_changed = true;
        }

        // 虚拟轨的 path 是合成路径（容器路径::track=..::start=..::end=..[::sacd=..]），
        // 逐条 fs::metadata 探活必然失败；目录含 CUE/ISO 或已有虚拟轨时整体重建。
        if folder_scan == IndexedFolderScan::RebuildVirtual {
            match AudioFolder::read_from_folder(&folder_path) {
                Ok(rebuilt) => {
                    let rebuilt_audios: Vec<serde_json::Value> = rebuilt
                        .audios
                        .iter()
                        .map(|audio| audio.to_json_value())
                        .collect();
                    let rebuilt_count = rebuilt_audios.len() as u64;
                    folder_item["audios"] = serde_json::Value::Array(rebuilt_audios);
                    folder_item["modified"] = serde_json::json!(rebuilt.modified);
                    folder_item["latest"] = serde_json::json!(rebuilt.latest);
                    checked += rebuilt_count;
                    index_changed = true;
                    let _ = sink.add(IndexActionState {
                        progress: if total == 0 {
                            1.0
                        } else {
                            checked as f64 / total as f64
                        },
                        message: String::new(),
                        phase: IndexPhase::Scanning,
                        unreadable_total: 0,
                    });
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    // 目录为空或已没有音乐：保留条目但全部标为无效。
                    let mut invalidated_here = 0_u64;
                    if let Some(audios) = folder_item
                        .get_mut("audios")
                        .and_then(|value| value.as_array_mut())
                    {
                        for audio in audios.iter_mut() {
                            if audio_json_is_valid(audio) {
                                set_audio_json_valid(audio, false);
                                invalidated_here += 1;
                            }
                        }
                    }
                    invalidated += invalidated_here;
                    checked += folder_audio_count;
                    if invalidated_here > 0 {
                        index_changed = true;
                    }
                }
                Err(error) => return Err(error.into()),
            }
            continue;
        }

        let audios = match folder_item["audios"].as_array_mut() {
            Some(a) => a,
            None => continue,
        };
        let mut refresh_jobs: Vec<(usize, PathBuf)> = Vec::new();
        let mut audio_probe_error = None;
        for (audio_index, audio_item) in audios.iter_mut().enumerate() {
            let Some(path) = audio_item["path"].as_str().map(str::to_string) else {
                audio_probe_error = Some(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "indexed audio is missing path",
                ));
                break;
            };
            match probe_indexed_path(fs::metadata(&path)) {
                Ok(Some(metadata)) => {
                    if !audio_json_is_valid(audio_item) {
                        set_audio_json_valid(audio_item, true);
                        revived += 1;
                        index_changed = true;
                    }
                    let update = if refresh_all_metadata {
                        IndexedAudioUpdate::RereadTags
                    } else {
                        indexed_audio_update(audio_item, &metadata)
                    };
                    match update {
                        IndexedAudioUpdate::RereadTags => {
                            refresh_jobs.push((audio_index, PathBuf::from(&path)));
                            tag_rereads += 1;
                        }
                        IndexedAudioUpdate::BackfillIdentity => {
                            backfill_audio_identity(audio_item, &metadata, Path::new(&path));
                            skipped_tag_reads += 1;
                            index_changed = true;
                        }
                        IndexedAudioUpdate::Skip => {
                            skipped_tag_reads += 1;
                        }
                    }
                }
                Ok(None) => {
                    if audio_json_is_valid(audio_item) {
                        set_audio_json_valid(audio_item, false);
                        invalidated += 1;
                        index_changed = true;
                    }
                }
                Err(error) => {
                    audio_probe_error = Some(error);
                    break;
                }
            }
        }
        if let Some(error) = audio_probe_error {
            return Err(error.into());
        }

        checked += (audios.len() - refresh_jobs.len()) as u64;
        let refresh_paths: Vec<PathBuf> =
            refresh_jobs.iter().map(|(_, path)| path.clone()).collect();
        let checked_before_refresh = checked;
        let refreshed = read_audio_paths_parallel(&refresh_paths, |completed| {
            let completed = checked_before_refresh + completed as u64;
            if should_emit_index_progress(completed as usize, total as usize) {
                let _ = sink.add(IndexActionState {
                    progress: if total == 0 {
                        1.0
                    } else {
                        completed as f64 / total as f64
                    },
                    message: String::new(),
                    phase: IndexPhase::Scanning,
                    unreadable_total,
                });
            }
        });
        checked += refresh_jobs.len() as u64;
        for ((audio_index, _), modified_audio) in refresh_jobs.into_iter().zip(refreshed) {
            if let Some(modified_audio) = modified_audio {
                audios[audio_index] = modified_audio.to_json_value();
                index_changed = true;
            } else {
                unreadable_total += 1;
                if audio_json_is_valid(&audios[audio_index]) {
                    set_audio_json_valid(&mut audios[audio_index], false);
                    invalidated += 1;
                    index_changed = true;
                }
            }
        }
        if refresh_paths.is_empty() {
            let _ = sink.add(IndexActionState {
                progress: if total == 0 {
                    1.0
                } else {
                    checked as f64 / total as f64
                },
                message: String::new(),
                phase: IndexPhase::Scanning,
                unreadable_total,
            });
        }

        let (new_latest, added, unreadable) =
            add_missing_audio_files(&folder_path, audios, latest)?;
        unreadable_total += unreadable;
        if added || new_latest != latest {
            folder_item["latest"] = serde_json::json!(new_latest);
            index_changed = true;
        }
    }

    {
        let existing_paths: HashSet<String> = folders
            .iter()
            .filter_map(|f| f.get("path").and_then(|v| v.as_str()).map(String::from))
            .collect();
        let mut new_entries: Vec<serde_json::Value> = Vec::new();
        let mut scanned_dirs: HashSet<String> = HashSet::new();
        for root_path in discovery_roots {
            let _ = sink.add(IndexActionState {
                progress: if total == 0 {
                    0.0
                } else {
                    checked as f64 / total as f64
                },
                message: format!("正在检查新增文件夹 {}", root_path.to_string_lossy()),
                phase: IndexPhase::Scanning,
                unreadable_total,
            });
            discover_new_audio_folders(
                &root_path,
                &existing_paths,
                &mut new_entries,
                &mut scanned_dirs,
            )?;
        }
        if !new_entries.is_empty() {
            index_changed = true;
            folders.extend(new_entries);
        }
    }

    let revived_moves = drop_invalid_duplicates_by_media_id(folders);
    if revived_moves > 0 {
        revived += revived_moves as u64;
        index_changed = true;
    }

    if index_changed || !sqlite_snapshot_current {
        let _ = sink.add(IndexActionState {
            progress: 1.0,
            message: String::from("正在保存索引"),
            phase: IndexPhase::Saving,
            unreadable_total,
        });
        library_db::write_index_snapshot(&index_dir, &index)?;
    }
    log::info!(
        target: "library",
        "[perf] index update skipped={} reread={} invalidated={} revived={} changed={}",
        skipped_tag_reads,
        tag_rereads,
        invalidated,
        revived,
        index_changed,
    );

    let _ = sink.add(IndexActionState {
        progress: 1.0,
        message: String::from("音乐库更新完成"),
        phase: IndexPhase::Complete,
        unreadable_total,
    });

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::is_network_path;
    use std::path::Path;

    #[test]
    fn recognizes_windows_network_paths() {
        assert!(is_network_path(Path::new(r"\\server\share")));
        assert!(is_network_path(Path::new(r"\\?\UNC\server\share")));
    }

    #[test]
    fn keeps_extended_local_paths_out_of_network_paths() {
        assert!(!is_network_path(Path::new(r"\\?\C:\Music")));
    }
}
