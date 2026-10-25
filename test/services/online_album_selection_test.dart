import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/services/online_album/cn_music_client.dart';
import 'package:pure_music/services/online_album/musicbrainz_client.dart';
import 'package:pure_music/services/online_album/online_album_service.dart';

class _FakeCnMusicClient extends CnMusicClient {
  _FakeCnMusicClient(this.albums, {this.fail = false});

  final List<CnAlbumCandidate> albums;
  final bool fail;
  int calls = 0;

  @override
  Future<List<CnAlbumCandidate>> searchAlbums({
    required String title,
    required String artist,
    int limit = 8,
  }) async {
    calls++;
    if (fail) throw StateError('offline');
    return albums;
  }
}

class _FakeMusicBrainzClient extends MusicBrainzClient {
  _FakeMusicBrainzClient({this.fail = false});

  final bool fail;
  int calls = 0;

  @override
  Future<List<MbReleaseGroup>> searchReleaseGroups({
    required String release,
    required String artist,
    int limit = 8,
  }) async {
    calls++;
    if (fail) throw MusicBrainzException('offline');
    return const [];
  }
}

Album _abbeyRoad({int trackCount = 17}) {
  final album = Album(name: 'Abbey Road');
  for (var i = 1; i <= trackCount; i++) {
    album.works.add(
      Audio(
        'Track $i',
        'The Beatles',
        'Abbey Road',
        'The Beatles',
        i,
        200,
        320,
        44100,
        'G:/Music/Abbey Road/$i.flac',
        0,
        0,
        null,
      ),
    );
  }
  return album;
}

const _netease = CnAlbumCandidate(
  source: CnMusicSource.netease,
  id: '1',
  title: 'Abbey Road',
  artist: 'The Beatles',
  coverUrl: 'https://p1.music.126.net/cover.jpg',
  trackCount: 17,
  year: 1969,
);

