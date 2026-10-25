import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/settings.dart';

/// 缓存根下的子目录名。
const String cacheCoversDirectoryName = 'covers';
const String cacheLyricsDirectoryName = 'lyrics';
const String cacheOnlineAlbumDirectoryName = 'online_album';
const String cacheSacdDirectoryName = 'iso';
const String cacheLyricIndexDirectoryName = 'lyric_index';

/// 缓存根下由本应用维护的全部子目录。
const List<String> cacheSubdirectoryNames = <String>[
  cacheCoversDirectoryName,
  cacheLyricsDirectoryName,
  cacheOnlineAlbumDirectoryName,
  cacheSacdDirectoryName,
  cacheLyricIndexDirectoryName,
];

/// 旧版 SACD 缓存在数据根下的目录名。
const String _legacySacdDirectoryName = 'iso_cache';

/// 旧版 AMLL 索引在缓存根下的相对目录名。
const String _legacyAmllIndexDirectoryName = 'amll';

/// 旧版 AMLL 索引文件在缓存根下的相对路径，用于清理早期布局。
const String _legacyAmllIndexFileName = 'raw-lyrics-index.jsonl';

Future<Directory>? _cacheRootFuture;
String? _cacheRootSignature;
bool _sacdMigrationAttempted = false;
bool _lyricIndexMigrationAttempted = false;

Future<Directory> Function()? _dataRootOverride;
String Function()? _cacheDirectoryOverride;

/// 缓存清理结果。
class CacheClearReport {
  const CacheClearReport({
    required this.files,
    required this.bytes,
    required this.failed,
  });

  final int files;
  final int bytes;
  final int failed;
}

Future<Directory> _dataRoot() {
  final override = _dataRootOverride;
  return override != null ? override() : getAppDataDir();
}

String _configuredCacheDirectory() {
  final override = _cacheDirectoryOverride;
  if (override != null) return override().trim();
  return AppSettings.instance.cacheDirectory.trim();
}

/// 当前生效的缓存根。
///
/// 设置项 `CacheDirectory` 为空表示 `<数据根>/cache`。设置值不是绝对路径、
/// 创建失败或写探测失败时回退默认位置并记录 WARN，不向调用方抛出异常。
Future<Directory> getCacheRoot() {
  final configured = _configuredCacheDirectory();
  final cached = _cacheRootFuture;
  if (cached != null && _cacheRootSignature == configured) return cached;
  _cacheRootSignature = configured;
  final future = _resolveCacheRoot(configured);
  _cacheRootFuture = future;
  return future;
}

/// 缓存目录设置变化后丢弃已解析的缓存根。
void resetCacheRoot() {
  _cacheRootFuture = null;
  _cacheRootSignature = null;
  _lyricIndexMigrationAttempted = false;
}

/// 校验用户选择的目录；返回 null 表示可用，否则返回面向用户的提示。
Future<String?> validateCacheDirectory(String rawPath) async {
  final normalized = rawPath.trim();
  if (normalized.isEmpty) return null;
  if (!p.isAbsolute(normalized)) return '请选择绝对路径';
  final problem = await _prepareDirectory(Directory(p.normalize(normalized)));
  if (problem == null) return null;
  return '目录不可写：$normalized';
}

Future<Directory> _resolveCacheRoot(String configured) async {
  final fallback = await _defaultCacheRoot();
  if (configured.isEmpty) return fallback;
  if (!p.isAbsolute(configured)) {
    log.app.warn(
      'cache_paths',
      '缓存目录不是绝对路径，已回退默认位置：$configured',
    );
    return fallback;
  }
  final candidate = Directory(p.normalize(configured));
  final problem = await _prepareDirectory(candidate);
  if (problem == null) return candidate;
  log.app.warn(
    'cache_paths',
    '缓存目录不可用，已回退默认位置：${candidate.path}',
    error: problem,
  );
  return fallback;
}

Future<Directory> _defaultCacheRoot() async {
  final dataRoot = await _dataRoot();
  final directory = Directory(p.join(dataRoot.path, 'cache'));
  try {
    await directory.create(recursive: true);
  } catch (error, stackTrace) {
    log.app.warn(
      'cache_paths',
      '默认缓存目录创建失败：${directory.path}',
      error: error,
      stackTrace: stackTrace,
    );
  }
  return directory;
}

