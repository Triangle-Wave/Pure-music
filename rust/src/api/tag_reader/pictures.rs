//! 专辑内嵌图片的多图读取：图片角色识别、去重、上限控制与按序号缩略图。
//!
//! 主路径使用 lofty 遍历文件中的所有标签与图片；lofty 无法读取时，按文件
//! 格式回退到 DSF、DFF、ASF、ID3 与 Symphonia 读取器。所有读取器都返回完整
//! 图片列表，由上层统一去重并按上限截断。

use std::collections::HashSet;
use std::fs;
use std::io::Cursor;
use std::path::Path;

use anyhow::{anyhow, Context, Result};
use id3::TagLike as _;
use lofty::config::{ParseOptions, ParsingMode};
use lofty::file::TaggedFileExt as _;
use lofty::picture::PictureType as LoftyPictureType;
use lofty::probe::Probe;
use md5::{Digest, Md5};
use ratag::tag::Picture as RatagPictureTag;
use ratag::{Picture as RatagPictureData, PictureKind as RatagPictureKind};
use symphonia::core::meta::StandardVisualKey;

use super::format_detection::{
    is_asf_path, is_dff_path, is_dsf_path, is_generic_id3_path, is_symphonia_path,
};
use super::{dff, symphonia as symphonia_reader};

/// 单张内嵌图片允许进入解析结果的最大字节数（32 MiB）。
const MAX_PICTURE_BYTES: usize = 32 * 1024 * 1024;

/// 单个文件允许保留的最大图片数量。
const MAX_PICTURES_PER_FILE: usize = 64;

/// 图片在专辑中的角色。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PictureKind {
    /// 封面（正面）。
    Front,
    /// 封底。
    Back,
    /// 碟片或光盘介质图片。
    Disc,
    /// 内页、插画或歌词页。
    Booklet,
    /// 其他角色。
    Other,
}

/// 一条内嵌图片的元数据。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PictureInfo {
    /// 图片在去重后的完整列表中的序号，从 0 开始。
    pub index: u32,
    /// 图片角色。
    pub kind: PictureKind,
    /// 图片 MIME 类型；标签缺失时按图片数据特征推断，无法识别时为空串。
    pub mime_type: String,
    /// 标签中记录的图片描述，空描述归一为 `None`。
    pub description: Option<String>,
}

/// 解析后的内嵌图片，供标签读取器与缩略图缓存共享。
#[derive(Debug, Clone)]
pub(super) struct EmbeddedPicture {
    pub(super) mime_type: String,
    pub(super) description: Option<String>,
    pub(super) kind: PictureKind,
    pub(super) data: Vec<u8>,
}

/// 把 lofty 的图片角色映射为项目角色。
pub(super) fn kind_from_lofty(picture_type: LoftyPictureType) -> PictureKind {
    match picture_type {
        LoftyPictureType::CoverFront => PictureKind::Front,
        LoftyPictureType::CoverBack => PictureKind::Back,
        LoftyPictureType::Media => PictureKind::Disc,
        LoftyPictureType::Leaflet | LoftyPictureType::Illustration => PictureKind::Booklet,
        _ => PictureKind::Other,
    }
}

/// 把 ID3 的图片角色映射为项目角色。
pub(super) fn kind_from_id3(picture_type: id3::frame::PictureType) -> PictureKind {
    match picture_type {
        id3::frame::PictureType::CoverFront => PictureKind::Front,
        id3::frame::PictureType::CoverBack => PictureKind::Back,
        id3::frame::PictureType::Media => PictureKind::Disc,
        id3::frame::PictureType::Leaflet | id3::frame::PictureType::Illustration => {
            PictureKind::Booklet
        }
        _ => PictureKind::Other,
    }
}

