import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/cue_segment_path.dart';
import 'package:pure_music/library/track_override.dart';

void main() {
  group('CueSegmentPath.trackUid', () {
    test('归一化大小写与路径分隔符', () {
      const segment = CueSegmentPath(
        sourcePath: r'D:\Music\Album\Disc.FLAC',
        trackNumber: 2,
        startMs: 0,
        endMs: 1000,
      );

      expect(segment.trackUid, 'cue:d:/music/album/disc.flac#02');
    });

    test('两位轨号补零，三位轨号保持原样', () {
      const twoDigit = CueSegmentPath(
        sourcePath: r'D:\Music\disc.flac',
        trackNumber: 7,
        startMs: 0,
        endMs: 1000,
      );
      const threeDigit = CueSegmentPath(
        sourcePath: r'D:\Music\disc.flac',
        trackNumber: 123,
        startMs: 0,
        endMs: 1000,
      );

      expect(twoDigit.trackUid, 'cue:d:/music/disc.flac#07');
      expect(threeDigit.trackUid, 'cue:d:/music/disc.flac#123');
    });

    test('从合成路径解析后得到同一主键', () {
      final segment = parseCueSegmentPath(
        r'D:\Music\Album\disc.flac::track=02::start=1000::end=201000',
      );

      expect(segment?.trackUid, 'cue:d:/music/album/disc.flac#02');
    });
  });

  group('Audio.applyTrackOverride', () {
    Audio buildAudio() => Audio(
      '原歌名',
      '原歌手',
      '原专辑',
      '原专辑艺术家',
      1,
      60,
      320,
      44100,
      r'D:\Music\Album\disc.flac::track=02::start=1000::end=201000',
      1,
      1,
      'test',
      disc: 1,
    );

    test('覆盖全部可编辑字段并刷新艺术家分割', () {
      final audio = buildAudio();

      audio.applyTrackOverride(
        const TrackOverride(
          trackUid: 'cue:d:/music/album/disc.flac#02',
          title: '新歌名',
          artist: '新歌手 / 合作者',
          album: '新专辑',
          albumArtist: '新专辑艺术家 / 共同艺术家',
          track: 5,
          disc: 2,
          updatedAt: 123,
        ),
      );

      expect(audio.title, '新歌名');
      expect(audio.artist, '新歌手 / 合作者');
      expect(audio.album, '新专辑');
      expect(audio.albumArtist, '新专辑艺术家 / 共同艺术家');
      expect(audio.track, 5);
      expect(audio.disc, 2);
      expect(audio.splitedArtists, ['新歌手', '合作者']);
      expect(audio.splitedAlbumArtists, ['新专辑艺术家', '共同艺术家']);
      expect(audio.matchesSearchQuery('新歌名'.toLowerCase()), isTrue);
    });

    test('空字段保留原值', () {
      final audio = buildAudio();

      audio.applyTrackOverride(
        const TrackOverride(
          trackUid: 'cue:d:/music/album/disc.flac#02',
          title: '只换歌名',
          updatedAt: 456,
        ),
      );

      expect(audio.title, '只换歌名');
      expect(audio.artist, '原歌手');
      expect(audio.album, '原专辑');
      expect(audio.albumArtist, '原专辑艺术家');
      expect(audio.track, 1);
      expect(audio.disc, 1);
    });
  });
}
