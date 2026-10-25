import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:pure_music/core/log/app_log.dart';

/// 磁盘封面缓存默认大小上限。
const int coverDiskCacheMaxBytes = 256 << 20;

/// 封面二级磁盘缓存。
///
/// 目录固定为 `<数据根>/cache/covers/`：本地图片按“源路径 + 修改时间 + 目标
/// 像素尺寸”生成 PNG 缩略图，在线图片按 URL 哈希保存下载结果。文件名只含
/// SHA-1 摘要与内容扩展名，不把原始路径或 URL 写进目录。
///
/// 所有磁盘错误都降级为未命中，调用方继续使用内存缓存与网络链路；缓存文件
/// 损坏时直接删除，下一次请求重新生成或下载。
class CoverDiskCache {
  CoverDiskCache({
    Future<Directory> Function()? rootDirectory,
    DateTime Function()? clock,
    this.maxBytes = coverDiskCacheMaxBytes,
    this.pruneInterval = const Duration(minutes: 5),
  }) : _rootDirectory = rootDirectory,
       _clock = clock ?? DateTime.now;

  static final CoverDiskCache instance = CoverDiskCache();

  final Future<Directory> Function()? _rootDirectory;
  final DateTime Function() _clock;
  final int maxBytes;
  final Duration pruneInterval;

  static const int _minImageBytes = 32;
  static const int _pruneScanLimit = 4096;

  Directory? _directory;
  DateTime? _lastPrune;
  final Map<String, File> _localFiles = {};
  final Map<String, File> _networkFiles = {};
  bool _networkIndexLoaded = false;

  /// 由启动流程在数据根确定后调用。
  void configure({required String rootPath}) {
    final root = rootPath.trim();
    if (root.isEmpty) return;
    _directory = Directory(path.join(root, 'cache', 'covers'));
    _localFiles.clear();
    _networkFiles.clear();
    _networkIndexLoaded = false;
    _lastPrune = null;
  }

