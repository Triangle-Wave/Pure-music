//! SACD 镜像读取与 Master TOC / Area TOC 编排。
//!
//! 支持两种扇区布局：
//! - 2048 字节逻辑扇区（标准 ISO 布局）；
//! - 2064 字节扇区：12 字节头 + 2048 字节负载 + 4 字节尾。

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use super::area_toc::AreaTocHeader;
use super::master_toc::{
    MasterToc, MASTER_TOC_SECTOR_COUNT, MASTER_TOC_SIGNATURE, MASTER_TOC_START_LSN,
};
use super::tracklist::{build_tracks, parse_track_lists};
use super::types::{
    SacdArea, SacdError, SacdToc, MAX_AREA_TOC_SECTORS, MIN_AREA_TOC_SECTORS, SACD_LSN_SIZE,
};

/// 2064 字节扇区的总大小。
const HEADERED_SECTOR_SIZE: u64 = 2064;

/// 2064 字节扇区中位于负载之前的头部长度。
const HEADERED_SECTOR_HEADER: u64 = 12;

/// 2064 字节扇区中位于负载之后的尾部长度。
const HEADERED_SECTOR_TAIL: u64 = 4;

/// 单次读取的扇区数上限，避免异常数据造成超大分配。
const MAX_SECTORS_PER_READ: u64 = 128;

/// 镜像的扇区布局。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SectorLayout {
    /// 标准 2048 字节扇区。
    Plain2048,
    /// 2064 字节扇区：12 字节头 + 2048 字节负载 + 4 字节尾。
    Headered2064,
}

impl SectorLayout {
    /// 当前布局的物理扇区大小。
    const fn sector_size(self) -> u64 {
        match self {
            Self::Plain2048 => SACD_LSN_SIZE as u64,
            Self::Headered2064 => HEADERED_SECTOR_SIZE,
        }
    }

    /// 扇区负载之前的头部长度。
    const fn payload_header(self) -> u64 {
        match self {
            Self::Plain2048 => 0,
            Self::Headered2064 => HEADERED_SECTOR_HEADER,
        }
    }
}

/// 判断目标文件是否为 SACD 镜像。
///
/// 只读取 Master TOC 起始处少量字节；任何读取失败都返回 `false`。
pub(crate) fn is_sacd_iso(path: &Path) -> bool {
    ImageReader::open(path).is_ok()
}

/// 读取并解析 SACD 的 Master TOC、Area TOC 与轨道列表。
pub(crate) fn read_sacd_toc(path: &Path) -> Result<SacdToc, SacdError> {
    let mut image = ImageReader::open(path)?;

    let master_bytes = image.read_sectors(MASTER_TOC_START_LSN, MASTER_TOC_SECTOR_COUNT)?;
    let master = MasterToc::parse(&master_bytes)?;

    let mut areas = Vec::with_capacity(2);
    if let Some(area) = read_area(
        &mut image,
        "双声道区",
        master.area_1_toc_1_start,
        master.area_1_toc_2_start,
        master.area_1_toc_size,
    )? {
        areas.push(area);
    }
    if let Some(area) = read_area(
        &mut image,
        "多声道区",
        master.area_2_toc_1_start,
        master.area_2_toc_2_start,
        master.area_2_toc_size,
    )? {
        areas.push(area);
    }

    if areas.is_empty() {
        return Err(SacdError::invalid("镜像中没有可解析的音频区"));
    }

    Ok(SacdToc {
        version_major: master.version_major,
        version_minor: master.version_minor,
        disc_flags: master.disc_flags,
        album_set_size: master.album_set_size,
        album_sequence_number: master.album_sequence_number,
        areas,
    })
}

/// 读取一个音频区；TOC 1 优先，失败时回退到 TOC 2。
fn read_area(
    image: &mut ImageReader,
    label: &str,
    toc_1_start: u32,
    toc_2_start: u32,
    toc_size: u16,
) -> Result<Option<SacdArea>, SacdError> {
    if toc_1_start == 0 && toc_2_start == 0 {
        return Ok(None);
    }
    if !(MIN_AREA_TOC_SECTORS..=MAX_AREA_TOC_SECTORS).contains(&toc_size) {
        return Err(SacdError::invalid(format!(
            "{label} TOC 长度 {toc_size} 不在 {}..={} 范围内",
            MIN_AREA_TOC_SECTORS, MAX_AREA_TOC_SECTORS
        )));
    }

    let mut last_error = None;
    for start_lsn in [toc_1_start, toc_2_start] {
        if start_lsn == 0 {
            continue;
        }
        match read_area_at(image, start_lsn, toc_size) {
            Ok(area) => return Ok(Some(area)),
            Err(error) => last_error = Some(error),
        }
    }

    Err(last_error.unwrap_or_else(|| SacdError::invalid(format!("{label} 缺少可用的 Area TOC"))))
}

/// 从指定 LSN 读取并解析一个 Area TOC 及其轨道列表。
fn read_area_at(
    image: &mut ImageReader,
    start_lsn: u32,
    toc_size: u16,
) -> Result<SacdArea, SacdError> {
    let toc_bytes = image.read_sectors(start_lsn, toc_size)?;
    let header = AreaTocHeader::parse(&toc_bytes)?;
    let track_lists = parse_track_lists(&toc_bytes, toc_size, header.track_count)?;
    let tracks = build_tracks(
        header.track_count,
        track_lists.list_1.as_ref(),
        track_lists.list_2.as_ref(),
    )?;

    Ok(SacdArea {
        kind: header.kind,
        channel_count: header.channel_count,
        track_count: header.track_count,
        total_playtime_ms: header.total_playtime_ms,
        frame_format: header.frame_format,
        track_start_lsn: header.track_start_lsn,
        track_end_lsn: header.track_end_lsn,
        tracks,
    })
}