/// 创建目录并写入一个空探测文件；失败时返回异常对象。
Future<Object?> _prepareDirectory(Directory directory) async {
  final probePath = p.join(
    directory.path,
    '.pure_music_cache_probe_${pid}_'
    '${DateTime.now().microsecondsSinceEpoch}',
  );
  final probe = File(probePath);
  try {
    await directory.create(recursive: true);
    await probe.writeAsBytes(const <int>[], flush: true);
  } catch (error) {
    try {
      if (await probe.exists()) await probe.delete();
    } catch (_) {
      // 探测文件清理失败时留给用户手动处理，不覆盖原始错误。
    }
    return error;
  }
  try {
    await probe.delete();
  } catch (_) {
    // 探测文件删除失败不影响目录可写性判断。
  }
  return null;
}

Future<Directory> _ensureDirectory(Directory directory) async {
  try {
    await directory.create(recursive: true);
  } catch (error, stackTrace) {
    log.app.warn(
      'cache_paths',
      '缓存目录创建失败：${directory.path}',
      error: error,
      stackTrace: stackTrace,
    );
  }
  return directory;
}

/// 缓存根下的指定子目录，已尽力创建。
Future<Directory> getCacheSubdirectory(String name) async {
  final root = await getCacheRoot();
  return _ensureDirectory(Directory(p.join(root.path, name)));
}

Future<Directory> getCoverCacheDirectory() =>
    getCacheSubdirectory(cacheCoversDirectoryName);

Future<Directory> getLyricCandidateCacheDirectory() =>
    getCacheSubdirectory(cacheLyricsDirectoryName);

Future<Directory> getOnlineAlbumCacheDirectory() =>
    getCacheSubdirectory(cacheOnlineAlbumDirectoryName);

Future<Directory> getOnlineAlbumArtistCacheDirectory() async {
  final base = await getOnlineAlbumCacheDirectory();
  return _ensureDirectory(Directory(p.join(base.path, 'artist')));
}

/// AMLL 索引目录。
Future<Directory> getLyricIndexCacheDirectory() async {
  final directory = await getCacheSubdirectory(cacheLyricIndexDirectoryName);
  await _migrateLegacyLyricIndex(directory);
  return directory;
}

/// SACD 提取缓存目录。
Future<Directory> getSacdCacheDirectory() async {
  await _migrateLegacySacdCache();
  return getCacheSubdirectory(cacheSacdDirectoryName);
}

/// 旧版缓存根 `<数据根>/cache`。
Future<Directory> getLegacyCacheRoot() async {
  final dataRoot = await _dataRoot();
  return Directory(p.join(dataRoot.path, 'cache'));
}

Future<Directory> getLegacyCoverCacheDirectory() async {
  final root = await getLegacyCacheRoot();
  return Directory(p.join(root.path, cacheCoversDirectoryName));
}

/// 旧版 SACD 缓存目录 `<数据根>/iso_cache`。
Future<Directory> getLegacySacdCacheDirectory() async {
  final dataRoot = await _dataRoot();
  return Directory(p.join(dataRoot.path, _legacySacdDirectoryName));
}

