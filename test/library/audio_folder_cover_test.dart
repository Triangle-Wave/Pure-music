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

String _cueTrackPath(
  String directory, {
  String fileName = 'album.cue',
  int track = 1,
}) =>
    '${p.join(directory, fileName)}'
    '::track=${track.toString().padLeft(2, '0')}::start=0::end=200000';

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

  test('resolves an image named after the cue source file', () async {
    final cover = File(p.join(directory.path, '告白.png'));
    await cover.writeAsBytes([1]);
    final audio = _audioFor(_cueTrackPath(directory.path, fileName: '告白.tak'));

    expect(await audio.resolveFolderCoverPath(), cover.path);
  });

  test('prefers a generic cover name over the source-named image', () async {
    await File(p.join(directory.path, '告白.png')).writeAsBytes([1]);
    final cover = File(p.join(directory.path, 'cover.jpg'));
    await cover.writeAsBytes([2]);
    final audio = _audioFor(_cueTrackPath(directory.path, fileName: '告白.tak'));

    expect(await audio.resolveFolderCoverPath(), cover.path);
  });

  test('prefers the source-named image over a Jacket scan', () async {
    final jacket = await Directory(p.join(directory.path, 'Jacket')).create();
    await File(p.join(jacket.path, 'IMG_0001.bmp')).writeAsBytes([1]);
    final cover = File(p.join(directory.path, '告白.png'));
    await cover.writeAsBytes([2]);
    final audio = _audioFor(_cueTrackPath(directory.path, fileName: '告白.tak'));

    expect(await audio.resolveFolderCoverPath(), cover.path);
  });

  test(
    'resolves a bmp cover inside a case-insensitive Jacket directory',
    () async {
      final jacket = await Directory(p.join(directory.path, 'jacket')).create();
      final cover = File(p.join(jacket.path, 'IMG_0002.bmp'));
      await cover.writeAsBytes([1]);
      await File(p.join(jacket.path, 'notes.txt')).writeAsString('ignore me');
      final audio = _audioFor(_cueTrackPath(directory.path));

      expect(await audio.resolveFolderCoverPath(), cover.path);
    },
  );

  test('resolves an image inside a Scans directory', () async {
    final scans = await Directory(p.join(directory.path, 'SCANS')).create();
    await File(p.join(scans.path, 'scan02.png')).writeAsBytes([1]);
    final cover = File(p.join(scans.path, 'scan01.jpg'));
    await cover.writeAsBytes([2]);
    final audio = _audioFor(_cueTrackPath(directory.path));

    expect(await audio.resolveFolderCoverPath(), cover.path);
  });

  test('uses the source-named image for a sacd virtual track too', () async {
    final cover = File(p.join(directory.path, 'album.webp'));
    await cover.writeAsBytes([1]);
    final audio = _audioFor(_sacdTrackPath(directory.path));

    expect(await audio.resolveFolderCoverPath(), cover.path);
  });

  test(
    'shares the folder lookup between tracks of the same source file',
    () async {
      final cover = File(p.join(directory.path, 'cover.webp'));
      await cover.writeAsBytes([1]);
      final first = _audioFor(_cueTrackPath(directory.path));
      final second = _audioFor(_cueTrackPath(directory.path, track: 2));

      expect(await first.resolveFolderCoverPath(), cover.path);
      await cover.delete();
      // 同一音源的多条虚拟轨共享封面缓存，沿用已解析的封面路径。
      expect(await second.resolveFolderCoverPath(), cover.path);
    },
  );

  test('resolves each source its own image in a shared folder', () async {
    final firstCover = File(p.join(directory.path, 'a.png'));
    final secondCover = File(p.join(directory.path, 'b.png'));
    await firstCover.writeAsBytes([1]);
    await secondCover.writeAsBytes([2]);
    final first = _audioFor(_cueTrackPath(directory.path, fileName: 'a.tak'));
    final second = _audioFor(_cueTrackPath(directory.path, fileName: 'b.tak'));

    expect(await first.resolveFolderCoverPath(), firstCover.path);
    expect(await second.resolveFolderCoverPath(), secondCover.path);
  });

  test('returns every folder cover candidate in priority order', () async {
    final cover = File(p.join(directory.path, 'cover.jpg'));
    final sameName = File(p.join(directory.path, 'a.png'));
    final jacket = await Directory(p.join(directory.path, 'Jacket')).create();
    final scan = File(p.join(jacket.path, 'IMG_0001.bmp'));
    await cover.writeAsBytes([1]);
    await sameName.writeAsBytes([2]);
    await scan.writeAsBytes([3]);
    final audio = _audioFor(_cueTrackPath(directory.path, fileName: 'a.tak'));

    final candidates = await AudioLibrary.instance.resolveFolderCoverCandidates(
      directory.path,
      sourcePath: audio.filePath,
    );

    expect(candidates.map((candidate) => candidate.path), [
      cover.path,
      sameName.path,
      scan.path,
    ]);
  });

  test(
    'enumerates a shared folder once for concurrent and repeated lookups',
    () async {
      final firstCover = File(p.join(directory.path, 'a.png'));
      final secondCover = File(p.join(directory.path, 'b.png'));
      await firstCover.writeAsBytes([1]);
      await secondCover.writeAsBytes([2]);
      final first = _audioFor(_cueTrackPath(directory.path, fileName: 'a.tak'));
      final second = _audioFor(_cueTrackPath(directory.path, fileName: 'b.tak'));
      final library = AudioLibrary.instance;
      final before = library.folderCoverDirectoryScanCount;

      final paths = await Future.wait([
        first.resolveFolderCoverPath(),
        second.resolveFolderCoverPath(),
      ]);

      expect(paths, [firstCover.path, secondCover.path]);
      expect(library.folderCoverDirectoryScanCount - before, 1);
      // 重复调用命中候选缓存，不再重新枚举目录。
      expect(await second.resolveFolderCoverPath(), secondCover.path);
      expect(library.folderCoverDirectoryScanCount - before, 1);
    },
  );
}
