import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/core/cache_paths.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/lyric_match_scoring.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/services/online_lyric/models/lyric_candidate.dart';

/// 候选缓存的有效期；超过后在下次读取时删除并重新获取。
const Duration lyricCandidateCacheTtl = Duration(days: 365);

/// 内存中保留的候选记录数量，避免长期占用大块歌词文本。
const int lyricCandidateMemoryCapacity = 8;

/// 计算一首歌的候选缓存键。
///
/// 标题、艺术家、专辑先做归一化（大小写、括号说明、版本词、标点差异都会被
/// 抹平），时长按 5 秒取整吸收不同来源的时长偏差；三者都为空时退回音频路径，
/// 避免未知曲目共用同一份缓存。
String lyricCandidateCacheKey(Audio audio) {
  final title = normalizeLyricMatchText(audio.title);
  final artist = normalizeLyricMatchText(audio.artist);
  final album = normalizeLyricMatchText(audio.album);
  final durationBucket = audio.duration > 0
      ? (audio.duration / 5).round().toString()
      : '';
  final buffer = StringBuffer()
    ..write(title)
    ..write('|')
    ..write(artist)
    ..write('|')
    ..write(album)
    ..write('|')
    ..write(durationBucket);
  if (title.isEmpty && artist.isEmpty) {
    buffer
      ..write('|')
      ..write(audio.path.toLowerCase());
  }
  return sha1.convert(utf8.encode(buffer.toString())).toString();
}

/// 歌词候选缓存统计。
class LyricCandidateCacheStats {
  const LyricCandidateCacheStats({required this.fileCount, required this.bytes});

  final int fileCount;
  final int bytes;

  bool get isEmpty => fileCount == 0;
}

/// 歌词候选的磁盘缓存。
///
/// 目录为缓存根下的 `lyrics/`（默认 `<数据根>/cache/lyrics/`），每首歌一个
/// `<sha1>.json` 文件。写入落在当前缓存根；旧位置的文件可继续作为只读回退
/// 命中。所有磁盘错误都降级为未命中；缓存文件损坏时删除并重新获取。写入
/// 失败向上抛出，由用户操作路径提示，自动获取路径自行吞掉并记录。
class LyricCandidateCache {
  LyricCandidateCache({
    Future<Directory> Function()? rootDirectory,
    Future<Directory> Function()? legacyRootDirectory,
    DateTime Function()? clock,
  }) : _rootDirectory = rootDirectory,
       _legacyRootDirectory = legacyRootDirectory ??
           (rootDirectory == null ? getLegacyCacheRoot : null),
       _clock = clock ?? DateTime.now;

  static final LyricCandidateCache instance = LyricCandidateCache();

  final Future<Directory> Function()? _rootDirectory;
  final Future<Directory> Function()? _legacyRootDirectory;
  final DateTime Function() _clock;

  final LinkedHashMap<String, LyricCandidateRecord> _memory = LinkedHashMap();
  final Map<String, Future<LyricCandidateRecord?>> _inflight = {};

  /// 同步读取内存中的记录，用于切歌时立即显示已访问过的歌词。
  LyricCandidateRecord? peek(String cacheKey) => _memory[cacheKey];

  LyricCandidateRecord? peekForAudio(Audio audio) =>
      peek(lyricCandidateCacheKey(audio));

  Future<LyricCandidateRecord?> read(Audio audio) =>
      readByKey(lyricCandidateCacheKey(audio));

  Future<LyricCandidateRecord?> readByKey(String cacheKey) {
    final cached = _memory[cacheKey];
    if (cached != null) {
      _touch(cacheKey, cached);
      return Future.value(cached);
    }
    final inflight = _inflight[cacheKey];
    if (inflight != null) return inflight;
    late final Future<LyricCandidateRecord?> future;
    future = _readFromDisk(cacheKey).whenComplete(() {
      if (identical(_inflight[cacheKey], future)) {
        _inflight.remove(cacheKey);
      }
    });
    _inflight[cacheKey] = future;
    return future;
  }

  Future<LyricCandidateRecord?> _readFromDisk(String cacheKey) async {
    try {
      final record = await _readFromDirectory(await _cacheDirectory(), cacheKey);
      if (record != null) return record;
      final legacy = await _legacyCacheDirectory();
      if (legacy == null) return null;
      return await _readFromDirectory(legacy, cacheKey);
    } catch (error, trace) {
      log.lyric.warn(
        'lyric.cache',
        '歌词候选缓存目录不可用，按未命中处理',
        error: error,
        stackTrace: trace,
      );
      return null;
    }
  }

