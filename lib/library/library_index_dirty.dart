import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/settings.dart';
import 'package:sqlite3/sqlite3.dart';

/// 标记音频所在目录需要重扫。
///
/// 写标签只改变文件内容与文件 mtime，目录 mtime 不变；增量扫描的目录快速
/// 路径因此会跳过该目录。把 `folders.modified` 置 0 使下次启动必然重扫。
///
/// [supportPath] 仅用于测试注入曲库目录；生产环境使用应用数据目录。
Future<bool> markAudioDirectoryIndexDirty(
  String audioPath, {
  String? supportPath,
}) {
  final file = audioPath.trim();
  if (file.isEmpty) return Future<bool>.value(false);
  return markLibraryIndexDirectoryDirty(
    p.dirname(file),
    supportPath: supportPath,
  );
}

/// 把 [directory] 在 `folders` 表中的 `modified` 置 0。
///
/// 返回是否命中并更新了目录记录；数据库缺失、无匹配目录或更新失败返回
/// false。异常在此捕获并记录日志，不向调用方抛出。
Future<bool> markLibraryIndexDirectoryDirty(
  String directory, {
  String? supportPath,
}) async {
  final target = directory.trim();
  if (target.isEmpty) return false;

  Database? database;
  try {
    final root = supportPath ?? (await getAppDataDir()).path;
    final databaseFile = File(p.join(root, 'library.sqlite'));
    if (!databaseFile.existsSync()) {
      log.library.debug(
        'legacy',
        '曲库数据库不存在，跳过目录重扫标记',
        fields: {'database': databaseFile.path},
      );
      return false;
    }

    database = sqlite3.open(databaseFile.path);
    database.execute('PRAGMA busy_timeout = 3000');
    // 索引库由 Rust 侧写入，路径分隔符可能和 Dart 侧不一致。
    const matchClause =
        "path COLLATE NOCASE = ? OR "
        "REPLACE(path, '/', '\\') = REPLACE(?, '/', '\\') COLLATE NOCASE";
    final matched = database
        .select('SELECT 1 FROM folders WHERE $matchClause LIMIT 1', [
          target,
          target,
        ])
        .isNotEmpty;
    if (!matched) {
      log.library.debug(
        'legacy',
        '曲库索引中没有该目录，跳过重扫标记',
        fields: {'directory': target},
      );
      return false;
    }
    database.execute(
      'UPDATE folders SET modified = 0 WHERE $matchClause',
      [target, target],
    );
    return true;
  } catch (error, trace) {
    log.library.error(
      'legacy',
      '标记曲库目录待重扫失败',
      fields: {'directory': target},
      error: error,
      stackTrace: trace,
    );
    return false;
  } finally {
    try {
      database?.dispose();
    } catch (error, trace) {
      log.library.warn(
        'legacy',
        '释放曲库数据库句柄失败',
        error: error,
        stackTrace: trace,
      );
    }
  }
}
