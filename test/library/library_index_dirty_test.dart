import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/library/library_index_dirty.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('library-index-dirty-');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  String createLibrary(List<String> folderPaths) {
    final databasePath = p.join(tempDir.path, 'library.sqlite');
    final database = sqlite3.open(databasePath);
    try {
      database.execute(
        'CREATE TABLE folders ('
        'path TEXT PRIMARY KEY, '
        'modified INTEGER NOT NULL, '
        'latest INTEGER NOT NULL)',
      );
      for (final folderPath in folderPaths) {
        database.execute(
          'INSERT INTO folders(path, modified, latest) VALUES(?, ?, ?)',
          [folderPath, 123456, 123456],
        );
      }
    } finally {
      database.dispose();
    }
    return databasePath;
  }

  int modifiedOf(String databasePath, String folderPath) {
    final database = sqlite3.open(databasePath);
    try {
      final row = database
          .select(
            'SELECT modified FROM folders WHERE path = ?',
            [folderPath],
          )
          .single;
      return row['modified'] as int;
    } finally {
      database.dispose();
    }
  }

  test('命中目录时把 modified 置 0', () async {
    final databasePath = createLibrary([r'D:\Music\Album']);

    final marked = await markLibraryIndexDirectoryDirty(
      r'D:\Music\Album',
      supportPath: tempDir.path,
    );

    expect(marked, isTrue);
    expect(modifiedOf(databasePath, r'D:\Music\Album'), 0);
  });

  test('按音频路径的父目录标记', () async {
    final databasePath = createLibrary([r'D:\Music\Album']);

    final marked = await markAudioDirectoryIndexDirty(
      r'D:\Music\Album\song.flac',
      supportPath: tempDir.path,
    );

    expect(marked, isTrue);
    expect(modifiedOf(databasePath, r'D:\Music\Album'), 0);
  });

  test('路径分隔符与大小写不同也能命中', () async {
    final databasePath = createLibrary(['D:/Music/Album']);

    final marked = await markLibraryIndexDirectoryDirty(
      r'd:\music\album',
      supportPath: tempDir.path,
    );

    expect(marked, isTrue);
    expect(modifiedOf(databasePath, 'D:/Music/Album'), 0);
  });

  test('目录不在曲库中时返回 false 且不修改其他记录', () async {
    final databasePath = createLibrary([r'D:\Music\Other']);

    final marked = await markLibraryIndexDirectoryDirty(
      r'D:\Music\Album',
      supportPath: tempDir.path,
    );

    expect(marked, isFalse);
    expect(modifiedOf(databasePath, r'D:\Music\Other'), 123456);
  });

  test('曲库数据库不存在时返回 false', () async {
    final marked = await markLibraryIndexDirectoryDirty(
      r'D:\Music\Album',
      supportPath: p.join(tempDir.path, 'missing'),
    );

    expect(marked, isFalse);
  });

  test('空路径直接返回 false', () async {
    createLibrary([r'D:\Music\Album']);

    final marked = await markAudioDirectoryIndexDirty(
      '   ',
      supportPath: tempDir.path,
    );

    expect(marked, isFalse);
  });
}
