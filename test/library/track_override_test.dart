import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/cue_segment_path.dart';
import 'package:pure_music/library/track_override.dart';
import 'package:sqlite3/sqlite3.dart';

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

    test('扩展字段保留在 virtualOverride 供详情页展示', () {
      final audio = buildAudio();
      const override = TrackOverride(
        trackUid: 'cue:d:/music/album/disc.flac#02',
        genre: 'Jazz',
        year: '2001',
        trackTotal: 12,
        discTotal: 2,
        composer: '作曲',
        bpm: '128.5',
        language: 'zh',
        updatedAt: 1,
      );

      audio.applyTrackOverride(override);

      expect(audio.virtualOverride, same(override));
      expect(audio.virtualOverride?.genre, 'Jazz');
      expect(audio.virtualOverride?.year, '2001');
      expect(audio.virtualOverride?.trackTotal, 12);
      expect(audio.virtualOverride?.discTotal, 2);
      expect(audio.virtualOverride?.composer, '作曲');
      expect(audio.virtualOverride?.bpm, '128.5');
      expect(audio.virtualOverride?.language, 'zh');
    });
  });

  group('TrackOverrideStore', () {
    late Database database;
    late TrackOverrideStore store;

    setUp(() {
      database = sqlite3.openInMemory();
      final optionalColumns = trackOverrideOptionalColumns.entries
          .map((entry) => '${entry.key} ${entry.value}')
          .join(',\n  ');
      database.execute('''
CREATE TABLE track_overrides (
  track_uid TEXT PRIMARY KEY,
  title TEXT,
  artist TEXT,
  album TEXT,
  album_artist TEXT,
  track INTEGER,
  disc INTEGER,
  updated_at INTEGER NOT NULL,
  $optionalColumns
);
''');
      store = TrackOverrideStore.withDatabase(() async => database);
    });

    tearDown(() {
      database.dispose();
    });

    TrackOverride buildOverride() => const TrackOverride(
      trackUid: 'cue:d:/music/disc.flac#02',
      title: '标题',
      artist: '歌手',
      album: '专辑',
      albumArtist: '专辑艺术家',
      track: 2,
      disc: 1,
      genre: 'Jazz',
      year: '2001',
      trackTotal: 12,
      discTotal: 2,
      composer: '作曲',
      lyricist: '作词',
      label: '厂牌',
      comment: '注释',
      bpm: '128.5',
      language: 'zh',
      copyright: '版权',
      license: 'CC BY',
      updatedAt: 789,
    );

    test('保存后读取全部字段', () async {
      final override = buildOverride();

      await store.save(override);
      final loaded = (await store.loadAll())[override.trackUid];

      expect(loaded, isNotNull);
      expect(loaded!.title, '标题');
      expect(loaded.artist, '歌手');
      expect(loaded.album, '专辑');
      expect(loaded.albumArtist, '专辑艺术家');
      expect(loaded.track, 2);
      expect(loaded.disc, 1);
      expect(loaded.genre, 'Jazz');
      expect(loaded.year, '2001');
      expect(loaded.trackTotal, 12);
      expect(loaded.discTotal, 2);
      expect(loaded.composer, '作曲');
      expect(loaded.lyricist, '作词');
      expect(loaded.label, '厂牌');
      expect(loaded.comment, '注释');
      expect(loaded.bpm, '128.5');
      expect(loaded.language, 'zh');
      expect(loaded.copyright, '版权');
      expect(loaded.license, 'CC BY');
      expect(loaded.updatedAt, 789);
    });

    test('同主键再次保存时更新扩展字段并清空未设置字段', () async {
      await store.save(buildOverride());

      await store.save(
        const TrackOverride(
          trackUid: 'cue:d:/music/disc.flac#02',
          title: '新标题',
          genre: 'Rock',
          trackTotal: 9,
          bpm: '90',
          updatedAt: 1000,
        ),
      );
      final loaded = (await store.loadAll())['cue:d:/music/disc.flac#02'];

      expect(loaded, isNotNull);
      expect(loaded!.title, '新标题');
      expect(loaded.genre, 'Rock');
      expect(loaded.trackTotal, 9);
      expect(loaded.bpm, '90');
      expect(loaded.year, isNull);
      expect(loaded.discTotal, isNull);
      expect(loaded.composer, isNull);
      expect(loaded.license, isNull);
      expect(loaded.updatedAt, 1000);
    });

    test('remove 删除覆盖记录', () async {
      await store.save(buildOverride());

      await store.remove('cue:d:/music/disc.flac#02');

      expect(await store.loadAll(), isEmpty);
    });
  });
}
