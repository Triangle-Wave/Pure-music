use std::path::Path;

use id3::TagLike;
use ndsd_read::{dff_reader::DFFReader, DSDFormat, DSDReader};

use super::{
    dsd_native_bitrate,
    estimated_bitrate,
    id3_text,
    optional_nonempty,
    read_id3_from_bytes,
};

#[derive(Clone)]
pub(super) struct DffMetadata {
    pub(super) title: Option<String>,
    pub(super) artist: Option<String>,
    pub(super) album: Option<String>,
    pub(super) album_artist: Option<String>,
    pub(super) genre: Option<String>,
    pub(super) year: Option<String>,
    pub(super) composer: Option<String>,
    pub(super) bpm: Option<String>,
    pub(super) track: Option<u32>,
    pub(super) disc: Option<u32>,
    pub(super) duration: u64,
    pub(super) bitrate: Option<u32>,
    pub(super) sample_rate: Option<u32>,
    pub(super) channels: Option<u8>,
    pub(super) picture: Option<Vec<u8>>,
    pub(super) items: Vec<(String, String)>,
}

/// DFF 码率（kbps）：优先按 DSD 原生口径 `sample_rate * channels / 1000`，
/// 与 DSF 及 Lofty 防御分支保持一致；仅在采样率或声道数缺失时回退到
/// 文件大小与时长估算。
fn dff_bitrate(
    path: &Path,
    duration: u64,
    sample_rate: Option<u32>,
    channels: Option<u8>,
) -> Option<u32> {
    let sample_rate = sample_rate.filter(|value| *value > 0);
    let channels = channels.filter(|value| *value > 0);
    if let (Some(sample_rate), Some(channels)) = (sample_rate, channels) {
        return dsd_native_bitrate(Some(sample_rate), Some(channels));
    }
    estimated_bitrate(path, duration)
}

