import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/services/online_album/cover_art_client.dart';
import 'package:pure_music/services/online_album/musicbrainz_client.dart';
import 'package:pure_music/services/online_album/online_album_service.dart';

void main() {
  group('专辑名称与年份匹配', () {
    test('归一化忽略版本后缀与标点', () {
      expect(normalizeForMatch('Abbey Road (Remastered 2009)'), 'abbey road');
      expect(
        normalizeForMatch('OK Computer [Collector\'s Edition]'),
        'ok computer',
      );
      expect(normalizeForMatch('范特西'), '范特西');
    });

    test('版本后缀不影响标题相似度', () {
      expect(
        albumTitleSimilarity('Abbey Road', 'Abbey Road (Remastered)'),
        1.0,
      );
      expect(
        albumTitleSimilarity('Abbey Road', 'Let It Be'),
        lessThan(0.5),
      );
    });

    test('年份提示取文本中最后一个合理年份', () {
      expect(extractYearHintFromTexts(['Album 1969 2009 Remaster']), 2009);
      expect(extractYearHintFromTexts(['D:/Music/Abbey Road (1969)/01.flac']), 1969);
      expect(extractYearHintFromTexts(['No year here']), isNull);
      expect(extractYearHintFromTexts(['Track 1234']), isNull);
    });
  });

  group('候选打分', () {
    const exact = MbReleaseGroup(
      id: 'g1',
      title: 'Abbey Road',
      score: 100,
      primaryType: 'Album',
      secondaryTypes: [],
      firstReleaseDate: '1969-09-26',
      disambiguation: '',
      artistNames: ['The Beatles'],
      genres: ['rock'],
      tags: [],
    );
    const wrongYearAndArtist = MbReleaseGroup(
      id: 'g2',
      title: 'Abbey Road',
      score: 90,
      primaryType: 'Album',
      secondaryTypes: [],
      firstReleaseDate: '2001-01-01',
      disambiguation: '',
      artistNames: ['Some Tribute Band'],
      genres: [],
      tags: [],
    );

    test('名称、艺术家、年份与曲目数都匹配时得分最高', () {
      final matched = scoreReleaseGroupCandidate(
        albumTitle: 'Abbey Road',
        artist: 'The Beatles',
        trackCount: 17,
        yearHint: 1969,
        group: exact,
        candidateTrackCount: 17,
      );
      final mismatched = scoreReleaseGroupCandidate(
        albumTitle: 'Abbey Road',
        artist: 'The Beatles',
        trackCount: 17,
        yearHint: 1969,
        group: wrongYearAndArtist,
        candidateTrackCount: 12,
      );
      expect(matched, greaterThan(mismatched));
      expect(matched, greaterThanOrEqualTo(minimumOnlineAlbumScore));
      expect(mismatched, lessThan(minimumOnlineAlbumScore));
    });

    test('曲目数接近的发行版优先', () {
      const near = MbRelease(
        id: 'near',
        title: 'Abbey Road',
        date: '1969-09-26',
        status: 'Official',
        trackCount: 17,
        genres: [],
        tags: [],
      );
      const far = MbRelease(
        id: 'far',
        title: 'Abbey Road',
        date: '1969-09-26',
        status: 'Official',
        trackCount: 10,
        genres: [],
        tags: [],
      );
      expect(pickBestRelease([far, near], 17)?.id, 'near');
      expect(pickBestRelease([far, near], 10)?.id, 'far');
    });
  });

  group('MusicBrainz 响应解析', () {
    test('解析 release-group 搜索结果的艺术家与风格', () {
      final groups = MbReleaseGroup.listFromJson([
        {
          'id': 'mbid-1',
          'title': 'Abbey Road',
          'score': 100,
          'primary-type': 'Album',
          'secondary-types': ['Live'],
          'first-release-date': '1969-09-26',
          'artist-credit': [
            {'name': 'The Beatles'},
            {'name': 'Billy Preston'},
          ],
          'genres': [
            {'name': 'rock', 'count': 4},
          ],
        },
      ]);
      expect(groups, hasLength(1));
      final group = groups.single;
      expect(group.id, 'mbid-1');
      expect(group.artistNames, const ['The Beatles', 'Billy Preston']);
      expect(group.secondaryTypes, const ['Live']);
      expect(group.genres, const ['rock']);
      expect(group.firstReleaseDate, '1969-09-26');
    });

    test('解析发行版列表的曲目数', () {
      final releases = MbRelease.listFromJson([
        {
          'id': 'release-1',
          'title': 'Abbey Road',
          'status': 'Official',
          'date': '1969-09-26',
          'track-count': 17,
        },
      ]);
      expect(releases.single.trackCount, 17);
    });
  });

  group('Cover Art Archive 解析', () {
    test('识别 front/back/booklet 并优先 500 缩略图', () {
      final set = CoverArtSet.fromJson({
        'images': [
          {
            'types': ['Front'],
            'front': true,
            'back': false,
            'image': 'https://img/front-original.jpg',
            'thumbnails': {
              '250': 'https://img/front-250.jpg',
              '500': 'https://img/front-500.jpg',
              'large': 'https://img/front-large.jpg',
              '1200': 'https://img/front-1200.jpg',
            },
          },
          {
            'types': ['Back'],
            'front': false,
            'back': true,
            'image': 'https://img/back.jpg',
            'thumbnails': {'large': 'https://img/back-large.jpg'},
          },
          {
            'types': ['Booklet'],
            'front': false,
            'back': false,
            'image': 'https://img/booklet.jpg',
            'thumbnails': {'250': 'https://img/booklet-250.jpg'},
          },
        ],
      });
      expect(set.front?.url, 'https://img/front-500.jpg');
      expect(set.front?.largeUrl, 'https://img/front-1200.jpg');
      expect(set.back?.url, 'https://img/back-large.jpg');
      expect(set.booklets, hasLength(1));
      expect(set.booklets.single.url, 'https://img/booklet-250.jpg');
      expect(set.isEmpty, isFalse);
    });

    test('没有图片时返回空集合', () {
      expect(CoverArtSet.fromJson({'images': []}).isEmpty, isTrue);
      expect(CoverArtSet.fromJson(null).isEmpty, isTrue);
    });

    test('合并 release 与 release-group 时补齐正反面并去重内页', () {
      const first = CoverArtSet(
        front: CoverArtImage(
          url: 'https://img/front.jpg',
          largeUrl: null,
          front: true,
          back: false,
          types: ['front'],
        ),
        booklets: [
          CoverArtImage(
            url: 'https://img/booklet-1.jpg',
            largeUrl: null,
            front: false,
            back: false,
            types: ['booklet'],
          ),
        ],
      );
      const second = CoverArtSet(
        back: CoverArtImage(
          url: 'https://img/back.jpg',
          largeUrl: null,
          front: false,
          back: true,
          types: ['back'],
        ),
        booklets: [
          CoverArtImage(
            url: 'https://img/booklet-1.jpg',
            largeUrl: null,
            front: false,
            back: false,
            types: ['booklet'],
          ),
          CoverArtImage(
            url: 'https://img/booklet-2.jpg',
            largeUrl: null,
            front: false,
            back: false,
            types: ['booklet'],
          ),
        ],
      );
      final merged = CoverArtSet.merge(first, second);
      expect(merged.front?.url, 'https://img/front.jpg');
      expect(merged.back?.url, 'https://img/back.jpg');
      expect(merged.booklets, hasLength(2));
    });
  });

  group('缓存与序列化', () {
    test('在线专辑信息 JSON 往返保持封面顺序', () {
      const info = OnlineAlbumInfo(
        releaseGroupId: 'mbid-1',
        title: 'Abbey Road',
        artist: 'The Beatles',
        year: 1969,
        label: 'Apple',
        genre: 'rock',
        summary: 'Album · 1969-09-26',
        trackCount: 17,
        covers: CoverArtSet(
          front: CoverArtImage(
            url: 'https://img/front.jpg',
            largeUrl: null,
            front: true,
            back: false,
            types: ['front'],
          ),
          booklets: [
            CoverArtImage(
              url: 'https://img/booklet.jpg',
              largeUrl: null,
              front: false,
              back: false,
              types: ['booklet'],
            ),
          ],
        ),
      );
      final restored = OnlineAlbumInfo.fromJson(info.toJson());
      expect(restored, isNotNull);
      final value = restored!;
      expect(value.title, 'Abbey Road');
      expect(value.covers.front?.url, 'https://img/front.jpg');
      expect(value.artworks.map((e) => e.role), const ['front', 'booklet']);
      expect(value.artworks.first.label, '封面');
    });

    test('缓存键对同一专辑稳定，对不同专辑区分', () {
      final service = OnlineAlbumService.instance;
      final first = service.cacheKeyForAlbum(Album(name: 'Abbey Road'));
      final same = service.cacheKeyForAlbum(Album(name: 'Abbey Road'));
      final other = service.cacheKeyForAlbum(Album(name: 'Let It Be'));
      expect(first, same);
      expect(first, isNot(other));
      expect(first, hasLength(40));
    });
  });
}
