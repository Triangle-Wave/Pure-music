import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/union_search_result.dart';

Audio _audio(
  String title,
  String path, {
  String artist = 'Artist',
  String album = 'Album',
}) => Audio(
  title,
  artist,
  album,
  null,
  1,
  60,
  320,
  44100,
  path,
  1,
  1,
  'test',
);

void main() {
  setUp(() {
    AudioLibrary.instance.dispose();
    AppSettings.instance.artistAliases = {};
  });

  tearDown(() {
    AppSettings.instance.artistAliases = {};
  });

  test('precomputed search matches title and pinyin initials', () {
    AudioLibrary.instance.audioCollection = [
      _audio('晴天', r'C:\Music\a.mp3'),
      _audio('Numb', r'C:\Music\b.mp3'),
    ];

    expect(UnionSearchResult.search('numb').audios.single.title, 'Numb');
    expect(UnionSearchResult.search('qt').audios.single.title, '晴天');
  });

  test('search finds one title among 10000 cached entries', () {
    AudioLibrary.instance.audioCollection = [
      for (var i = 0; i < 10000; i++)
        _audio('Track $i', 'C:\\Music\\$i.mp3'),
    ];
    final result = UnionSearchResult.search('track 9999');
    expect(result.audios.single.title, 'Track 9999');
  });

  test('search matches album and artist names', () {
    AudioLibrary.instance.audioCollection = [
      _audio('Instrumental', r'C:\Music\a.mp3', album: '告白'),
      _audio('Koi no Uta', r'C:\Music\b.mp3', artist: 'azusa'),
      _audio('Other', r'C:\Music\c.mp3'),
    ];

    expect(
      UnionSearchResult.search('告白').audios.single.title,
      'Instrumental',
    );
    expect(
      UnionSearchResult.search('azusa').audios.single.title,
      'Koi no Uta',
    );
  });

  test(
    'album and artist matches support pinyin initials and full pinyin',
    () {
      AudioLibrary.instance.audioCollection = [
        _audio('Instrumental', r'C:\Music\a.mp3', album: '告白'),
      ];

      expect(
        UnionSearchResult.search('gb').audios.single.title,
        'Instrumental',
      );
      expect(
        UnionSearchResult.search('gaobai').audios.single.title,
        'Instrumental',
      );
    },
  );

  test('album and artist tabs match full pinyin and initials', () {
    AudioLibrary.instance.artistCollection = {
      '告白': Artist(name: '告白'),
    };
    AudioLibrary.instance.albumCollection = {
      '告白': Album(name: '告白'),
    };

    expect(
      UnionSearchResult.search('gaobai', scope: SearchScope.album)
          .album
          .single
          .name,
      '告白',
    );
    expect(
      UnionSearchResult.search(
        'gb',
        scope: SearchScope.album,
      ).album.single.name,
      '告白',
    );
    expect(
      UnionSearchResult.search('gaobai', scope: SearchScope.artist)
          .artists
          .single
          .name,
      '告白',
    );
  });

  test('artist search matches a linked member name', () {
    AppSettings.instance.artistAliases = {'夜遊': 'YOASOBI'};
    AudioLibrary.instance.artistCollection = {
      'YOASOBI': Artist(name: 'YOASOBI'),
    };

    expect(
      UnionSearchResult.search(
        '夜遊',
        scope: SearchScope.artist,
      ).artists.single.name,
      'YOASOBI',
    );
  });

  test('title matches come before album and artist matches', () {
    AudioLibrary.instance.audioCollection = [
      _audio('Album Hit', r'C:\Music\a.mp3', album: '告白'),
      _audio('告白', r'C:\Music\b.mp3', album: 'Other'),
      _audio('Artist Hit', r'C:\Music\c.mp3', artist: '告白'),
    ];

    final titles = UnionSearchResult.search(
      '告白',
    ).audios.map((audio) => audio.title).toList();

    expect(titles, ['告白', 'Album Hit', 'Artist Hit']);
  });

  test('a track matching both title and album appears once', () {
    AudioLibrary.instance.audioCollection = [
      _audio('告白', r'C:\Music\a.mp3', album: '告白'),
    ];

    expect(UnionSearchResult.search('告白').audios.length, 1);
  });

  test('search without scope returns music artist and album together', () {
    AudioLibrary.instance.audioCollection = [
      _audio('告白', r'C:\Music\a.mp3'),
    ];
    AudioLibrary.instance.artistCollection = {
      '告白': Artist(name: '告白'),
    };
    AudioLibrary.instance.albumCollection = {
      '告白': Album(name: '告白'),
    };

    final result = UnionSearchResult.search('告白');
    expect(result.audios, isNotEmpty);
    expect(result.artists, isNotEmpty);
    expect(result.album, isNotEmpty);
  });

  test('mixedItems merges three kinds into one list', () {
    AudioLibrary.instance.audioCollection = [
      _audio('告白', r'C:\Music\a.mp3'),
    ];
    AudioLibrary.instance.artistCollection = {
      '告白': Artist(name: '告白'),
    };
    AudioLibrary.instance.albumCollection = {
      '告白': Album(name: '告白'),
    };

    final items = UnionSearchResult.search('告白').mixedItems;
    expect(items.length, 3);
    expect(
      items.map((item) => item.kind).toSet(),
      <UnionSearchItemKind>{
        UnionSearchItemKind.music,
        UnionSearchItemKind.artist,
        UnionSearchItemKind.album,
      },
    );
  });

  test('mixedItems returns empty for an empty query even with data', () {
    final result = UnionSearchResult('');
    result.audios = [_audio('告白', r'C:\Music\a.mp3')];
    result.artists = [Artist(name: '告白')];
    result.album = [Album(name: '告白')];

    expect(result.mixedItems, isEmpty);
    expect(
      rankUnionSearchItems(
        audios: result.audios,
        artists: result.artists,
        albums: result.album,
        query: '',
      ),
      isEmpty,
    );
  });

  test('rankUnionSearchItems puts rank 0 before rank 1', () {
    final items = rankUnionSearchItems(
      audios: [
        _audio('Instrumental', r'C:\Music\a.mp3', album: '告白'),
      ],
      artists: [Artist(name: '告白')],
      albums: [Album(name: '精选告白')],
      query: '告白',
    );

    expect(items.length, 3);
    final ranks = items.map((item) => item.rank).toList();
    expect(ranks, <int>[0, 1, 1]);
    expect(ranks.first, 0);
    expect(ranks.last, 1);
  });

  test('rankUnionSearchItems breaks ties by sortKey then kind order', () {
    final items = rankUnionSearchItems(
      audios: [_audio('告白', r'C:\Music\a.mp3')],
      artists: [Artist(name: '告白')],
      albums: [Album(name: '告白')],
      query: '告白',
    );

    expect(
      items.map((item) => item.kind).toList(),
      <UnionSearchItemKind>[
        UnionSearchItemKind.music,
        UnionSearchItemKind.artist,
        UnionSearchItemKind.album,
      ],
    );
  });

  test('rankUnionSearchItems keeps the original audio index', () {
    final unmatched = _audio('Other', r'C:\Music\a.mp3', album: 'Nope');
    final matched = _audio('告白', r'C:\Music\b.mp3');
    final items = rankUnionSearchItems(
      audios: [unmatched, matched],
      artists: const <Artist>[],
      albums: const <Album>[],
      query: '告白',
    );

    expect(items.length, 1);
    expect(items.single.audioIndex, 1);
    expect(identical(items.single.audio, matched), isTrue);
  });

  test('simplified query matches traditional title artist and album', () {
    AudioLibrary.instance.audioCollection = [
      _audio('再見', r'C:\Music\a.mp3',
          artist: '鄧紫棋', album: '我的電台'),
    ];
    AudioLibrary.instance.artistCollection = {
      '鄧紫棋': Artist(name: '鄧紫棋'),
    };
    AudioLibrary.instance.albumCollection = {
      '我的電台': Album(name: '我的電台'),
    };

    final result = UnionSearchResult.search('再见');
    expect(result.audios.single.title, '再見');
    expect(result.artists.single.name, '鄧紫棋');
    expect(result.album.single.name, '我的電台');
  });

  test('traditional query matches simplified title', () {
    AudioLibrary.instance.audioCollection = [
      _audio('再见', r'C:\Music\a.mp3'),
    ];

    expect(UnionSearchResult.search('再見').audios.single.title, '再见');
  });

  test('simplified query rank equals traditional title rank', () {
    final items = rankUnionSearchItems(
      audios: [_audio('再見', r'C:\Music\a.mp3')],
      artists: const <Artist>[],
      albums: const <Album>[],
      query: '再见',
    );

    expect(items.single.rank, 0);
    expect(items.single.sortKey, '再见');
  });

  test('traditional title supports pinyin search', () {
    AudioLibrary.instance.audioCollection = [
      _audio('再見', r'C:\Music\a.mp3'),
    ];

    expect(UnionSearchResult.search('zaijian').audios.single.title, '再見');
    expect(UnionSearchResult.search('zj').audios.single.title, '再見');
  });
}