pub(super) fn read_dff_metadata(path: &Path) -> Option<DffMetadata> {
    let path_string = path.to_string_lossy();
    let mut reader = DFFReader::new(&path_string).ok()?;
    let mut format = DSDFormat::default();
    reader.open(&mut format).ok()?;
    let dsd_metadata = reader.get_metadata();
    let id3_tag = dsd_metadata
        .and_then(|metadata| metadata.id3_raw.as_deref())
        .and_then(read_id3_from_bytes);
    let id3_tag = id3_tag.as_ref();
    let duration = if format.sampling_rate == 0 {
        0
    } else {
        format.total_samples.saturating_mul(8) / u64::from(format.sampling_rate)
    };
    let title = id3_tag
        .and_then(|tag| tag.title().map(str::to_string))
        .or_else(|| dsd_metadata.and_then(|metadata| metadata.title.clone()));
    let artist = id3_tag
        .and_then(|tag| tag.artist().map(str::to_string))
        .or_else(|| dsd_metadata.and_then(|metadata| metadata.artist.clone()));
    let album = id3_tag
        .and_then(|tag| tag.album().map(str::to_string))
        .or_else(|| dsd_metadata.and_then(|metadata| metadata.album.clone()));
    let album_artist = id3_tag.and_then(|tag| tag.album_artist().map(str::to_string));
    let genre = id3_tag
        .and_then(|tag| tag.genre().map(str::to_string))
        .or_else(|| dsd_metadata.and_then(|metadata| metadata.genre.clone()));
    let year = id3_tag
        .and_then(|tag| tag.year())
        .or_else(|| dsd_metadata.and_then(|metadata| metadata.year.map(|year| year as i32)))
        .map(|value| value.to_string());
    let composer = id3_tag.and_then(|tag| id3_text(tag, "TCOM"));
    let bpm = id3_tag.and_then(|tag| id3_text(tag, "TBPM"));
    let picture = id3_tag
        .and_then(|tag| tag.pictures().next().map(|picture| picture.data.clone()))
        .or_else(|| {
            dsd_metadata.and_then(|metadata| {
                metadata
                    .cover_art
                    .first()
                    .map(|picture| picture.data.clone())
            })
        });
    let mut items = Vec::new();
    let mut push_item = |key: &str, value: Option<String>| {
        if let Some(value) = optional_nonempty(value) {
            items.push((key.to_string(), value));
        }
    };
    push_item("year", year.clone());
    push_item("genre", genre.clone());
    push_item("composer", composer.clone());
    push_item("bpm", bpm.clone());
    push_item("artist", artist.clone());
    push_item("album_artist", album_artist.clone());
    push_item(
        "track",
        id3_tag
            .and_then(|tag| tag.track())
            .map(|value| value.to_string()),
    );
    push_item(
        "disc",
        id3_tag
            .and_then(|tag| tag.disc())
            .map(|value| value.to_string()),
    );

    let sample_rate = (format.sampling_rate > 0).then_some(format.sampling_rate);
    let channels = u8::try_from(format.num_channels)
        .ok()
        .filter(|value| *value > 0);
    let bitrate = dff_bitrate(path, duration, sample_rate, channels);

    Some(DffMetadata {
        title,
        artist,
        album,
        album_artist,
        genre,
        year,
        composer,
        bpm,
        track: id3_tag.and_then(|tag| tag.track()),
        disc: id3_tag.and_then(|tag| tag.disc()),
        duration,
        bitrate,
        sample_rate,
        channels,
        picture,
        items,
    })
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::{dff_bitrate, read_dff_metadata};

    fn temp_dff_path(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "pure_music_{}_{}_{}.dff",
            label,
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn push_chunk(out: &mut Vec<u8>, id: &[u8; 4], payload: &[u8]) {
        out.extend_from_slice(id);
        out.extend_from_slice(&(payload.len() as u64).to_be_bytes());
        out.extend_from_slice(payload);
        if payload.len() % 2 == 1 {
            out.push(0);
        }
    }

    /// 最小 DSDIFF 文件：FRM8(DSD ) → PROP(SND: FS/CHNL/CMPR) → DSD 数据块。
    fn minimal_dff(sample_rate: u32, channels: u16, data_bytes: u32) -> Vec<u8> {
        let mut prop = b"SND ".to_vec();
        push_chunk(&mut prop, b"FS  ", &sample_rate.to_be_bytes());
        let mut channel_payload = channels.to_be_bytes().to_vec();
        for _ in 0..channels {
            channel_payload.extend_from_slice(b"SLFT");
        }
        push_chunk(&mut prop, b"CHNL", &channel_payload);
        push_chunk(&mut prop, b"CMPR", b"DSD ");

        let mut file = b"FRM8".to_vec();
        file.extend_from_slice(&[0u8; 8]);
        file.extend_from_slice(b"DSD ");
        push_chunk(&mut file, b"PROP", &prop);
        push_chunk(&mut file, b"DSD ", &vec![0u8; data_bytes as usize]);
        let form_size = (file.len() - 12) as u64;
        file[4..12].copy_from_slice(&form_size.to_be_bytes());
        file
    }

    fn write_temp_dff(label: &str, bytes: &[u8]) -> PathBuf {
        let path = temp_dff_path(label);
        std::fs::write(&path, bytes).unwrap();
        path
    }

    #[test]
    fn invalid_dff_input_returns_none() {
        let path = std::env::temp_dir().join(format!(
            "pure_music_invalid_dff_{}_{}.dff",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::write(&path, b"not a dff").unwrap();

        assert!(read_dff_metadata(&path).is_none());

        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn dff_bitrate_uses_native_dsd_rate_over_file_size_estimate() {
        let sample_rate = 2_822_400u32;
        let channels = 2u16;
        // 1 秒 DSD64 数据量：duration 为 1 秒，文件头字节使大小估算值为 5645。
        let data_bytes = sample_rate * u32::from(channels) / 8;
        let path = write_temp_dff(
            "dff_native_bitrate",
            &minimal_dff(sample_rate, channels, data_bytes),
        );

        let metadata = read_dff_metadata(&path).expect("dff metadata");
        assert_eq!(metadata.duration, 1);
        assert_eq!(metadata.sample_rate, Some(sample_rate));
        assert_eq!(metadata.channels, Some(2));
        assert_eq!(metadata.bitrate, Some(sample_rate * 2 / 1000));
        assert_ne!(
            metadata.bitrate,
            super::super::estimated_bitrate(&path, metadata.duration)
        );

        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn dff_bitrate_falls_back_only_when_sample_rate_or_channels_missing() {
        let path = write_temp_dff("dff_bitrate_fallback", &minimal_dff(2_822_400, 2, 4_000));
        let duration = 1;
        assert_eq!(
            dff_bitrate(&path, duration, None, Some(2)),
            super::super::estimated_bitrate(&path, duration)
        );
        assert_eq!(
            dff_bitrate(&path, duration, Some(2_822_400), None),
            super::super::estimated_bitrate(&path, duration)
        );
        assert_eq!(dff_bitrate(&path, duration, Some(2_822_400), Some(2)), Some(5_644));
        std::fs::remove_file(path).unwrap();
    }
}