const _qq = CnAlbumCandidate(
  source: CnMusicSource.qq,
  id: '2',
  title: 'Abbey Road',
  artist: 'The Beatles',
  coverUrl: 'https://y.gtimg.cn/cover.jpg',
  trackCount: 17,
  year: 1969,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('专辑候选持久化', () {
    test('查询写入全部候选并默认使用最佳候选', () async {
      final dir = await Directory.systemTemp.createTemp('pure_music_album');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final client = _FakeCnMusicClient(const [_netease, _qq]);
      final service = OnlineAlbumService.createForTest(
        cnMusic: client,
        appDataDirectory: () async => dir,
        clock: () => DateTime(2026, 10, 25, 12),
      );
      final album = _abbeyRoad();
      final cache = await service.loadCandidates(album);
      expect(cache, isNotNull);
      expect(cache!.candidates, hasLength(2));
      expect(cache.info?.title, 'Abbey Road');
      expect(cache.selectedCandidateId, isNull);
      expect(cache.disabled, isFalse);

      final file = File(
        p.join(
          dir.path,
          'online_album',
          'candidates',
          '${service.cacheKeyForAlbum(album)}.json',
        ),
      );
      expect(await file.exists(), isTrue);
      final json = jsonDecode(await file.readAsString());
      expect(json, isA<Map<String, dynamic>>());
      final payload = json as Map<String, dynamic>;
      expect(payload['candidates'], hasLength(2));
      expect(payload['selectedCandidateId'], isNull);
      expect(payload['disabled'], isFalse);
      final first = (payload['candidates'] as List<dynamic>).first;
      expect(first['source'], isNotEmpty);
      expect(first['imageUrl'], isNotNull);
      expect(first['info'], isA<Map<String, dynamic>>());
    });

    test('选择候选后重启仍使用该候选且不重新请求', () async {
      final dir = await Directory.systemTemp.createTemp('pure_music_album');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final first = OnlineAlbumService.createForTest(
        cnMusic: _FakeCnMusicClient(const [_netease, _qq]),
        appDataDirectory: () async => dir,
      );
      final album = _abbeyRoad();
      await first.loadCandidates(album);
      await first.updateSelection(album, candidateId: 'cn:qq:2');

      final secondClient = _FakeCnMusicClient(const []);
      final second = OnlineAlbumService.createForTest(
        cnMusic: secondClient,
        appDataDirectory: () async => dir,
      );
      final cache = await second.loadCandidates(album);
      expect(cache!.selectedCandidateId, 'cn:qq:2');
      expect(cache.activeCandidate?.source, 'QQ 音乐');
      expect(cache.info?.covers.front?.url, 'https://y.gtimg.cn/cover.jpg');
      expect(secondClient.calls, 0);
    });

    test('选择不使用后不发请求且不返回在线信息', () async {
      final dir = await Directory.systemTemp.createTemp('pure_music_album');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final first = OnlineAlbumService.createForTest(
        cnMusic: _FakeCnMusicClient(const [_netease]),
        appDataDirectory: () async => dir,
      );
      final album = _abbeyRoad();
      await first.loadCandidates(album);
      await first.updateSelection(album, disabled: true);

      final secondClient = _FakeCnMusicClient(const [_netease]);
      final second = OnlineAlbumService.createForTest(
        cnMusic: secondClient,
        appDataDirectory: () async => dir,
      );
      expect(await second.lookup(album), isNull);
      expect(secondClient.calls, 0);
      final cache = await second.loadCandidates(album);
      expect(cache!.disabled, isTrue);
      expect(cache.info, isNull);
    });

    test('缓存损坏时删除文件并重新查询', () async {
      final dir = await Directory.systemTemp.createTemp('pure_music_album');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final client = _FakeCnMusicClient(const [_netease]);
      final service = OnlineAlbumService.createForTest(
        cnMusic: client,
        appDataDirectory: () async => dir,
      );
      final album = _abbeyRoad();
      await service.loadCandidates(album);
      final file = File(
        p.join(
          dir.path,
          'online_album',
          'candidates',
          '${service.cacheKeyForAlbum(album)}.json',
        ),
      );
      await file.writeAsString('{broken json');

      final freshClient = _FakeCnMusicClient(const [_netease]);
      final fresh = OnlineAlbumService.createForTest(
        cnMusic: freshClient,
        appDataDirectory: () async => dir,
      );
      final cache = await fresh.loadCandidates(album);
      expect(freshClient.calls, 1);
      expect(cache!.candidates, hasLength(1));
      expect(await file.exists(), isTrue);
      expect(
        jsonDecode(await file.readAsString()),
        isA<Map<String, dynamic>>(),
      );
    });

    test('网络失败时回退已有缓存', () async {
      final dir = await Directory.systemTemp.createTemp('pure_music_album');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final album = _abbeyRoad();
      final first = OnlineAlbumService.createForTest(
        cnMusic: _FakeCnMusicClient(const [_netease]),
        appDataDirectory: () async => dir,
      );
      await first.loadCandidates(album);

      final failingCn = _FakeCnMusicClient(const [], fail: true);
      final failingMb = _FakeMusicBrainzClient(fail: true);
      final second = OnlineAlbumService.createForTest(
        cnMusic: failingCn,
        musicBrainz: failingMb,
        appDataDirectory: () async => dir,
      );
      final cache = await second.loadCandidates(album, force: true);
      expect(failingCn.calls, 1);
      expect(failingMb.calls, 1);
      expect(cache!.candidates, hasLength(1));
      expect(cache.info?.title, 'Abbey Road');
    });

    test('低分候选不自动展示，但可以手动选择', () async {
      final dir = await Directory.systemTemp.createTemp('pure_music_album');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      const weak = CnAlbumCandidate(
        source: CnMusicSource.kugou,
        id: '9',
        title: 'Abbey Road Tribute',
        artist: 'Unknown Band',
        coverUrl: 'https://img.kugou.com/cover.jpg',
        trackCount: 4,
        year: 2015,
      );
      final service = OnlineAlbumService.createForTest(
        cnMusic: _FakeCnMusicClient(const [weak]),
        musicBrainz: _FakeMusicBrainzClient(),
        appDataDirectory: () async => dir,
      );
      final album = _abbeyRoad();
      final cache = await service.loadCandidates(album);
      expect(cache!.candidates, hasLength(1));
      expect(cache.info, isNull);

      await service.updateSelection(
        album,
        candidateId: 'cn:kugou:9',
      );
      final selected = await service.loadCandidates(album);
      expect(selected!.info?.title, 'Abbey Road Tribute');
    });
  });
}
