import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';

const String _containerPath = r'C:\Music\album.tak';
const String _virtualPath =
    r'C:\Music\album.tak::track=01::start=0::end=200000';

Audio _audio(String path) => Audio(
  'Title',
  'Artist',
  'Album',
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
  setUp(() => AudioLibrary.instance.dispose());
  tearDown(() => AudioLibrary.instance.dispose());

  test('AudioFolder drops a container track shadowed by a virtual track', () {
    final container = _audio(_containerPath);
    final virtual = _audio(_virtualPath);

    final folder = AudioFolder([container, virtual], r'C:\Music', 1, 1);

    expect(folder.audios, [virtual]);
  });

  test('AudioFolder keeps a container track without virtual tracks', () {
    final container = _audio(_containerPath);

    final folder = AudioFolder([container], r'C:\Music', 1, 1);

    expect(folder.audios, [container]);
  });

  test('assigning audios drops a container track added later', () {
    final container = _audio(_containerPath);
    final virtual = _audio(_virtualPath);
    final folder = AudioFolder([virtual], r'C:\Music', 1, 1);

    folder.audios = [...folder.audios, container];

    expect(folder.audios, [virtual]);
  });

  test('collection rebuild drops container tracks injected into a folder', () {
    final library = AudioLibrary.instance;
    final container = _audio(_containerPath);
    final virtual = _audio(_virtualPath);
    final folder = AudioFolder([virtual], r'C:\Music', 1, 1);
    folder.audios.add(container);

    library.replaceFolders([folder]);

    expect(library.audioCollection, [virtual]);
  });

  test('collection rebuild drops a container track from a separate entry', () {
    final library = AudioLibrary.instance;
    final container = _audio(_containerPath);
    final virtual = _audio(_virtualPath);

    library.replaceFolders([
      AudioFolder([container], r'C:\Music', 1, 1),
      AudioFolder([virtual], r'C:\Music', 1, 1),
    ]);

    expect(library.audioCollection, [virtual]);
  });
}
