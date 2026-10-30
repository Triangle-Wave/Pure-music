import 'package:flutter_test/flutter_test.dart';
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
}