/// 把 Symphonia 的视觉用途映射为项目角色。
pub(super) fn kind_from_symphonia(usage: Option<StandardVisualKey>) -> PictureKind {
    match usage {
        Some(StandardVisualKey::FrontCover) => PictureKind::Front,
        Some(StandardVisualKey::BackCover) => PictureKind::Back,
        Some(StandardVisualKey::Media) => PictureKind::Disc,
        Some(StandardVisualKey::Leaflet) | Some(StandardVisualKey::Illustration) => {
            PictureKind::Booklet
        }
        _ => PictureKind::Other,
    }
}

/// 把 ratag 的图片类型位集映射为项目角色；多个类型同时存在时按封面、
/// 封底、介质、内页的优先级取第一个命中的角色。
pub(super) fn kind_from_ratag(kind: RatagPictureKind) -> PictureKind {
    if kind.contains(RatagPictureKind::FRONT_COVER) {
        PictureKind::Front
    } else if kind.contains(RatagPictureKind::BACK_COVER) {
        PictureKind::Back
    } else if kind.contains(RatagPictureKind::MEDIA) {
        PictureKind::Disc
    } else if kind.contains(RatagPictureKind::LEAFLET_PAGE)
        || kind.contains(RatagPictureKind::ILLUSTRATION)
    {
        PictureKind::Booklet
    } else {
        PictureKind::Other
    }
}

/// 按图片数据头部特征推断 MIME 类型，无法识别时返回空串。
fn sniff_mime(data: &[u8]) -> &'static str {
    if data.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        "image/png"
    } else if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "image/jpeg"
    } else if data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a") {
        "image/gif"
    } else if data.starts_with(b"BM") {
        "image/bmp"
    } else if data.starts_with(&[0x49, 0x49, 0x2A, 0x00])
        || data.starts_with(&[0x4D, 0x4D, 0x00, 0x2A])
    {
        "image/tiff"
    } else if data.len() >= 12 && data.starts_with(b"RIFF") && &data[8..12] == b"WEBP" {
        "image/webp"
    } else {
        ""
    }
}

fn normalize_description(description: Option<&str>) -> Option<String> {
    description
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn normalize_mime(mime_type: Option<&str>, data: &[u8]) -> String {
    mime_type
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| sniff_mime(data).to_string())
}

/// 由各读取器共享的图片构造函数，统一 MIME、描述与角色归一规则。
pub(super) fn embedded_from_parts(
    mime_type: Option<&str>,
    description: Option<&str>,
    kind: PictureKind,
    data: Vec<u8>,
) -> EmbeddedPicture {
    EmbeddedPicture {
        mime_type: normalize_mime(mime_type, &data),
        description: normalize_description(description),
        kind,
        data,
    }
}

/// 由 ID3 图片构造内嵌图片。
pub(super) fn embedded_from_id3(picture: &id3::frame::Picture) -> EmbeddedPicture {
    embedded_from_parts(
        Some(picture.mime_type.as_str()),
        Some(picture.description.as_str()),
        kind_from_id3(picture.picture_type),
        picture.data.clone(),
    )
}

/// 收集并约束内嵌图片：按数据哈希去重、过滤空图与超大图、限制单文件数量。
struct PictureCollector<'a> {
    path: &'a str,
    pictures: Vec<EmbeddedPicture>,
    seen: HashSet<[u8; 16]>,
    truncated: bool,
}

impl<'a> PictureCollector<'a> {
    fn new(path: &'a str) -> Self {
        Self {
            path,
            pictures: Vec::new(),
            seen: HashSet::new(),
            truncated: false,
        }
    }

    fn push(&mut self, picture: EmbeddedPicture) {
        if picture.data.is_empty() {
            return;
        }
        if picture.data.len() > MAX_PICTURE_BYTES {
            log::warn!(
                target: "tag",
                "skip oversized embedded picture for {}: {} bytes exceeds {} bytes",
                self.path,
                picture.data.len(),
                MAX_PICTURE_BYTES
            );
            return;
        }
        let digest = Md5::digest(&picture.data);
        let mut hash = [0_u8; 16];
        hash.copy_from_slice(digest.as_slice());
        if !self.seen.insert(hash) {
            return;
        }
        if self.pictures.len() >= MAX_PICTURES_PER_FILE {
            if !self.truncated {
                self.truncated = true;
                log::warn!(
                    target: "tag",
                    "truncate embedded pictures for {}: more than {} pictures",
                    self.path,
                    MAX_PICTURES_PER_FILE
                );
            }
            return;
        }
        self.pictures.push(picture);
    }

