import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/library/audio_library.dart';

Audio _audioFor(String path) => Audio(
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

String _cueTrackPath(String directory) =>
    '${p.join(directory, 'album.cue')}::track=01::start=0::end=200000';

String _sacdTrackPath(String directory) =>
    '${p.join(directory, 'album.iso')}'
    '::track=01::start=0::end=200000::sacd=2ch';

void main() {
  late Directory directory;

  setUp(() async {
    AudioLibrary.instance.dispose();
    directory = await Directory.systemTemp.createTemp(
      'pure_music_folder_cover_',
    );
  });

  tearDown(() async {
    AudioLibrary.instance.dispose();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test(
    'resolves a case-insensitive cover for a cue virtual track',
    () async {
      final cover = File(p.join(directory.path, 'COVER.JPG'));
      await cover.writeAsBytes([1, 2, 3]);
      final audio = _audioFor(_cueTrackPath(directory.path));

      expect(await audio.resolveFolderCoverPath(), cover.path);
    },
  );

  test('resolves a cover for a sacd virtual track', () async {
    final cover = File(p.join(directory.path, 'Cover.Png'));
    await cover.writeAsBytes([1, 2, 3]);
    final audio = _audioFor(_sacdTrackPath(directory.path));

    expect(await audio.resolveFolderCoverPath(), cover.path);
  });

  test('prefers cover over folder and front', () async {
    await File(p.join(directory.path, 'front.png')).writeAsBytes([1]);
    await File(p.join(directory.path, 'folder.jpg')).writeAsBytes([2]);
    final cover = File(p.join(directory.path, 'cover.png'));
    await cover.writeAsBytes([3]);
    final audio = _audioFor(_cueTrackPath(directory.path));

    expect(await audio.resolveFolderCoverPath(), cover.path);
  });

  test('falls back to folder then front names', () async {
    await File(p.join(directory.path, 'front.JPEG')).writeAsBytes([1]);
    final folder = File(p.join(directory.path, 'Folder.WebP'));
    await folder.writeAsBytes([2]);
    final audio = _audioFor(_cueTrackPath(directory.path));

    expect(await audio.resolveFolderCoverPath(), folder.path);
  });

  test('returns null when the folder has no cover image', () async {
    final audio = _audioFor(_cueTrackPath(directory.path));

    expect(await audio.resolveFolderCoverPath(), isNull);
  });

  test(
    'shares the folder lookup between tracks in the same directory',
    () async {
      final cover = File(p.join(directory.path, 'cover.webp'));
      await cover.writeAsBytes([1]);
      final first = _audioFor(_cueTrackPath(directory.path));
      final second = _audioFor(_sacdTrackPath(directory.path));

      expect(await first.resolveFolderCoverPath(), cover.path);
      await cover.delete();
      // 目录级缓存按目录共享：同一目录的下一首曲目沿用已解析的封面路径。
      expect(await second.resolveFolderCoverPath(), cover.path);
    },
  );
}
