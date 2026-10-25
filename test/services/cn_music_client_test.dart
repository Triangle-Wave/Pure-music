import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/online_album/album_match.dart';
import 'package:pure_music/services/online_album/cn_music_client.dart';
import 'package:pure_music/services/online_album/online_album_service.dart';

void main() {
  group('国内专辑响应解析', () {
    test('网易专辑搜索解析封面、艺术家与曲目数', () {
      final albums = CnMusicClient.parseNeteaseAlbums({
        'result': {
          'albums': [
            {
              'id': 302184,
              'name': '范特西',
              'artist': {'name': '周杰伦'},
              'picUrl': 'http://p1.music.126.net/cover.jpg',
              'size': 10,
            },
          ],
        },
      });
      expect(albums, hasLength(1));
      final album = albums.single;
      expect(album.source, CnMusicSource.netease);
      expect(album.id, '302184');
      expect(album.title, '范特西');
      expect(album.artist, '周杰伦');
      expect(album.trackCount, 10);
      expect(album.coverUrl, 'https://p1.music.126.net/cover.jpg');
    });

    test('QQ 搜索歌曲结果聚合为专辑候选', () {
      final albums = CnMusicClient.parseQqAlbums({
        'req_0': {
          'data': {
            'body': {
              'item_song': [
                {
                  'title': '七里香',
                  'singer': [
                    {'name': '周杰伦'},
                  ],
                  'album': {'name': '七里香', 'mid': 'album-mid'},
                },
              ],
            },
          },
        },
      });
      expect(albums, hasLength(1));
      final album = albums.single;
      expect(album.source, CnMusicSource.qq);
      expect(album.title, '七里香');
      expect(album.artist, '周杰伦');
      expect(
        album.coverUrl,
        'https://y.gtimg.cn/music/photo_new/T002R800x800M000album-mid.jpg',
      );
    });

    test('酷狗专辑搜索解析曲目数并把封面升级为 https', () {
      final albums = CnMusicClient.parseKugouAlbums({
        'data': {
          'info': [
            {
              'albumid': 7788,
              'albumname': '范特西',
              'singername': '周杰伦',
              'imgurl': 'http://imge.kugou.com/stdmusic/{size}/cover.jpg',
              'songcount': 10,
            },
          ],
        },
      });
      expect(albums, hasLength(1));
      final album = albums.single;
      expect(album.source, CnMusicSource.kugou);
      expect(album.trackCount, 10);
      expect(
        album.coverUrl,
        'https://imge.kugou.com/stdmusic/480/cover.jpg',
      );
    });

    test('损坏或缺失字段不会抛异常', () {
      expect(CnMusicClient.parseNeteaseAlbums(null), isEmpty);
      expect(CnMusicClient.parseNeteaseAlbums({'result': 'bad'}), isEmpty);
      expect(CnMusicClient.parseQqAlbums({'req_0': 1}), isEmpty);
      expect(CnMusicClient.parseKugouAlbums(const []), isEmpty);
    });
  });

  group('国内歌手响应解析', () {
    test('网易歌手搜索保留头像地址', () {
      final artists = CnMusicClient.parseNeteaseArtists({
        'result': {
          'artists': [
            {
              'id': 6452,
              'name': '周杰伦',
              'picUrl': 'http://p1.music.126.net/artist.jpg',
              'albumSize': 38,
            },
          ],
        },
      });
      expect(artists, hasLength(1));
      final artist = artists.single;
      expect(artist.name, '周杰伦');
      expect(artist.picUrl, 'https://p1.music.126.net/artist.jpg');
      expect(artist.albumCount, 38);
    });

    test('QQ 歌手搜索兼容 camelCase 并用 mid 生成头像', () {
      final artists = CnMusicClient.parseQqArtists({
        'req_0': {
          'data': {
            'body': {
              'singer': {
                'list': [
                  {'singerName': '周杰伦', 'singerMid': 'singer-mid'},
                ],
              },
            },
          },
        },
      });
      expect(artists, hasLength(1));
      expect(
        artists.single.picUrl,
        'https://y.gtimg.cn/music/photo_new/T001R300x300M000singer-mid.jpg',
      );
    });

    test('酷狗歌手搜索解析头像', () {
      final artists = CnMusicClient.parseKugouArtists({
        'data': {
          'info': [
            {
              'singerid': 1,
              'singername': '周杰伦',
              'imgurl': 'http://imge.kugou.com/singer.jpg',
            },
          ],
        },
      });
      expect(artists, hasLength(1));
      expect(artists.single.picUrl, 'https://imge.kugou.com/singer.jpg');
    });
  });

  group('国内候选打分', () {
    const right = CnAlbumCandidate(
      source: CnMusicSource.qq,
      id: 'right',
      title: '范特西',
      artist: '周杰伦',
      trackCount: 10,
    );
    const wrongArtist = CnAlbumCandidate(
      source: CnMusicSource.qq,
      id: 'wrong',
      title: '范特西',
      artist: '其他歌手',
      trackCount: 10,
    );

    test('名称与艺术家匹配的候选胜出', () {
      final best = pickBestCnAlbumCandidate(
        albumTitle: '范特西',
        artist: '周杰伦',
        trackCount: 10,
        yearHint: null,
        candidates: const [wrongArtist, right],
      );
      expect(best?.id, 'right');
    });

    test('艺术家完全不匹配时宁可不返回', () {
      final best = pickBestCnAlbumCandidate(
        albumTitle: '范特西',
        artist: '周杰伦',
        trackCount: 10,
        yearHint: null,
        candidates: const [wrongArtist],
      );
      expect(best, isNull);
    });

    test('曲目数接近的候选得分更高', () {
      const exact = CnAlbumCandidate(
        source: CnMusicSource.netease,
        id: 'exact',
        title: '范特西',
        artist: '周杰伦',
        trackCount: 10,
      );
      const far = CnAlbumCandidate(
        source: CnMusicSource.netease,
        id: 'far',
        title: '范特西',
        artist: '周杰伦',
        trackCount: 30,
      );
      final exactScore = scoreCnAlbumCandidate(
        albumTitle: '范特西',
        artist: '周杰伦',
        trackCount: 10,
        yearHint: null,
        candidate: exact,
      );
      final farScore = scoreCnAlbumCandidate(
        albumTitle: '范特西',
        artist: '周杰伦',
        trackCount: 10,
        yearHint: null,
        candidate: far,
      );
      expect(exactScore, greaterThan(farScore));
      expect(exactScore, greaterThanOrEqualTo(minimumOnlineAlbumScore));
    });
  });

  group('艺术家名称匹配', () {
    const artist = CnArtistCandidate(
      source: CnMusicSource.netease,
      id: '1',
      name: '周杰伦',
      picUrl: 'https://p1.music.126.net/artist.jpg',
    );

    test('别名可以命中规范名', () {
      final best = pickBestArtistCandidate(
        name: '周董',
        candidates: const [artist],
        aliases: const {'周董': '周杰伦'},
      );
      expect(best?.id, '1');
    });

    test('带英文后缀的艺术家名仍视为同一人', () {
      final best = pickBestArtistCandidate(
        name: '周杰伦 Jay Chou',
        candidates: const [artist],
      );
      expect(best?.id, '1');
    });

    test('完全不同的艺术家不命中', () {
      final best = pickBestArtistCandidate(
        name: '五月天',
        candidates: const [artist],
      );
      expect(best, isNull);
    });

    test('没有头像的候选被忽略', () {
      final best = pickBestArtistCandidate(
        name: '周杰伦',
        candidates: const [
          CnArtistCandidate(
            source: CnMusicSource.qq,
            id: 'no-pic',
            name: '周杰伦',
          ),
        ],
      );
      expect(best, isNull);
    });
  });

  group('在线专辑来源序列化', () {
    test('旧缓存没有 source 时显示 MusicBrainz', () {
      final restored = OnlineAlbumInfo.fromJson({
        'releaseGroupId': 'mbid-1',
        'title': 'Abbey Road',
      });
      expect(restored, isNotNull);
      expect(restored!.sourceLabel, 'MusicBrainz');
    });

    test('国内来源往返保持显示名', () {
      const info = OnlineAlbumInfo(
        releaseGroupId: 'cn:netease:302184',
        title: '范特西',
        artist: '周杰伦',
        trackCount: 10,
        source: '网易云音乐',
      );
      final restored = OnlineAlbumInfo.fromJson(info.toJson());
      expect(restored?.sourceLabel, '网易云音乐');
      expect(restored?.trackCount, 10);
    });
  });
}