    fn finish(self) -> Vec<EmbeddedPicture> {
        self.pictures
    }
}

/// 使用 lofty 遍历所有标签中的所有图片。
fn read_lofty_pictures(path: &Path) -> Result<Vec<EmbeddedPicture>> {
    let options = ParseOptions::new()
        .parsing_mode(ParsingMode::Relaxed)
        .read_tags(true)
        .read_cover_art(true)
        .read_properties(false);
    let path_display = path.display();
    let tagged_file = Probe::open(path)
        .and_then(|probe| probe.options(options).read())
        .map_err(|err| anyhow!("read lofty tags: {path_display}: {err}"))?;

    let mut pictures = Vec::new();
    for tag in tagged_file.tags() {
        for picture in tag.pictures() {
            pictures.push(embedded_from_parts(
                picture.mime_type().map(|mime_type| mime_type.as_str()),
                picture.description(),
                kind_from_lofty(picture.pic_type()),
                picture.data().to_vec(),
            ));
        }
    }
    Ok(pictures)
}

fn read_dsf_pictures(path: &Path) -> Result<Vec<EmbeddedPicture>> {
    let file = dsf_meta::DsfFile::open(path)
        .map_err(|err| anyhow!("open DSF file {}: {err}", path.display()))?;
    let Some(tag) = file.id3_tag().as_ref() else {
        return Ok(Vec::new());
    };
    Ok(tag.pictures().map(embedded_from_id3).collect())
}

fn read_asf_pictures(path: &Path) -> Result<Vec<EmbeddedPicture>> {
    let mut collector = RatagPictureTag::preferably_cover();
    collector.max_cnt = MAX_PICTURES_PER_FILE;
    collector.types = RatagPictureKind::all();
    // 清空优先级后 ratag 不再用后续图片替换已收集的图片，保证完整遍历。
    collector.precedence.clear();
    ratag::read_tag_from_file(path, &mut collector, &ratag::trap::Skip)
        .map_err(|err| anyhow!("read ASF pictures from {}: {err}", path.display()))?;

    Ok(collector
        .pictures
        .into_iter()
        .filter(|picture| !picture.is_uri)
        .map(embedded_from_ratag)
        .collect())
}

fn embedded_from_ratag(picture: RatagPictureData) -> EmbeddedPicture {
    embedded_from_parts(
        picture.mime.as_deref(),
        picture.description.as_deref(),
        kind_from_ratag(picture.kind),
        picture.data,
    )
}

fn read_id3_pictures(path: &Path) -> Result<Vec<EmbeddedPicture>> {
    let tag = id3::Tag::read_from_path(path)
        .map_err(|err| anyhow!("read ID3 pictures from {}: {err}", path.display()))?;
    Ok(tag.pictures().map(embedded_from_id3).collect())
}

/// 按文件格式选择兜底读取器，返回该格式下的完整图片列表。
fn read_fallback_pictures(path: &Path) -> Result<Vec<EmbeddedPicture>> {
    if is_dsf_path(path) {
        return read_dsf_pictures(path);
    }
    if is_dff_path(path) {
        return dff::read_dff_pictures(path);
    }
    if is_asf_path(path) {
        return read_asf_pictures(path);
    }
    if is_generic_id3_path(path) {
        return read_id3_pictures(path);
    }
    if is_symphonia_path(path) {
        let pictures = symphonia_reader::read_symphonia_pictures(path)?;
        if !pictures.is_empty() {
            return Ok(pictures);
        }
    }
    read_id3_pictures(path)
}