/// 创建缓存根与全部子目录，并把旧 SACD 缓存尽力迁移到新位置。
Future<void> ensureCacheDirectories() async {
  try {
    await _migrateLegacySacdCache();
    for (final name in cacheSubdirectoryNames) {
      await getCacheSubdirectory(name);
    }
  } catch (error, stackTrace) {
    log.app.warn(
      'cache_directory_prepare_failed',
      '缓存目录准备失败，功能按需回退',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// 清空全部缓存内容，返回删除统计。设置、数据库、日志与更新包不受影响。
Future<CacheClearReport> clearCache() async {
  final root = await getCacheRoot();
  final dataRoot = await _dataRoot();
  final directories = <String, Directory>{};

  void addDirectory(Directory directory) {
    final key = p.normalize(p.absolute(directory.path)).toLowerCase();
    if (key == p.normalize(p.absolute(root.path)).toLowerCase()) return;
    directories[key] = directory;
  }

  for (final name in cacheSubdirectoryNames) {
    addDirectory(Directory(p.join(root.path, name)));
  }
  final legacyCacheRoot = Directory(p.join(dataRoot.path, 'cache'));
  for (final name in const [
    cacheCoversDirectoryName,
    cacheLyricsDirectoryName,
    _legacyAmllIndexDirectoryName,
    cacheOnlineAlbumDirectoryName,
    cacheSacdDirectoryName,
    cacheLyricIndexDirectoryName,
  ]) {
    addDirectory(Directory(p.join(legacyCacheRoot.path, name)));
  }
  addDirectory(
    Directory(p.join(dataRoot.path, cacheOnlineAlbumDirectoryName)),
  );
  addDirectory(Directory(p.join(dataRoot.path, _legacySacdDirectoryName)));

  final legacyFiles = <File>[
    File(p.join(legacyCacheRoot.path, _legacyAmllIndexFileName)),
  ];

  var files = 0;
  var bytes = 0;
  var failed = 0;

  for (final directory in directories.values) {
    final result = await _clearDirectory(directory);
    files += result.files;
    bytes += result.bytes;
    failed += result.failed;
  }
  for (final file in legacyFiles) {
    try {
      if (!await file.exists()) continue;
      final length = await file.length();
      await file.delete();
      files += 1;
      bytes += length;
    } catch (error, stackTrace) {
      failed += 1;
      log.app.warn(
        'cache_paths',
        '缓存文件清理失败：${file.path}',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
  return CacheClearReport(files: files, bytes: bytes, failed: failed);
}

Future<CacheClearReport> _clearDirectory(Directory directory) async {
  var files = 0;
  var bytes = 0;
  var failed = 0;
  try {
    if (!await directory.exists()) {
      return const CacheClearReport(files: 0, bytes: 0, failed: 0);
    }
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      try {
        final length = await entity.length();
        await entity.delete();
        files += 1;
        bytes += length;
      } catch (error, stackTrace) {
        failed += 1;
        log.app.warn(
          'cache_paths',
          '缓存文件清理失败：${entity.path}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  } catch (error, stackTrace) {
    failed += 1;
    log.app.warn(
      'cache_paths',
      '缓存目录扫描失败：${directory.path}',
      error: error,
      stackTrace: stackTrace,
    );
  }
  return CacheClearReport(files: files, bytes: bytes, failed: failed);
}

/// 用资源管理器打开缓存根；非 Windows 或失败时返回 false。
Future<bool> openCacheDirectory() async {
  try {
    final directory = await getCacheRoot();
    await directory.create(recursive: true);
    if (!Platform.isWindows) return false;
    await Process.start(
      'explorer',
      [directory.absolute.path],
      runInShell: true,
    );
    return true;
  } catch (error, stackTrace) {
    log.app.warn(
      'cache_paths',
      '打开缓存目录失败',
      error: error,
      stackTrace: stackTrace,
    );
    return false;
  }
}

Future<void> _migrateLegacySacdCache() async {
  if (_sacdMigrationAttempted) return;
  _sacdMigrationAttempted = true;
  try {
    final target = Directory(
      p.join((await getCacheRoot()).path, cacheSacdDirectoryName),
    );
    final legacy = await getLegacySacdCacheDirectory();
    if (p.equals(target.path, legacy.path)) return;
    if (await target.exists()) {
      final empty = await target.list(followLinks: false).isEmpty;
      if (!empty) return;
      await target.delete(recursive: true);
    }
    if (!await legacy.exists()) return;
    if (await legacy.list(followLinks: false).isEmpty) return;
    await legacy.rename(target.path);
    log.app.info('cache_paths', 'SACD 缓存目录已迁移到 ${target.path}');
  } catch (error, stackTrace) {
    log.app.info(
      'cache_paths',
      '旧 SACD 缓存未迁移，保留在原位置并可手动清理',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

Future<void> _migrateLegacyLyricIndex(Directory targetRoot) async {
  if (_lyricIndexMigrationAttempted) return;
  _lyricIndexMigrationAttempted = true;
  try {
    final legacy = Directory(
      p.join((await getLegacyCacheRoot()).path, _legacyAmllIndexDirectoryName),
    );
    final target = Directory(
      p.join(targetRoot.path, _legacyAmllIndexDirectoryName),
    );
    if (p.equals(legacy.path, target.path)) return;
    if (!await legacy.exists()) return;
    await for (final entity in legacy.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: legacy.path);
      final destination = File(p.join(target.path, relative));
      if (await destination.exists()) continue;
      try {
        await destination.parent.create(recursive: true);
        await entity.copy(destination.path);
      } catch (error, stackTrace) {
        log.app.warn(
          'cache_paths',
          '旧 AMLL 索引复制失败：${entity.path}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  } catch (error, stackTrace) {
    log.app.warn(
      'cache_paths',
      '旧 AMLL 索引迁移失败，下一次搜索重新建立索引',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// 测试专用：覆盖数据根与缓存目录设置来源。
@visibleForTesting
void debugConfigureCachePaths({
  Future<Directory> Function()? dataRoot,
  String Function()? cacheDirectory,
}) {
  _dataRootOverride = dataRoot;
  _cacheDirectoryOverride = cacheDirectory;
  _sacdMigrationAttempted = false;
  resetCacheRoot();
}