  Future<LyricCandidateRecord?> _readFromDirectory(
    Directory directory,
    String cacheKey,
  ) async {
    File? file;
    try {
      file = File(p.join(directory.path, '$cacheKey.json'));
      if (!await file.exists()) return null;
      final modified = await file.lastModified();
      if (_clock().difference(modified) > lyricCandidateCacheTtl) {
        log.lyric.info('lyric.cache', '歌词候选缓存已过期，重新获取');
        await _deleteFile(file);
        return null;
      }
      final raw = await file.readAsString();
      final record = LyricCandidateRecord.fromJson(
        jsonDecode(raw),
        cacheKey: cacheKey,
      );
      if (record == null) {
        log.lyric.warn('lyric.cache', '歌词候选缓存结构无效，删除后重取');
        await _deleteFile(file);
        return null;
      }
      _remember(cacheKey, record);
      return record;
    } catch (error, trace) {
      log.lyric.warn(
        'lyric.cache',
        '读取歌词候选缓存失败，删除后重取',
        error: error,
        stackTrace: trace,
      );
      if (file != null) await _deleteFile(file);
      return null;
    }
  }

  /// 写入记录；失败时抛出，由调用方决定提示还是静默降级。
  Future<void> write(Audio audio, LyricCandidateRecord record) {
    return writeByKey(record.cacheKey, record);
  }

  Future<void> writeByKey(String cacheKey, LyricCandidateRecord record) async {
    final directory = await _cacheDirectory();
    final file = File(p.join(directory.path, '$cacheKey.json'));
    await writeTextFileAtomically(file.path, jsonEncode(record.toJson()));
    _remember(cacheKey, record);
  }

  /// 更新用户选择并立即落盘。
  Future<LyricCandidateRecord> updateSelection(
    Audio audio, {
    required bool disabled,
    String? selectedSourceId,
  }) async {
    final cacheKey = lyricCandidateCacheKey(audio);
    final existing = await readByKey(cacheKey);
    final base = existing ?? _emptyRecord(audio, cacheKey);
    final updated = base.copyWith(
      disabled: disabled,
      selectedSourceId: selectedSourceId,
      clearSelectedSourceId: selectedSourceId == null,
      updatedAtMs: _clock().millisecondsSinceEpoch,
    );
    await writeByKey(cacheKey, updated);
    return updated;
  }

  /// 用新候选覆盖记录，保留用户已做的选择（仍存在时）。
  Future<LyricCandidateRecord> replaceCandidates(
    Audio audio,
    List<LyricCandidate> candidates,
  ) async {
    final cacheKey = lyricCandidateCacheKey(audio);
    final existing = await readByKey(cacheKey);
    final limited = _limitCandidates(candidates);
    final selected = existing?.selectedSourceId;
    final keepSelection =
        selected != null && limited.any((item) => item.id == selected);
    final updated = LyricCandidateRecord(
      cacheKey: cacheKey,
      audioPath: audio.path,
      title: audio.title,
      artist: audio.artist,
      album: audio.album,
      durationSec: audio.duration,
      updatedAtMs: _clock().millisecondsSinceEpoch,
      candidates: limited,
      selectedSourceId: keepSelection ? selected : null,
      disabled: existing?.disabled ?? false,
    );
    await writeByKey(cacheKey, updated);
    return updated;
  }

  /// 删除一首歌的候选缓存。
  Future<void> remove(Audio audio) async {
    final cacheKey = lyricCandidateCacheKey(audio);
    _memory.remove(cacheKey);
    try {
      final directories = <Directory>[await _cacheDirectory()];
      final legacy = await _legacyCacheDirectory();
      if (legacy != null) directories.add(legacy);
      for (final directory in directories) {
        final file = File(p.join(directory.path, '$cacheKey.json'));
        await _deleteFile(file);
      }
    } catch (error, trace) {
      log.lyric.warn(
        'lyric.cache',
        '删除歌词候选缓存失败',
        error: error,
        stackTrace: trace,
      );
    }
  }

  /// 清空全部候选缓存，返回删除的文件数。
  Future<int> clearAll() async {
    _memory.clear();
    _inflight.clear();
    return _deleteWhere((_) => true);
  }