/// 已打开的 SACD 镜像。
struct ImageReader {
    file: File,
    layout: SectorLayout,
    file_len: u64,
}

impl ImageReader {
    /// 打开文件并识别扇区布局。
    fn open(path: &Path) -> Result<Self, SacdError> {
        let mut file = File::open(path)?;
        let file_len = file.metadata()?.len();
        let layout = detect_layout(&mut file, file_len)?;
        Ok(Self {
            file,
            layout,
            file_len,
        })
    }

    /// 读取从 `lsn` 开始的 `count` 个逻辑扇区，返回连续的 2048 字节负载。
    fn read_sectors(&mut self, lsn: u32, count: u16) -> Result<Vec<u8>, SacdError> {
        let count = u64::from(count);
        if count == 0 {
            return Err(SacdError::invalid("读取扇区数不能为 0"));
        }
        if count > MAX_SECTORS_PER_READ {
            return Err(SacdError::invalid(format!(
                "单次读取扇区数 {count} 超过上限 {MAX_SECTORS_PER_READ}"
            )));
        }

        let start = u64::from(lsn)
            .checked_mul(self.layout.sector_size())
            .ok_or_else(|| SacdError::invalid("读取偏移溢出"))?;
        let raw_len = count
            .checked_mul(self.layout.sector_size())
            .ok_or_else(|| SacdError::invalid("读取长度溢出"))?;
        let end = start
            .checked_add(raw_len)
            .ok_or_else(|| SacdError::invalid("读取范围溢出"))?;
        if end > self.file_len {
            return Err(SacdError::invalid(format!(
                "LSN {lsn} 起的 {count} 个扇区超出镜像大小"
            )));
        }

        self.file.seek(SeekFrom::Start(start))?;
        let raw_len = usize::try_from(raw_len)
            .map_err(|_| SacdError::invalid("读取长度超出平台地址空间"))?;
        let mut raw = vec![0u8; raw_len];
        self.file.read_exact(&mut raw)?;

        match self.layout {
            SectorLayout::Plain2048 => Ok(raw),
            SectorLayout::Headered2064 => strip_sector_headers(&raw),
        }
    }
}

/// 识别镜像布局：先按 2048 字节扇区检查魔数，再按 2064 字节扇区检查。
fn detect_layout(file: &mut File, file_len: u64) -> Result<SectorLayout, SacdError> {
    for layout in [SectorLayout::Plain2048, SectorLayout::Headered2064] {
        let offset = master_toc_payload_offset(layout)?;
        if has_signature_at(file, offset, MASTER_TOC_SIGNATURE, file_len)? {
            return Ok(layout);
        }
    }
    Err(SacdError::NotSacd)
}

/// 计算 Master TOC 负载在文件中的起始偏移。
fn master_toc_payload_offset(layout: SectorLayout) -> Result<u64, SacdError> {
    u64::from(MASTER_TOC_START_LSN)
        .checked_mul(layout.sector_size())
        .and_then(|offset| offset.checked_add(layout.payload_header()))
        .ok_or_else(|| SacdError::invalid("Master TOC 偏移计算溢出"))
}

/// 检查文件指定偏移处是否为给定签名。
fn has_signature_at(
    file: &mut File,
    offset: u64,
    signature: &[u8],
    file_len: u64,
) -> Result<bool, SacdError> {
    let end = offset
        .checked_add(signature.len() as u64)
        .ok_or_else(|| SacdError::invalid("签名检查偏移溢出"))?;
    if end > file_len {
        return Ok(false);
    }

    file.seek(SeekFrom::Start(offset))?;
    let mut buffer = [0u8; 8];
    let target = buffer
        .get_mut(..signature.len())
        .ok_or_else(|| SacdError::invalid("签名长度超出缓冲区"))?;
    match file.read_exact(target) {
        Ok(()) => Ok(&*target == signature),
        Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => Ok(false),
        Err(error) => Err(SacdError::Io(error)),
    }
}

/// 去掉 2064 字节扇区的前 12 字节头与后 4 字节尾，拼接出连续的 2048 字节负载。
fn strip_sector_headers(raw: &[u8]) -> Result<Vec<u8>, SacdError> {
    let sector_size = usize::try_from(HEADERED_SECTOR_SIZE)
        .map_err(|_| SacdError::invalid("扇区大小超出平台地址空间"))?;
    let header_len = usize::try_from(HEADERED_SECTOR_HEADER)
        .map_err(|_| SacdError::invalid("扇区头长度超出平台地址空间"))?;
    let tail_len = usize::try_from(HEADERED_SECTOR_TAIL)
        .map_err(|_| SacdError::invalid("扇区尾长度超出平台地址空间"))?;
    let payload_len = sector_size
        .checked_sub(header_len)
        .and_then(|remaining| remaining.checked_sub(tail_len))
        .ok_or_else(|| SacdError::invalid("扇区头尾长度大于扇区大小"))?;

    let mut payload = Vec::with_capacity(raw.len() / sector_size * payload_len);
    for sector in raw.chunks_exact(sector_size) {
        let payload_end = header_len
            .checked_add(payload_len)
            .ok_or_else(|| SacdError::invalid("扇区负载范围溢出"))?;
        let bytes = sector
            .get(header_len..payload_end)
            .ok_or_else(|| SacdError::invalid("扇区负载长度不足"))?;
        payload.extend_from_slice(bytes);
    }
    Ok(payload)
}