  Future<Directory?> _root() async {
    final configured = _directory;
    if (configured != null) return configured;
    final factory = _rootDirectory;
    if (factory == null) return null;
    try {
      final base = await factory();
      final directory = Directory(path.join(base.path, 'cache', 'covers'));
      _directory = directory;
      return directory;
    } catch (error, stackTrace) {
      log.app.debug(
        'cover_cache_root_failed',
        '封面缓存目录不可用，继续使用内存缓存',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<Directory?> _readyRoot() async {
    final directory = await _root();
    if (directory == null) return null;
    try {
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      return directory;
    } catch (error, stackTrace) {
      log.app.warn(
        'cover_cache_directory_failed',
        '封面缓存目录创建失败，继续使用内存缓存',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  String _localKey({
    required String sourcePath,
    required int width,
    required int height,
    int? modified,
  }) {
    final normalized = path.normalize(sourcePath).toLowerCase();
    final stamp = modified ?? 0;
    final size = '${_bucket(width)}x${_bucket(height)}';
    final raw = 'local|$normalized|$stamp|$size';
    return sha1.convert(utf8.encode(raw)).toString();
  }

  String _networkKey(String url) {
    return sha1.convert(utf8.encode('url|${url.trim()}')).toString();
  }

  int _bucket(int value) {
    final clamped = value <= 0 ? 1 : (value > 2048 ? 2048 : value);
    return ((clamped + 31) ~/ 32) * 32;
  }

  /// 同步查询本地缩略图，供列表首帧直接使用 `FileImage`。
  File? cachedLocalThumbnailFile({
    required String sourcePath,
    required int width,
    required int height,
    int? modified,
  }) {
    final directory = _directory;
    if (directory == null) return null;
    final key = _localKey(
      sourcePath: sourcePath,
      width: width,
      height: height,
      modified: modified,
    );
    final known = _localFiles[key];
    if (known != null && _isUsableSync(known)) return known;
    _localFiles.remove(key);
    final file = File(path.join(directory.path, 'l_$key.png'));
    if (_isUsableSync(file)) {
      _localFiles[key] = file;
      return file;
    }
    return null;
  }

  /// 读取本地缩略图字节；文件损坏时删除并按未命中处理。
  Future<Uint8List?> readLocalThumbnail({
    required String sourcePath,
    required int width,
    required int height,
    int? modified,
  }) async {
    final file = cachedLocalThumbnailFile(
      sourcePath: sourcePath,
      width: width,
      height: height,
      modified: modified,
    );
    if (file == null) return null;
    try {
      final bytes = await file.readAsBytes();
      if (_hasPngSignature(bytes)) return bytes;
      await _deleteQuietly(file, 'invalid_local_thumbnail');
    } catch (error, stackTrace) {
      log.app.debug(
        'cover_cache_local_read_failed',
        '本地封面缩略图读取失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
    final key = _localKey(
      sourcePath: sourcePath,
      width: width,
      height: height,
      modified: modified,
    );
    _localFiles.remove(key);
    return null;
  }

  /// 写入本地封面缩略图；返回落盘文件，失败返回 null。
  Future<File?> writeLocalThumbnail({
    required String sourcePath,
    required int width,
    required int height,
    required Uint8List bytes,
    int? modified,
  }) async {
    if (!_hasPngSignature(bytes)) return null;
    final directory = await _readyRoot();
    if (directory == null) return null;
    final key = _localKey(
      sourcePath: sourcePath,
      width: width,
      height: height,
      modified: modified,
    );
    final file = File(path.join(directory.path, 'l_$key.png'));
    try {
      await _writeBytesAtomically(file, bytes);
      _localFiles[key] = file;
      _schedulePrune();
      return file;
    } catch (error, stackTrace) {
      log.app.warn(
        'cover_cache_local_write_failed',
        '本地封面缩略图写入失败，继续使用内存结果',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// 查询在线封面文件；过期、空文件或内容类型不符时删除并返回 null。
  Future<File?> findNetworkImage(String url, {required Duration ttl}) async {
    final key = _networkKey(url);
    final file = await _networkFileFor(key);
    if (file == null) return null;
    try {
      final stat = await file.stat();
      if (stat.size < _minImageBytes) {
        await _deleteNetworkFile(key, file, 'empty');
        return null;
      }
      if (_clock().difference(stat.modified) > ttl) {
        await _deleteNetworkFile(key, file, 'expired');
        return null;
      }
      final head = await _readHead(file, 16);
      if (!_looksLikeImage(head)) {
        await _deleteNetworkFile(key, file, 'invalid');
        return null;
      }
      return file;
    } catch (error, stackTrace) {
      log.app.debug(
        'cover_cache_network_read_failed',
        '在线封面缓存读取失败',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// 写入在线封面；旧扩展名文件会被替换。失败返回 null，由调用方回退内存图。
  Future<File?> storeNetworkImage(String url, Uint8List bytes) async {
    if (bytes.length < _minImageBytes) return null;
    final directory = await _readyRoot();
    if (directory == null) return null;
    final key = _networkKey(url);
    final extension = _extensionForBytes(bytes);
    final file = File(path.join(directory.path, 'u_$key$extension'));
    try {
      final previous = _networkFiles[key];
      if (previous != null && previous.path != file.path) {
        await _deleteQuietly(previous, 'replaced');
      }
      await _writeBytesAtomically(file, bytes);
      _networkFiles[key] = file;
      _schedulePrune();
      return file;
    } catch (error, stackTrace) {
      log.app.warn(
        'cover_cache_network_write_failed',
        '在线封面缓存写入失败，继续使用内存结果',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> deleteNetworkImage(String url) async {
    final key = _networkKey(url);
    final file = await _networkFileFor(key);
    if (file == null) return;
    await _deleteNetworkFile(key, file, 'requested');
  }

  /// 只清空在线封面文件，保留本地缩略图。
  Future<void> clearNetworkImages() async {
    final directory = await _root();
    if (directory == null) return;
    try {
      if (!await directory.exists()) {
        _networkFiles.clear();
        _networkIndexLoaded = false;
        return;
      }
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        if (!path.basename(entity.path).startsWith('u_')) continue;
        await _deleteQuietly(entity, 'clear_network');
      }
      _networkFiles.clear();
      _networkIndexLoaded = false;
    } catch (error, stackTrace) {
      log.app.warn(
        'cover_cache_network_clear_failed',
        '在线封面缓存清理失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 清空全部磁盘封面，供设置页或诊断使用。
  Future<void> clear() async {
    final directory = await _root();
    if (directory == null) return;
    try {
      if (!await directory.exists()) {
        _resetIndexes();
        return;
      }
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File) {
          await _deleteQuietly(entity, 'clear');
        }
      }
      _resetIndexes();
    } catch (error, stackTrace) {
      log.app.warn(
        'cover_cache_clear_failed',
        '封面缓存清理失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 按最近修改时间淘汰，把目录限制在 [maxBytes] 以内。
  Future<void> prune({int? maxBytes}) async {
    final directory = await _root();
    if (directory == null) return;
    try {
      if (!await directory.exists()) return;
      final entries = <_CacheFileStat>[];
      var total = 0;
      var scanned = 0;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        if (path.basename(entity.path).startsWith('.')) continue;
        scanned++;
        if (scanned > _pruneScanLimit) break;
        try {
          final stat = await entity.stat();
          entries.add(
            _CacheFileStat(
              file: entity,
              modified: stat.modified,
              size: stat.size,
            ),
          );
          total += stat.size;
        } catch (_) {
          continue;
        }
      }
      final limit = maxBytes ?? this.maxBytes;
      if (total <= limit) return;
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in entries) {
        if (total <= limit) break;
        await _deleteQuietly(entry.file, 'prune');
        total -= entry.size;
        _localFiles.removeWhere((_, file) => file.path == entry.file.path);
        _networkFiles.removeWhere((_, file) => file.path == entry.file.path);
      }
    } catch (error, stackTrace) {
      log.app.warn(
        'cover_cache_prune_failed',
        '封面缓存淘汰失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<File?> _networkFileFor(String key) async {
    final known = _networkFiles[key];
    if (known != null) {
      try {
        if (await known.exists()) return known;
      } catch (_) {
        // 文件已被外部删除，继续走目录索引。
      }
      _networkFiles.remove(key);
    }
    final directory = await _readyRoot();
    if (directory == null) return null;
    if (!_networkIndexLoaded) {
      await _loadNetworkIndex(directory);
    }
    return _networkFiles[key];
  }

  Future<void> _loadNetworkIndex(Directory directory) async {
    _networkIndexLoaded = true;
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = path.basename(entity.path);
        if (!name.startsWith('u_')) continue;
        final dot = name.indexOf('.');
        if (dot <= 2) continue;
        final key = name.substring(2, dot);
        _networkFiles.putIfAbsent(key, () => entity);
      }
    } catch (error, stackTrace) {
      _networkIndexLoaded = false;
      log.app.debug(
        'cover_cache_index_failed',
        '封面缓存索引建立失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _deleteNetworkFile(String key, File file, String reason) async {
    _networkFiles.remove(key);
    await _deleteQuietly(file, reason);
  }

  Future<void> _writeBytesAtomically(File file, Uint8List bytes) async {
    final temporary = File(
      path.join(
        file.parent.path,
        '.tmp_${path.basename(file.path)}_'
        '${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      try {
        await temporary.rename(file.path);
      } on FileSystemException {
        if (await file.exists()) await file.delete();
        await temporary.rename(file.path);
      }
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {
        // 临时文件由 prune 兜底清理，不覆盖原始异常。
      }
    }
  }

  Future<Uint8List> _readHead(File file, int length) async {
    final handle = await file.open();
    try {
      final buffer = Uint8List(length);
      final read = await handle.readInto(buffer);
      return Uint8List.sublistView(buffer, 0, read);
    } finally {
      await handle.close();
    }
  }

  bool _isUsableSync(File file) {
    try {
      return file.existsSync() && file.lengthSync() > 8;
    } catch (_) {
      return false;
    }
  }

  Future<void> _deleteQuietly(File file, String reason) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (error, stackTrace) {
      log.app.debug(
        'cover_cache_delete_failed',
        '封面缓存文件删除失败',
        fields: {'reason': reason},
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _schedulePrune() {
    final now = _clock();
    final last = _lastPrune;
    if (last != null && now.difference(last) < pruneInterval) return;
    _lastPrune = now;
    unawaited(prune());
  }

  void _resetIndexes() {
    _localFiles.clear();
    _networkFiles.clear();
    _networkIndexLoaded = false;
  }

  bool _hasPngSignature(List<int> bytes) {
    return bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a;
  }

  bool _looksLikeImage(Uint8List head) {
    if (_hasPngSignature(head)) return true;
    if (head.length >= 3 &&
        head[0] == 0xff &&
        head[1] == 0xd8 &&
        head[2] == 0xff) {
      return true;
    }
    if (head.length >= 6 &&
        head[0] == 0x47 &&
        head[1] == 0x49 &&
        head[2] == 0x46 &&
        head[3] == 0x38) {
      return true;
    }
    if (head.length >= 12 &&
        head[0] == 0x52 &&
        head[1] == 0x49 &&
        head[2] == 0x46 &&
        head[3] == 0x46 &&
        head[8] == 0x57 &&
        head[9] == 0x45 &&
        head[10] == 0x42 &&
        head[11] == 0x50) {
      return true;
    }
    return head.length >= 2 && head[0] == 0x42 && head[1] == 0x4d;
  }

  String _extensionForBytes(Uint8List bytes) {
    if (_hasPngSignature(bytes)) return '.png';
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return '.jpg';
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return '.gif';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return '.webp';
    }
    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4d) {
      return '.bmp';
    }
    return '.img';
  }
}

class _CacheFileStat {
  const _CacheFileStat({
    required this.file,
    required this.modified,
    required this.size,
  });

  final File file;
  final DateTime modified;
  final int size;
}
