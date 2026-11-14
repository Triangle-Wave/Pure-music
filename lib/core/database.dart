import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/settings.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

/// `track_overrides` 的可选标签列；建表与迁移共用同一份定义。
///
/// `year` 与 `bpm` 保留原始文本，兼容 `1999-01-01`、`128.5` 这类值。
const Map<String, String> trackOverrideOptionalColumns = <String, String>{
  'genre': 'TEXT',
  'year': 'TEXT',
  'track_total': 'INTEGER',
  'disc_total': 'INTEGER',
  'composer': 'TEXT',
  'lyricist': 'TEXT',
  'label': 'TEXT',
  'comment': 'TEXT',
  'bpm': 'TEXT',
  'language': 'TEXT',
  'copyright': 'TEXT',
  'license': 'TEXT',
};

/// 为 `track_overrides` 补齐缺失的可选标签列；重复调用无副作用。
void migrateTrackOverrideColumns(Database db) {
  final existing = <String>{
    for (final row in db.select('PRAGMA table_info(track_overrides)'))
      if (row['name'] is String) row['name'] as String,
  };
  for (final entry in trackOverrideOptionalColumns.entries) {
    if (existing.contains(entry.key)) continue;
    db.execute(
      'ALTER TABLE track_overrides ADD COLUMN ${entry.key} ${entry.value}',
    );
  }
}

class AppDb {
  AppDb._();

  static final AppDb instance = AppDb._();

  Database? _db;
  Future<Database>? _opening;

  Future<Database> db() {
    final existing = _db;
    if (existing != null) return Future<Database>.value(existing);
    final opening = _opening;
    if (opening != null) return opening;

    final future = _open();
    _opening = future;
    return future;
  }

  Future<Database> _open() async {
    Database? opened;
    try {
      final dir = await getDbDir();
      final dbFile = File(path.join(dir.path, 'app.sqlite'));
      dbFile.parent.createSync(recursive: true);

      opened = openRecovering(dbFile);
      _db = opened;
      return opened;
    } catch (error, stackTrace) {
      log.app.warn(
        'db_open_failed',
        '打开数据库失败，释放句柄后向上传播',
        error: error,
        stackTrace: stackTrace,
      );
      opened?.dispose();
      rethrow;
    } finally {
      _opening = null;
    }
  }

  /// 打开数据库；文件损坏时隔离旧文件后重建。
  @visibleForTesting
  static Database openRecovering(File dbFile) {
    if (dbFile.path.isEmpty) {
      throw ArgumentError.value(dbFile.path, 'dbFile.path', '数据库路径不能为空');
    }
    try {
      final db = sqlite3.open(dbFile.path);
      try {
        _initSchema(db);
      } catch (error, stackTrace) {
        log.app.warn(
          'db_init_failed',
          '初始化数据库失败，释放句柄后向上传播',
          fields: {'path': dbFile.path},
          error: error,
          stackTrace: stackTrace,
        );
        db.dispose();
        rethrow;
      }
      return db;
    } on SqliteException catch (error) {
      if (!_isCorruption(error)) rethrow;
      final quarantined = _quarantine(dbFile);
      if (quarantined == null) rethrow;
      log.app.warn(
        'db_corrupt',
        '数据文件已隔离至 $quarantined，准备重建',
        fields: {'code': error.resultCode, 'path': quarantined},
      );
      final db = sqlite3.open(dbFile.path);
      try {
        _initSchema(db);
      } catch (error, stackTrace) {
        log.app.warn(
          'db_init_failed',
          '重建数据库后初始化失败，释放句柄后向上传播',
          fields: {'path': dbFile.path},
          error: error,
          stackTrace: stackTrace,
        );
        db.dispose();
        rethrow;
      }
      return db;
    }
  }

  /// 损坏类结果码：SQLITE_CORRUPT=11、SQLITE_NOTADB=26，扩展码取低 8 位。
  @visibleForTesting
  static bool isCorruptionCode(int resultCode) => _isCorruptionCode(resultCode);

  static bool _isCorruption(SqliteException error) =>
      _isCorruptionCode(error.resultCode);

  static bool _isCorruptionCode(int resultCode) {
    final code = resultCode & 0xff;
    return code == 11 || code == 26;
  }

  /// 把损坏的数据库连同 WAL/SHM 一起改名保留，返回主文件的新路径。
  @visibleForTesting
  static String? quarantineDatabase(File dbFile) => _quarantine(dbFile);

  static String? _quarantine(File dbFile) {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    String? mainPath;
    for (final suffix in const ['', '-wal', '-shm']) {
      final file = File('${dbFile.path}$suffix');
      if (!file.existsSync()) continue;
      final target = '${dbFile.path}.corrupt-$stamp$suffix';
      try {
        file.renameSync(target);
        if (suffix.isEmpty) mainPath = target;
      } catch (error, stackTrace) {
        if (suffix.isEmpty) {
          log.app.warn(
            'db_corrupt',
            '隔离主文件失败，保留原文件并停止重建',
            fields: {'path': dbFile.path},
            error: error,
            stackTrace: stackTrace,
          );
          return null;
        }
        log.app.warn(
          'db_corrupt',
          '隔离附属文件失败，继续重建',
          fields: {'path': file.path},
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return mainPath;
  }

  static void _initSchema(Database db) {
    final optionalColumns = trackOverrideOptionalColumns.entries
        .map((entry) => '${entry.key} ${entry.value}')
        .join(',\n  ');
    db.execute('''
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA busy_timeout = 3000;

CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS playlists (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS playlist_items (
  playlist_id INTEGER NOT NULL,
  path TEXT NOT NULL,
  PRIMARY KEY (playlist_id, path)
);

CREATE INDEX IF NOT EXISTS idx_playlist_items_playlist_id ON playlist_items(playlist_id);

CREATE TABLE IF NOT EXISTS lyric_sources (
  path TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  id TEXT
);

CREATE TABLE IF NOT EXISTS album_colors (
  key TEXT PRIMARY KEY,
  sig TEXT NOT NULL,
  p INTEGER NOT NULL,
  on_p INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS track_overrides (
  track_uid TEXT PRIMARY KEY,
  title TEXT,
  artist TEXT,
  album TEXT,
  album_artist TEXT,
  track INTEGER,
  disc INTEGER,
  updated_at INTEGER NOT NULL,
  $optionalColumns
);
''');

    _migrate(db);
  }

  static void _migrate(Database db) {
    db.execute('BEGIN');
    try {
      final version =
          db.select('PRAGMA user_version').first['user_version'] as int;
      if (version < 1) {
        db.execute(
            'ALTER TABLE playlist_items ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0');
        db.execute('PRAGMA user_version = 1');
      }
      if (version < 2) {
        try {
          db.execute('ALTER TABLE playlist_items DROP COLUMN audio_json');
        } catch (_) {}
        db.execute('PRAGMA user_version = 2');
      }
      if (version < 3) {
        db.execute('ALTER TABLE playlists ADD COLUMN cover_source TEXT');
        db.execute('PRAGMA user_version = 3');
      }
      if (version < 4) {
        db.execute('ALTER TABLE playlist_items ADD COLUMN added_at TEXT');
        db.execute('PRAGMA user_version = 4');
      }
      if (version < 5) {
        migrateTrackOverrideColumns(db);
        db.execute('PRAGMA user_version = 5');
      }
      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void dispose() {
    _db?.dispose();
    _db = null;
  }
}
