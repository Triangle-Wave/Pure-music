import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';

Audio _audio(
  String title,
  String path, {
  required String artist,
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
    AppPreference.instance.audiosPagePref = PagePreference(
      0,
      SortOrder.ascending,
      ContentView.list,
    );
    AppPreference.instance.artistsPagePref = PagePreference(
      0,
      SortOrder.ascending,
      ContentView.table,
    );
    AppPreference.instance.albumsPagePref = PagePreference(
      0,
      SortOrder.ascending,
      ContentView.table,
    );
  });

  tearDown(() {
    AppSettings.instance.artistAliases = {};
  });

  test('linked names merge into one artist entry', () {
    AppSettings.instance.artistAliases = {'夜遊': 'YOASOBI'};
    final library = AudioLibrary.instance;

    library.replaceFolders([
      AudioFolder(
        [
          _audio('First', r'C:\Music\a.mp3', artist: '夜遊'),
          _audio('Second', r'C:\Music\b.mp3', artist: 'YOASOBI'),
        ],
        r'C:\Music',
        1,
        1,
      ),
    ]);

    expect(library.artistCollection.keys, ['YOASOBI']);
    expect(library.artistCollection['YOASOBI']!.works, hasLength(2));
    expect(library.artistCollection.containsKey('夜遊'), isFalse);
  });

  test('an empty old name disappears after rebuilding the collection', () {
    AppSettings.instance.artistAliases = {'夜遊': 'YOASOBI'};
    final library = AudioLibrary.instance;

    library.replaceFolders([
      AudioFolder(
        [_audio('Only', r'C:\Music\a.mp3', artist: '夜遊')],
        r'C:\Music',
        1,
        1,
      ),
    ]);
    expect(library.artistCollection.containsKey('夜遊'), isFalse);

    AppSettings.instance.artistAliases = {};
    library.replaceFolders([]);

    expect(library.artistCollection, isEmpty);
  });

  test('renaming the group removes the previous display name', () {
    AppSettings.instance.artistAliases = {'夜遊': 'YOASOBI'};
    final library = AudioLibrary.instance;

    library.replaceFolders([
      AudioFolder(
        [_audio('First', r'C:\Music\a.mp3', artist: '夜遊')],
        r'C:\Music',
        1,
        1,
      ),
    ]);

    AppSettings.instance.artistAliases = {'夜遊': 'Yoru', 'YOASOBI': 'Yoru'};
    library.replaceFolders([
      AudioFolder(
        [
          _audio('First', r'D:\Music\a.mp3', artist: '夜遊'),
          _audio('Second', r'D:\Music\b.mp3', artist: 'YOASOBI'),
        ],
        r'D:\Music',
        2,
        2,
      ),
    ]);

    expect(library.artistCollection.keys, ['Yoru']);
    expect(library.artistCollection['Yoru']!.works, hasLength(2));
    expect(library.artistCollection.containsKey('YOASOBI'), isFalse);
  });
}