/// 读取文件的全部内嵌图片（去重、限长后的结果）。
///
/// 文件不存在、不是普通文件或全部读取器失败时返回带上下文的错误。
pub(super) fn load_pictures(path: &Path) -> Result<Vec<EmbeddedPicture>> {
    let metadata = fs::metadata(path)
        .with_context(|| format!("read picture source metadata: {}", path.display()))?;
    if !metadata.is_file() {
        return Err(anyhow!(
            "picture source is not a regular file: {}",
            path.display()
        ));
    }

    let path_string = path.to_string_lossy();
    let mut collector = PictureCollector::new(&path_string);

    match read_lofty_pictures(path) {
        Ok(pictures) => {
            for picture in pictures {
                collector.push(picture);
            }
        }
        Err(err) => {
            log::debug!(
                target: "tag",
                "lofty picture read failed for {}: {err:#}",
                path.display()
            );
        }
    }

    if collector.pictures.is_empty() {
        match read_fallback_pictures(path) {
            Ok(pictures) => {
                for picture in pictures {
                    collector.push(picture);
                }
            }
            Err(err) => {
                log::debug!(
                    target: "tag",
                    "fallback picture read failed for {}: {err:#}",
                    path.display()
                );
            }
        }
    }

    Ok(collector.finish())
}

/// 选择对外展示的首选图片：优先第一张封面，缺失时取列表第一张。
pub(super) fn preferred_picture(pictures: &[EmbeddedPicture]) -> Option<&EmbeddedPicture> {
    pictures
        .iter()
        .find(|picture| picture.kind == PictureKind::Front)
        .or_else(|| pictures.first())
}

pub(super) fn resize_picture_to_png(data: &[u8], width: u32, height: u32) -> Result<Vec<u8>> {
    if width == 0 || height == 0 {
        return Err(anyhow!(
            "picture target size must be positive: {width}x{height}"
        ));
    }
    let loaded = image::load_from_memory(data).context("decode embedded picture")?;
    if loaded.width() == 0 || loaded.height() == 0 {
        return Err(anyhow!("embedded picture has empty dimensions"));
    }
    let ratio = loaded.width() as f32 / loaded.height() as f32;
    let (result_width, result_height) = if ratio > 1.0 {
        (width, (width as f32 / ratio).round() as u32)
    } else {
        ((height as f32 * ratio).round() as u32, height)
    };
    let resized = image::imageops::resize(
        &loaded,
        result_width.max(1),
        result_height.max(1),
        image::imageops::FilterType::Triangle,
    );
    let mut output = Cursor::new(Vec::new());
    resized
        .write_to(&mut output, image::ImageFormat::Png)
        .context("encode resized picture as PNG")?;
    Ok(output.into_inner())
}

/// 列出文件的全部内嵌图片元数据，不解码图片。
///
/// 读取失败时记录告警并返回空列表。
pub fn list_pictures(path: String) -> Vec<PictureInfo> {
    match load_pictures(Path::new(&path)) {
        Ok(pictures) => pictures
            .iter()
            .enumerate()
            .map(|(index, picture)| PictureInfo {
                index: index as u32,
                kind: picture.kind,
                mime_type: picture.mime_type.clone(),
                description: picture.description.clone(),
            })
            .collect(),
        Err(err) => {
            log::warn!(
                target: "tag",
                "list embedded pictures failed for {path}: {err:#}"
            );
            Vec::new()
        }
    }
}