  /// 清空超过有效期的候选缓存，返回删除的文件数。
  Future<int> clearExpired() async {
    final now = _clock();
    _memory.removeWhere(
      (_, record) =>
          now.difference(
            DateTime.fromMillisecondsSinceEpoch(record.updatedAtMs),
          ) >
          lyricCandidateCacheTtl,
    );
    return _deleteWhere((modified) {
      return now.difference(modified) > lyricCandidateCacheTtl;
    });
  }

  Future<LyricCandidateCacheStats> stats() async {
    try {
      final directory = await _cacheDirectory();
      var count = 0;
      var bytes = 0;
      await for (final entity in directory.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final length = await entity.length();
          count += 1;
          bytes += length;
        } catch (error, trace) {
          log.lyric.warn(
            'lyric.cache',
            '读取歌词缓存文件大小失败',
            error: error,
            stackTrace: trace,
          );
        }
      }
      return LyricCandidateCacheStats(fileCount: count, bytes: bytes);
    } catch (error, trace) {
      log.lyric.warn(
        'lyric.cache',
        '统计歌词缓存失败',
        error: error,
        stackTrace: trace,
      );
      return const LyricCandidateCacheStats(fileCount: 0, bytes: 0);
    }
  }

  Future<int> _deleteWhere(bool Function(DateTime modified) matches) async {
    var removed = 0;
    try {
      final directories = <Directory>[await _cacheDirectory()];
      final legacy = await _legacyCacheDirectory();
      if (legacy != null) directories.add(legacy);
      for (final directory in directories) {
        if (!await directory.exists()) continue;
        await for (final entity in directory.list()) {
          if (entity is! File || !entity.path.endsWith('.json')) continue;
          try {
            final modified = await entity.lastModified();
            if (!matches(modified)) continue;
            await entity.delete();
            removed += 1;
          } catch (error, trace) {
            log.lyric.warn(
              'lyric.cache',
              '删除歌词缓存文件失败',
              error: error,
              stackTrace: trace,
            );
          }
        }
      }
    } catch (error, trace) {
      log.lyric.warn(
        'lyric.cache',
        '扫描歌词缓存目录失败',
        error: error,
        stackTrace: trace,
      );
    }
    return removed;
  }

  Future<void> _deleteFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (error, trace) {
      log.lyric.warn(
        'lyric.cache',
        '删除歌词缓存文件失败',
        error: error,
        stackTrace: trace,
      );
    }
  }

  Future<Directory> _cacheDirectory() async {
    final root = _rootDirectory;
    final base = root == null ? await getCacheRoot() : await root();
    return Directory(p.join(base.path, 'lyrics')).create(recursive: true);
  }

  Future<Directory?> _legacyCacheDirectory() async {
    final root = _legacyRootDirectory;
    if (root == null) return null;
    try {
      final base = await root();
      final legacy = Directory(p.join(base.path, 'lyrics'));
      final primary = await _cacheDirectory();
      if (p.equals(legacy.path, primary.path)) return null;
      return legacy;
    } catch (error, trace) {
      log.lyric.warn(
        'lyric.cache',
        '旧歌词候选缓存目录不可用',
        error: error,
        stackTrace: trace,
      );
      return null;
    }
  }

  void _remember(String cacheKey, LyricCandidateRecord record) {
    _memory.remove(cacheKey);
    _memory[cacheKey] = record;
    while (_memory.length > lyricCandidateMemoryCapacity) {
      _memory.remove(_memory.keys.first);
    }
  }

  void _touch(String cacheKey, LyricCandidateRecord record) {
    _remember(cacheKey, record);
  }

  LyricCandidateRecord _emptyRecord(Audio audio, String cacheKey) {
    final now = _clock().millisecondsSinceEpoch;
    return LyricCandidateRecord(
      cacheKey: cacheKey,
      audioPath: audio.path,
      title: audio.title,
      artist: audio.artist,
      album: audio.album,
      durationSec: audio.duration,
      updatedAtMs: now,
      candidates: const [],
    );
  }

  List<LyricCandidate> _limitCandidates(List<LyricCandidate> candidates) {
    final sorted = [...candidates]
      ..sort((a, b) => b.score.compareTo(a.score));
    return sorted.take(lyricCandidateMaxCount).toList(growable: false);
  }

  @visibleForTesting
  void resetForTest() {
    _memory.clear();
    _inflight.clear();
  }
}
