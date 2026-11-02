import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('补齐 track_overrides 缺失列且保留旧数据', () {
    final database = sqlite3.openInMemory();
    addTearDown(database.dispose);
    database.execute('''
CREATE TABLE track_overrides (
  track_uid TEXT PRIMARY KEY,
  title TEXT,
  artist TEXT,
  album TEXT,
  album_artist TEXT,
  track INTEGER,
  disc INTEGER,
  updated_at INTEGER NOT NULL
);
''');
    database.execute(
      'INSERT INTO track_overrides(track_uid, title, updated_at) '
      'VALUES(?, ?, ?)',
      ['cue:d:/music/disc.flac#01', '旧标题', 1],
    );

    migrateTrackOverrideColumns(database);
    migrateTrackOverrideColumns(database);

    final columns = <String>{
      for (final row in database.select('PRAGMA table_info(track_overrides)'))
        if (row['name'] is String) row['name'] as String,
    };
    expect(columns.containsAll(trackOverrideOptionalColumns.keys), isTrue);
    expect(
      database.select('SELECT title FROM track_overrides').single['title'],
      '旧标题',
    );
  });

  test('track_overrides 扩展列清单保持稳定', () {
    expect(trackOverrideOptionalColumns.keys.toSet(), <String>{
      'genre',
      'year',
      'track_total',
      'disc_total',
      'composer',
      'lyricist',
      'label',
      'comment',
      'bpm',
      'language',
      'copyright',
      'license',
    });
  });
}