/// 读取指定序号的内嵌图片并缩放重编码为 PNG，使用进程内 LRU 缓存。
///
/// 序号来自 [`list_pictures`] 的返回顺序；越界、解码失败或文件不可读时返回
/// `None` 并记录告警。
pub fn get_picture_by_index(path: String, index: u32, width: u32, height: u32) -> Option<Vec<u8>> {
    let Ok(index_usize) = usize::try_from(index) else {
        return None;
    };
    let cache_key = super::picture_cache_key(&path, i64::from(index), width, height);
    if let Some(cached) = super::picture_cache_lookup(&cache_key) {
        return Some(cached);
    }

    let pictures = match load_pictures(Path::new(&path)) {
        Ok(pictures) => pictures,
        Err(err) => {
            log::warn!(
                target: "tag",
                "read embedded pictures failed for {path}: {err:#}"
            );
            return None;
        }
    };
    let Some(picture) = pictures.get(index_usize) else {
        log::debug!(
            target: "tag",
            "embedded picture index {index} out of range for {path} (count={})",
            pictures.len()
        );
        return None;
    };

    let png = match resize_picture_to_png(&picture.data, width, height) {
        Ok(png) => png,
        Err(err) => {
            log::warn!(
                target: "tag",
                "resize embedded picture {index} for {path} failed: {err:#}"
            );
            return None;
        }
    };
    super::picture_cache_store(cache_key, png.clone());
    Some(png)
}

#[cfg(test)]
mod tests {
    use super::{
        embedded_from_parts, kind_from_id3, kind_from_lofty, kind_from_ratag,
        kind_from_symphonia, preferred_picture, PictureCollector, PictureKind,
    };
    use id3::frame::PictureType as Id3PictureType;
    use lofty::picture::PictureType as LoftyPictureType;
    use ratag::PictureKind as RatagPictureKind;
    use symphonia::core::meta::StandardVisualKey;

    fn picture(data: Vec<u8>) -> super::EmbeddedPicture {
        embedded_from_parts(Some("image/png"), None, PictureKind::Other, data)
    }

    #[test]
    fn lofty_picture_kind_mapping_covers_album_roles() {
        assert_eq!(
            kind_from_lofty(LoftyPictureType::CoverFront),
            PictureKind::Front
        );
        assert_eq!(
            kind_from_lofty(LoftyPictureType::CoverBack),
            PictureKind::Back
        );
        assert_eq!(kind_from_lofty(LoftyPictureType::Media), PictureKind::Disc);
        assert_eq!(
            kind_from_lofty(LoftyPictureType::Leaflet),
            PictureKind::Booklet
        );
        assert_eq!(
            kind_from_lofty(LoftyPictureType::Illustration),
            PictureKind::Booklet
        );
        assert_eq!(kind_from_lofty(LoftyPictureType::Artist), PictureKind::Other);
    }

    #[test]
    fn id3_picture_kind_mapping_covers_album_roles() {
        assert_eq!(
            kind_from_id3(Id3PictureType::CoverFront),
            PictureKind::Front
        );
        assert_eq!(kind_from_id3(Id3PictureType::CoverBack), PictureKind::Back);
        assert_eq!(kind_from_id3(Id3PictureType::Media), PictureKind::Disc);
        assert_eq!(kind_from_id3(Id3PictureType::Leaflet), PictureKind::Booklet);
        assert_eq!(
            kind_from_id3(Id3PictureType::Illustration),
            PictureKind::Booklet
        );
        assert_eq!(kind_from_id3(Id3PictureType::Composer), PictureKind::Other);
        assert_eq!(
            kind_from_id3(Id3PictureType::Undefined(255)),
            PictureKind::Other
        );
    }

    #[test]
    fn symphonia_picture_kind_mapping_covers_album_roles() {
        assert_eq!(
            kind_from_symphonia(Some(StandardVisualKey::FrontCover)),
            PictureKind::Front
        );
        assert_eq!(
            kind_from_symphonia(Some(StandardVisualKey::BackCover)),
            PictureKind::Back
        );
        assert_eq!(
            kind_from_symphonia(Some(StandardVisualKey::Media)),
            PictureKind::Disc
        );
        assert_eq!(
            kind_from_symphonia(Some(StandardVisualKey::Leaflet)),
            PictureKind::Booklet
        );
        assert_eq!(
            kind_from_symphonia(Some(StandardVisualKey::Illustration)),
            PictureKind::Booklet
        );
        assert_eq!(
            kind_from_symphonia(Some(StandardVisualKey::Composer)),
            PictureKind::Other
        );
        assert_eq!(kind_from_symphonia(None), PictureKind::Other);
    }

