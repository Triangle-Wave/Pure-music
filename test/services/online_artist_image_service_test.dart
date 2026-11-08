import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:pure_music/services/online_album/album_match.dart';
import 'package:pure_music/services/online_album/cn_music_client.dart';
import 'package:pure_music/services/online_album/online_album_models.dart';
import 'package:pure_music/services/online_album/online_artist_image_service.dart';

class _FakeCnMusicClient extends CnMusicClient {
  _FakeCnMusicClient(
    this.artists, {
    this.byName = const <String, List<CnArtistCandidate>>{},
  });

  final List<CnArtistCandidate> artists;

  /// 按搜索词返回不同候选；未命中时回退到 [artists]。
  final Map<String, List<CnArtistCandidate>> byName;
  int calls = 0;

  /// 依次记录每次搜索收到的关键词。
  final List<String> names = <String>[];

  @override
  Future<List<CnArtistCandidate>> searchArtists({
    required String name,
    int limit = 8,
  }) async {
    calls++;
    names.add(name);
    return byName[name] ?? artists;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('艺术家头像缓存', () {
    test('命中结果写入磁盘并在新实例中复用', () async {
      final dir = await Directory.systemTemp.createTemp('pure_music_artist');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      const candidate = CnArtistCandidate(
        source: CnMusicSource.netease,
        id: '1',
        name: '周杰伦',
        picUrl: 'https://p1.music.126.net/artist.jpg',
      );
      final firstClient = _FakeCnMusicClient(const [candidate]);
      var downloads = 0;
      final first = OnlineArtistImageService.createForTest(
        cnMusic: firstClient,
        appDataDirectory: () async => dir,
        artworkLoader: (String url) async {
          downloads++;
          return null;
        },
      );
      await first.imageFor('周杰伦');
      expect(firstClient.calls, 1);
      expect(downloads, 1);

      final secondClient = _FakeCnMusicClient(const [candidate]);
      final second = OnlineArtistImageService.createForTest(
        cnMusic: secondClient,
        appDataDirectory: () async => dir,
        artworkLoader: (String url) async {
          downloads++;
          return null;
        },
      );
      await second.imageFor('周杰伦');
      expect(secondClient.calls, 0);
      expect(downloads, 2);
    });

    test('空结果不会阻止下次重新搜索', () async {
      final dir = await Directory.systemTemp.createTemp('pure_music_artist');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final firstClient = _FakeCnMusicClient(const []);
      final first = OnlineArtistImageService.createForTest(
        cnMusic: firstClient,
        appDataDirectory: () async => dir,
        artworkLoader: (String url) async => null,
      );
      expect(await first.imageFor('未知艺术家'), isNull);
      expect(firstClient.calls, 1);

      final secondClient = _FakeCnMusicClient(const []);
      final second = OnlineArtistImageService.createForTest(
        cnMusic: secondClient,
        appDataDirectory: () async => dir,
        artworkLoader: (String url) async => null,
      );
      expect(await second.imageFor('未知艺术家'), isNull);
      expect(secondClient.calls, 1);
    });

    test('过期缓存会重新搜索', () async {
      final dir = await Directory.systemTemp.createTemp('pure_music_artist');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final client = _FakeCnMusicClient(const []);
      final now = DateTime(2026, 10, 25, 12);
      final service = OnlineArtistImageService.createForTest(
        cnMusic: client,
        appDataDirectory: () async => dir,
        clock: () => now,
        artworkLoader: (String url) async => null,
      );
      await service.imageFor('未知艺术家');
      expect(client.calls, 1);

      // 把缓存文件的修改时间改成一年前，模拟过期。
      final files = dir
          .listSync(recursive: true)
          .whereType<File>()
          .toList(growable: false);
      for (final file in files) {
        await file.setLastModified(
          now.subtract(const Duration(days: 400)),
        );
      }
      final secondClient = _FakeCnMusicClient(const []);
      final second = OnlineArtistImageService.createForTest(
        cnMusic: secondClient,
        appDataDirectory: () async => dir,
        clock: () => now,
        artworkLoader: (String url) async => null,
      );
      expect(await second.imageFor('未知艺术家'), isNull);
      expect(secondClient.calls, 1);
    });

    test('图片加载器返回的 provider 会传给调用方', () async {
      final dir = await Directory.systemTemp.createTemp('pure_music_artist');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      const candidate = CnArtistCandidate(
        source: CnMusicSource.qq,
        id: '1',
        name: '周杰伦',
        picUrl: 'https://y.gtimg.cn/artist.jpg',
      );
      final provider = MemoryImage(Uint8List.fromList(const [1, 2, 3]));
      final service = OnlineArtistImageService.createForTest(
        cnMusic: _FakeCnMusicClient(const [candidate]),
        appDataDirectory: () async => dir,
        artworkLoader: (String url) async => provider,
      );
      expect(await service.imageFor('周杰伦'), same(provider));
    });

    test('选择的候选写入磁盘并在重启后沿用', () async {
      final dir = await Directory.systemTemp.createTemp('pure_music_artist');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      const netease = CnArtistCandidate(
        source: CnMusicSource.netease,
        id: '1',
        name: '周杰伦',
        picUrl: 'https://p1.music.126.net/artist.jpg',
      );
      const qq = CnArtistCandidate(
        source: CnMusicSource.qq,
        id: '2',
        name: '周杰伦',
        picUrl: 'https://y.gtimg.cn/artist.jpg',
      );
      final first = OnlineArtistImageService.createForTest(
        cnMusic: _FakeCnMusicClient(const [netease, qq]),
        appDataDirectory: () async => dir,
        artworkLoader: (String url) async => null,
      );
      final cache = await first.loadCandidates('周杰伦');
      expect(cache!.candidates, hasLength(2));
      await first.updateSelection(
        '周杰伦',
        candidateId: 'cn:qq:2',
      );

      final secondClient = _FakeCnMusicClient(const []);
      final second = OnlineArtistImageService.createForTest(
        cnMusic: secondClient,
        appDataDirectory: () async => dir,
        artworkLoader: (String url) async =>
            MemoryImage(Uint8List.fromList(const [1, 2, 3])),
      );
      final preferred = await second.preferredImageFor('周杰伦');
      expect(preferred, isNotNull);
      expect(secondClient.calls, 0);
      final restored = await second.loadCandidates('周杰伦');
      expect(restored!.selectedCandidateId, 'cn:qq:2');
    });

    test('选择不使用后不再发请求并返回空头像', () async {
      final dir = await Directory.systemTemp.createTemp('pure_music_artist');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      const candidate = CnArtistCandidate(
        source: CnMusicSource.netease,
        id: '1',
        name: '周杰伦',
        picUrl: 'https://p1.music.126.net/artist.jpg',
      );
      final first = OnlineArtistImageService.createForTest(
        cnMusic: _FakeCnMusicClient(const [candidate]),
        appDataDirectory: () async => dir,
        artworkLoader: (String url) async => null,
      );
      await first.loadCandidates('周杰伦');
      await first.updateSelection('周杰伦', disabled: true);

      final secondClient = _FakeCnMusicClient(const [candidate]);
      final second = OnlineArtistImageService.createForTest(
        cnMusic: secondClient,
        appDataDirectory: () async => dir,
        artworkLoader: (String url) async {
          fail('禁用后不应加载在线头像');
        },
      );
      expect(await second.imageFor('周杰伦'), isNull);
      expect(secondClient.calls, 0);
      expect(await second.preferredImageFor('周杰伦'), isNull);
    });

    test('改写搜索词时绕过缓存并带上新关键词', () async {
      final dir = await Directory.systemTemp.createTemp('pure_music_artist');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      const candidate = CnArtistCandidate(
        source: CnMusicSource.netease,
        id: '1',
        name: '周杰伦',
        picUrl: 'https://p1.music.126.net/artist.jpg',
      );
      final client = _FakeCnMusicClient(const [candidate]);
      final service = OnlineArtistImageService.createForTest(
        cnMusic: client,
        appDataDirectory: () async => dir,
        artworkLoader: (String url) async => null,
      );
      await service.loadCandidates('周杰伦');
      expect(client.calls, 1);
      expect(client.names.single, '周杰伦');

      final cache = await service.loadCandidates(
        '周杰伦',
        query: ' 周杰伦 Jay ',
      );
      expect(client.calls, 2);
      expect(client.names.last, '周杰伦 Jay');
      expect(cache, isNotNull);
      expect(cache!.searchQuery, '周杰伦 Jay');
      expect(
        cache.candidates.map((item) => item.name),
        contains('周杰伦'),
      );
    });

    test('括号显示名各自独立缓存与选择', () async {
      final dir = await Directory.systemTemp.createTemp('pure_music_artist');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      const kugimiya = CnArtistCandidate(
        source: CnMusicSource.netease,
        id: '11',
        name: 'cv.釘宮 理恵',
        picUrl: 'https://p1.music.126.net/kugimiya.jpg',
      );
      const asakawa = CnArtistCandidate(
        source: CnMusicSource.netease,
        id: '12',
        name: 'cv.浅川 悠',
        picUrl: 'https://p1.music.126.net/asakawa.jpg',
      );
      final client = _FakeCnMusicClient(
        const [],
        byName: const {
          '(cv.釘宮 理恵)': [kugimiya],
          '(cv.浅川 悠)': [asakawa],
        },
      );
      final loadedUrls = <String>[];
      final service = OnlineArtistImageService.createForTest(
        cnMusic: client,
        appDataDirectory: () async => dir,
        artworkLoader: (String url) async {
          loadedUrls.add(url);
          return null;
        },
      );

      final first = await service.loadCandidates('(cv.釘宮 理恵)');
      final second = await service.loadCandidates('(cv.浅川 悠)');
      expect(first!.candidates.single.imageUrl, kugimiya.picUrl);
      expect(second!.candidates.single.imageUrl, asakawa.picUrl);
      expect(
        service.cacheKeyForArtist('(cv.釘宮 理恵)'),
        isNot(service.cacheKeyForArtist('(cv.浅川 悠)')),
      );

      await service.updateSelection(
        '(cv.釘宮 理恵)',
        candidateId: first.candidates.single.id,
      );
      await service.updateSelection(
        '(cv.浅川 悠)',
        candidateId: second.candidates.single.id,
      );

      final firstRestored = await service.loadCandidates('(cv.釘宮 理恵)');
      final secondRestored = await service.loadCandidates('(cv.浅川 悠)');
      expect(firstRestored!.selectedCandidateId, first.candidates.single.id);
      expect(secondRestored!.selectedCandidateId, second.candidates.single.id);
      expect(
        firstRestored.selectedCandidateId,
        isNot(secondRestored.selectedCandidateId),
      );

      await service.preferredImageFor('(cv.釘宮 理恵)');
      await service.preferredImageFor('(cv.浅川 悠)');
      expect(loadedUrls, [kugimiya.picUrl, asakawa.picUrl]);
    });

    test('旧键缓存迁移到新键并保留选择', () async {
      final dir = await Directory.systemTemp.createTemp('pure_music_artist');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      const artistName = '(cv.釘宮 理恵)';
      const legacyCandidate = OnlineArtistCandidate(
        id: 'cn:netease:21',
        source: '网易云',
        name: 'cv.釘宮 理恵',
        imageUrl: 'https://p1.music.126.net/legacy-kugimiya.jpg',
        score: 1,
      );
      final legacyCache = OnlineArtistCandidateCache(
        candidates: const [legacyCandidate],
        selectedCandidateId: legacyCandidate.id,
        savedAt: DateTime(2026, 10, 1),
      );
      final cacheDirectory = Directory(
        path.join(dir.path, 'online_album', 'artist'),
      );
      await cacheDirectory.create(recursive: true);
      final legacyKey = sha1
          .convert(utf8.encode(normalizeForMatch(artistName)))
          .toString();
      final legacyFile = File(
        path.join(cacheDirectory.path, '$legacyKey.json'),
      );
      await legacyFile.writeAsString(jsonEncode(legacyCache.toJson()));
      final newKey = sha1.convert(utf8.encode(artistName.trim())).toString();
      final newFile = File(path.join(cacheDirectory.path, '$newKey.json'));
      expect(newKey, isNot(legacyKey));
      expect(await newFile.exists(), isFalse);

      final client = _FakeCnMusicClient(const []);
      final loadedUrls = <String>[];
      final service = OnlineArtistImageService.createForTest(
        cnMusic: client,
        appDataDirectory: () async => dir,
        artworkLoader: (String url) async {
          loadedUrls.add(url);
          return null;
        },
      );

      final loaded = await service.loadCandidates(artistName);
      expect(loaded!.selectedCandidateId, legacyCandidate.id);
      expect(client.calls, 0);
      expect(await newFile.exists(), isTrue);

      final migrated = OnlineArtistCandidateCache.fromJson(
        jsonDecode(await newFile.readAsString()),
      );
      expect(migrated!.selectedCandidateId, legacyCandidate.id);
      expect(migrated.candidates.single.id, legacyCandidate.id);
      expect(migrated.candidates.single.imageUrl, legacyCandidate.imageUrl);

      await service.preferredImageFor(artistName);
      expect(loadedUrls, [legacyCandidate.imageUrl]);
      expect(await legacyFile.exists(), isTrue);
    });
  });
}
