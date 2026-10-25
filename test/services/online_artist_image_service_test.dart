import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/online_album/cn_music_client.dart';
import 'package:pure_music/services/online_album/online_artist_image_service.dart';

class _FakeCnMusicClient extends CnMusicClient {
  _FakeCnMusicClient(this.artists);

  final List<CnArtistCandidate> artists;
  int calls = 0;

  @override
  Future<List<CnArtistCandidate>> searchArtists({
    required String name,
    int limit = 8,
  }) async {
    calls++;
    return artists;
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

    test('没有候选时缓存空结果，避免重复搜索', () async {
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
      expect(secondClient.calls, 0);
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

      // 把缓存文件的修改时间改成 8 天前，模拟过期。
      final files = dir
          .listSync(recursive: true)
          .whereType<File>()
          .toList(growable: false);
      for (final file in files) {
        await file.setLastModified(
          now.subtract(const Duration(days: 8)),
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
  });
}