    #[test]
    fn ratag_picture_kind_mapping_prefers_front_cover() {
        assert_eq!(
            kind_from_ratag(RatagPictureKind::FRONT_COVER | RatagPictureKind::BACK_COVER),
            PictureKind::Front
        );
        assert_eq!(
            kind_from_ratag(RatagPictureKind::BACK_COVER),
            PictureKind::Back
        );
        assert_eq!(kind_from_ratag(RatagPictureKind::MEDIA), PictureKind::Disc);
        assert_eq!(
            kind_from_ratag(
                RatagPictureKind::LEAFLET_PAGE | RatagPictureKind::ILLUSTRATION
            ),
            PictureKind::Booklet
        );
        assert_eq!(
            kind_from_ratag(RatagPictureKind::COMPOSER),
            PictureKind::Other
        );
    }

    #[test]
    fn duplicate_picture_data_keeps_first_occurrence() {
        let mut collector = PictureCollector::new("test.flac");
        collector.push(embedded_from_parts(
            Some("image/png"),
            Some("front"),
            PictureKind::Front,
            vec![1, 2, 3],
        ));
        collector.push(embedded_from_parts(
            Some("image/jpeg"),
            Some("back"),
            PictureKind::Back,
            vec![1, 2, 3],
        ));

        let pictures = collector.finish();
        assert_eq!(pictures.len(), 1);
        assert_eq!(pictures[0].kind, PictureKind::Front);
        assert_eq!(pictures[0].description.as_deref(), Some("front"));
    }

    #[test]
    fn picture_limit_truncates_after_64_unique_pictures() {
        let mut collector = PictureCollector::new("test.flac");
        for index in 0..70_u8 {
            collector.push(picture(vec![index]));
        }

        let pictures = collector.finish();
        assert_eq!(pictures.len(), super::MAX_PICTURES_PER_FILE);
        assert_eq!(pictures.first().map(|picture| picture.data[0]), Some(0));
        assert_eq!(
            pictures.last().map(|picture| picture.data[0]),
            Some(super::MAX_PICTURES_PER_FILE as u8 - 1)
        );
    }

    #[test]
    fn empty_picture_data_is_ignored() {
        let mut collector = PictureCollector::new("test.flac");
        collector.push(picture(Vec::new()));
        collector.push(picture(vec![7]));

        let pictures = collector.finish();
        assert_eq!(pictures.len(), 1);
        assert_eq!(pictures[0].data, vec![7]);
    }

    #[test]
    fn preferred_picture_uses_first_front_cover() {
        let pictures = vec![
            embedded_from_parts(None, None, PictureKind::Other, vec![9]),
            embedded_from_parts(None, None, PictureKind::Front, vec![1]),
            embedded_from_parts(None, None, PictureKind::Front, vec![2]),
        ];
        assert_eq!(
            preferred_picture(&pictures).map(|picture| picture.data[0]),
            Some(1)
        );

        let no_front = vec![
            embedded_from_parts(None, None, PictureKind::Back, vec![3]),
            embedded_from_parts(None, None, PictureKind::Other, vec![4]),
        ];
        assert_eq!(
            preferred_picture(&no_front).map(|picture| picture.data[0]),
            Some(3)
        );
    }

    #[test]
    fn picture_cache_key_includes_picture_index() {
        let legacy = crate::api::tag_reader::picture_cache_key("C:/missing.flac", -1, 96, 96);
        let first = crate::api::tag_reader::picture_cache_key("C:/missing.flac", 0, 96, 96);
        let second = crate::api::tag_reader::picture_cache_key("C:/missing.flac", 1, 96, 96);
        let other_size = crate::api::tag_reader::picture_cache_key("C:/missing.flac", 0, 128, 96);

        assert_ne!(legacy, first);
        assert_ne!(first, second);
        assert_ne!(first, other_size);
    }
}