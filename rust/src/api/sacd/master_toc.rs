//! Master TOC（LSN 510 起）解析。
//!
//! 字段偏移取自 Scarlet Book 的 Master_TOC 结构：
//! `SACDMTOC` 签名 + 版本 + 套装信息 + 音频区地址与长度。

use super::types::{
    validate_version, SacdError, SliceReader, MAX_AREA_TOC_SECTORS, MIN_AREA_TOC_SECTORS,
};

/// Master TOC 签名。
pub(super) const MASTER_TOC_SIGNATURE: &[u8] = b"SACDMTOC";

/// Master TOC 起始逻辑扇区号。
pub(super) const MASTER_TOC_START_LSN: u32 = 510;

/// Master TOC 占用扇区数。
pub(super) const MASTER_TOC_SECTOR_COUNT: u16 = 10;

/// Master TOC 中解析出的字段。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct MasterToc {
    /// 规范版本主号（偏移 0x0008）。
    pub(super) version_major: u8,
    /// 规范版本次号（偏移 0x0009）。
    pub(super) version_minor: u8,
    /// 套装内光盘总数（偏移 0x0010）。
    pub(super) album_set_size: u16,
    /// 当前光盘在套装内的序号（偏移 0x0012）。
    pub(super) album_sequence_number: u16,
    /// 2CH 区 TOC 1 起始 LSN（偏移 0x0040）。
    pub(super) area_1_toc_1_start: u32,
    /// 2CH 区 TOC 2 起始 LSN（偏移 0x0044）。
    pub(super) area_1_toc_2_start: u32,
    /// MCH 区 TOC 1 起始 LSN（偏移 0x0048）。
    pub(super) area_2_toc_1_start: u32,
    /// MCH 区 TOC 2 起始 LSN（偏移 0x004C）。
    pub(super) area_2_toc_2_start: u32,
    /// 光盘标志位（偏移 0x0050）。
    pub(super) disc_flags: u8,
    /// 2CH 区 TOC 长度，单位扇区（偏移 0x0054）。
    pub(super) area_1_toc_size: u16,
    /// MCH 区 TOC 长度，单位扇区（偏移 0x0056）。
    pub(super) area_2_toc_size: u16,
}

impl MasterToc {
    /// 从 Master TOC 扇区数据解析。
    ///
    /// 只读取前 88 字节，但允许传入完整的 10 个扇区。
    pub(super) fn parse(bytes: &[u8]) -> Result<Self, SacdError> {
        let mut reader = SliceReader::new(bytes);

        let signature = reader.read_bytes(8)?; // 0x0000..0x0008
        if signature != MASTER_TOC_SIGNATURE {
            return Err(SacdError::NotSacd);
        }

        let version_major = reader.read_u8()?; // 0x0008
        let version_minor = reader.read_u8()?; // 0x0009
        validate_version(version_major, version_minor)?;

        reader.skip(6)?; // 0x000A..0x0010 reserved
        let album_set_size = reader.read_u16()?; // 0x0010
        let album_sequence_number = reader.read_u16()?; // 0x0012
        reader.skip(4)?; // 0x0014..0x0018 reserved
        reader.skip(16)?; // 0x0018..0x0028 Album_Catalog_Number
        reader.skip(16)?; // 0x0028..0x0038 Album_Genre（4 x 4 字节）
        reader.skip(8)?; // 0x0038..0x0040 reserved

        let area_1_toc_1_start = reader.read_u32()?; // 0x0040
        let area_1_toc_2_start = reader.read_u32()?; // 0x0044
        let area_2_toc_1_start = reader.read_u32()?; // 0x0048
        let area_2_toc_2_start = reader.read_u32()?; // 0x004C

        let disc_flags = reader.read_u8()?; // 0x0050
        reader.skip(3)?; // 0x0051..0x0054 reserved

        let area_1_toc_size = reader.read_u16()?; // 0x0054
        let area_2_toc_size = reader.read_u16()?; // 0x0056

        let master_toc = Self {
            version_major,
            version_minor,
            album_set_size,
            album_sequence_number,
            area_1_toc_1_start,
            area_1_toc_2_start,
            area_2_toc_1_start,
            area_2_toc_2_start,
            disc_flags,
            area_1_toc_size,
            area_2_toc_size,
        };
        master_toc.validate_areas()?;
        Ok(master_toc)
    }

    /// 校验音频区地址与 TOC 长度。
    fn validate_areas(&self) -> Result<(), SacdError> {
        let has_two_channel = self.area_1_toc_1_start != 0 || self.area_1_toc_2_start != 0;
        let has_multi_channel = self.area_2_toc_1_start != 0 || self.area_2_toc_2_start != 0;

        if !has_two_channel && !has_multi_channel {
            return Err(SacdError::invalid("Master TOC 未声明任何音频区"));
        }

        if has_two_channel {
            validate_toc_size("双声道区", self.area_1_toc_size)?;
        }
        if has_multi_channel {
            validate_toc_size("多声道区", self.area_2_toc_size)?;
        }

        Ok(())
    }
}

/// 校验 Area TOC 长度是否在允许范围内。
fn validate_toc_size(label: &str, toc_size: u16) -> Result<(), SacdError> {
    if !(MIN_AREA_TOC_SECTORS..=MAX_AREA_TOC_SECTORS).contains(&toc_size) {
        return Err(SacdError::invalid(format!(
            "{label} TOC 长度 {toc_size} 不在 {}..={} 范围内",
            MIN_AREA_TOC_SECTORS, MAX_AREA_TOC_SECTORS
        )));
    }
    Ok(())
}
