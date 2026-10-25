import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as path;
import 'package:pure_music/core/cache_paths.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/services/online_album/album_match.dart';
import 'package:pure_music/services/online_album/cn_music_client.dart';
import 'package:pure_music/services/online_album/online_album_models.dart';
import 'package:pure_music/services/online_album/online_album_service.dart';

/// 艺术家头像服务。
///
/// 按艺术家名搜索网易云、QQ 音乐与酷狗音乐的歌手头像，把全部候选与当前
/// 选择写入缓存根下的 `online_album/artist/<sha1>.json`。旧位置
/// `<数据根>/online_album/artist` 的文件可继续作为只读回退命中。图片本身由
/// [OnlineAlbumService.artwork] 写入缓存根下的 `covers/` 并返回 `FileImage`，
/// 重启后仍直接读盘。选择“不使用”时不再请求在线图片；所有失败都静默降级为
/// 占位图。
class OnlineArtistImageService {
  OnlineArtistImageService._({
    CnMusicClient? cnMusic,
    Future<Directory> Function()? appDataDirectory,
    Future<Directory> Function()? cacheDirectory,
    DateTime Function()? clock,
    Future<ImageProvider?> Function(String url)? artworkLoader,
    Future<void> Function(String url)? artworkInvalidator,
    this.cacheTtl = onlineAlbumCacheTtl,
  }) : _cnMusic = cnMusic ?? CnMusicClient(),
       _appDataDirectory = appDataDirectory ?? getAppDataDir,
       _cacheDirectory = cacheDirectory,
       _usesAppDataCacheRoot =
           cacheDirectory == null && appDataDirectory != null,
       _clock = clock ?? DateTime.now,
       _artworkLoader =
           artworkLoader ?? OnlineAlbumService.instance.artwork,
       _artworkInvalidator =
           artworkInvalidator ??
           OnlineAlbumService.instance.invalidateArtwork;

  static final OnlineArtistImageService instance =
      OnlineArtistImageService._();

  @visibleForTesting
  static OnlineArtistImageService createForTest({
    CnMusicClient? cnMusic,
    Future<Directory> Function()? appDataDirectory,
    Future<Directory> Function()? cacheDirectory,
    DateTime Function()? clock,
    Future<ImageProvider?> Function(String url)? artworkLoader,
    Future<void> Function(String url)? artworkInvalidator,
    Duration cacheTtl = onlineAlbumCacheTtl,
  }) {
    return OnlineArtistImageService._(
      cnMusic: cnMusic,
      appDataDirectory: appDataDirectory,
      cacheDirectory: cacheDirectory,
      clock: clock,
      artworkLoader: artworkLoader,
      artworkInvalidator: artworkInvalidator,
      cacheTtl: cacheTtl,
    );
  }

  final CnMusicClient _cnMusic;
  final Future<Directory> Function() _appDataDirectory;
  final Future<Directory> Function()? _cacheDirectory;
  final bool _usesAppDataCacheRoot;
  final DateTime Function() _clock;
  final Future<ImageProvider?> Function(String url) _artworkLoader;
  final Future<void> Function(String url) _artworkInvalidator;
  final Duration cacheTtl;

  /// 空候选只保留一天，避免新上架的歌手长期没有头像。
  static const Duration _emptyCacheTtl = Duration(days: 1);

  final Map<String, Future<ImageProvider?>> _memory = {};
  final Map<String, OnlineArtistCandidateCache> _candidateMemory = {};
  final Map<String, Future<OnlineArtistCandidateCache?>> _pendingCandidates =
      {};
  final List<Completer<void>> _searchWaiters = [];
  Directory? _cacheDir;
  int _activeSearches = 0;
  int _selectionRevision = 0;

  /// 选择变化计数；列表项用它作为图片请求标识，保证跨页面同步刷新。
  int get selectionRevision => _selectionRevision;

  Future<ImageProvider?> imageFor(String artistName, {bool force = false}) {
    if (!AppSettings.instance.onlineArtistImageEnabled) {
      return Future<ImageProvider?>.value();
    }
    final name = artistName.trim();
    if (name.isEmpty) return Future<ImageProvider?>.value();
    final key = cacheKeyForArtist(name);
    if (!force) {
      final cached = _memory[key];
      if (cached != null) return cached;
    }
    if (_memory.length >= 256) {
      _memory.remove(_memory.keys.first);
    }
    final future = _load(name, key, force: force);
    _memory[key] = future;
    return future;
  }

  /// 只返回用户显式选择的候选图；自动选择与“不使用”都返回 null，
  /// 让调用方继续本地封面优先的既有逻辑。
  Future<ImageProvider?> preferredImageFor(String artistName) async {
    if (!AppSettings.instance.onlineArtistImageEnabled) return null;
    final name = artistName.trim();
    if (name.isEmpty) return null;
    final key = cacheKeyForArtist(name);
    try {
      final cache = _candidateMemory[key] ?? await _readCacheEntry(key);
      if (cache == null || !cache.hasExplicitSelection) return null;
      final url = cache.activeImageUrl;
      if (url == null || url.isEmpty) return null;
      return _artworkLoader(url);
    } catch (error) {
      log.library.warn(
        'online_artist_selection_failed',
        '读取艺术家头像选择失败',
        fields: {'error': error.runtimeType.toString()},
      );
      return null;
    }
  }

  /// 选中候选的图片下载走与专辑封面相同的磁盘缓存链路。
  Future<ImageProvider?> artwork(String url) => _artworkLoader(url);

  String cacheKeyForArtist(String artistName) {
    return sha1.convert(utf8.encode(normalizeForMatch(artistName))).toString();
  }

  /// 读取艺术家候选与当前选择；缓存缺失或 [force] 为真时重新搜索。
  Future<OnlineArtistCandidateCache?> loadCandidates(
    String artistName, {
    bool force = false,
  }) async {
    final name = artistName.trim();
    if (name.isEmpty) return null;
    if (!AppSettings.instance.onlineArtistImageEnabled) return null;
    return _ensureCandidates(name, cacheKeyForArtist(name), force: force);
  }

  /// 保存用户选择。`candidateId` 为空且 [disabled] 为真表示“不使用”。
  Future<OnlineArtistCandidateCache?> updateSelection(
    String artistName, {
    String? candidateId,
    bool disabled = false,
  }) async {
    final name = artistName.trim();
    if (name.isEmpty) return null;
    final key = cacheKeyForArtist(name);
    final stored = _candidateMemory[key] ?? await _readCacheEntry(key);
    final cache =
        stored ??
        OnlineArtistCandidateCache(
          candidates: const [],
          savedAt: _clock(),
        );
    var resolvedId = disabled ? null : candidateId;
    if (resolvedId != null &&
        !cache.candidates.any((candidate) => candidate.id == resolvedId)) {
      resolvedId = null;
    }
    final updated = cache.withSelection(
      candidateId: resolvedId,
      disabled: disabled,
      savedAt: _clock(),
    );
    await _writeCacheEntry(key, updated);
    _candidateMemory[key] = updated;
    _memory.remove(key);
    _selectionRevision++;
    return updated;
  }

  /// 手动刷新前丢弃该艺术家的内存缓存与在线图片磁盘缓存。
  Future<void> invalidateImage(String artistName) async {
    final name = artistName.trim();
    if (name.isEmpty) return;
    final key = cacheKeyForArtist(name);
    _memory.remove(key);
    _selectionRevision++;
    final cache = _candidateMemory[key] ?? await _readCacheEntry(key);
    final url = cache?.activeImageUrl;
    if (url == null || url.isEmpty) return;
    try {
      await _artworkInvalidator(url);
    } catch (error) {
      log.library.debug(
        'online_artist_image_invalidate_failed',
        '艺术家头像缓存清理失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
  }

  /// 清空艺术家头像候选缓存，供设置页手动清理。
  Future<void> clearCache() async {
    _memory.clear();
    _candidateMemory.clear();
    _pendingCandidates.clear();
    _cacheDir = null;
    _selectionRevision++;
    try {
      final directories = <Directory>[await _root(), ...await _legacyRoots()];
      for (final directory in directories) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    } catch (error) {
      log.library.warn(
        'online_artist_image_cache_clear_failed',
        '艺术家头像缓存清理失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
  }

  Future<ImageProvider?> _load(
    String name,
    String key, {
    bool force = false,
  }) async {
    try {
      final cache = await _ensureCandidates(name, key, force: force);
      final url = cache?.activeImageUrl;
      if (url == null || url.isEmpty) return null;
      return _artworkLoader(url);
    } catch (error) {
      log.library.warn(
        'online_artist_image_failed',
        '在线艺术家头像获取失败',
        fields: {'error': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Future<OnlineArtistCandidateCache?> _ensureCandidates(
    String name,
    String key, {
    required bool force,
  }) async {
    final pending = _pendingCandidates[key];
    if (pending != null) {
      if (!force) return pending;
      await pending;
    }
    final request = _loadCandidateCache(name, key, force: force);
    _pendingCandidates[key] = request;
    unawaited(
      request.whenComplete(() {
        if (identical(_pendingCandidates[key], request)) {
          _pendingCandidates.remove(key);
        }
      }),
    );
    return request;
  }

  Future<OnlineArtistCandidateCache?> _loadCandidateCache(
    String name,
    String key, {
    required bool force,
  }) async {
    OnlineArtistCandidateCache? previous;
    try {
      previous = _candidateMemory[key] ?? await _readCacheEntry(key);
    } catch (error) {
      log.library.warn(
        'online_artist_image_cache_read_failed',
        '艺术家头像缓存读取失败',
        fields: {'error': error.runtimeType.toString()},
      );
      previous = null;
    }
    if (!force && previous != null) return previous;

    List<CnArtistCandidate> candidates;
    try {
      candidates = await _withSearchSlot(
        () => _cnMusic.searchArtists(name: name),
      );
    } catch (error) {
      log.library.warn(
        'online_artist_image_search_failed',
        '艺术家头像搜索失败',
        fields: {'error': error.runtimeType.toString()},
      );
      return previous;
    }

    final aliases = AppSettings.instance.artistAliases;
    final ranked = <OnlineArtistCandidate>[];
    for (final candidate in candidates) {
      final pic = candidate.picUrl;
      if (pic == null || pic.isEmpty) continue;
      final score = artistNameSimilarity(
        name,
        candidate.name,
        aliases: aliases,
      );
      ranked.add(
        OnlineArtistCandidate(
          id: 'cn:${candidate.source.name}:${candidate.id}',
          source: candidate.source.label,
          name: candidate.name,
          imageUrl: pic,
          albumCount: candidate.albumCount,
          score: score,
        ),
      );
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));

    if (ranked.isEmpty && previous != null) return previous;

    final selectedId = previous?.selectedCandidateId;
    final stillExists =
        selectedId != null &&
        ranked.any((candidate) => candidate.id == selectedId);
    final cache = OnlineArtistCandidateCache(
      candidates: List.unmodifiable(ranked),
      selectedCandidateId: stillExists ? selectedId : null,
      disabled: previous?.disabled ?? false,
      savedAt: _clock(),
    );
    await _writeCacheEntry(key, cache);
    _candidateMemory[key] = cache;
    return cache;
  }

  /// 列表里可能同时出现大量艺术家；限制同时进行的搜索数量，
  /// 避免打开页面时瞬间向三个源发出数百个请求。
  Future<T> _withSearchSlot<T>(Future<T> Function() action) async {
    while (_activeSearches >= 3) {
      final waiter = Completer<void>();
      _searchWaiters.add(waiter);
      await waiter.future;
    }
    _activeSearches++;
    try {
      return await action();
    } finally {
      _activeSearches--;
      if (_searchWaiters.isNotEmpty) {
        _searchWaiters.removeAt(0).complete();
      }
    }
  }

  /// 缓存根设置变化后调用，下一次访问重新解析目录。
  void invalidateCacheRoot() {
    _cacheDir = null;
  }

  Future<Directory> _root() async {
    final cached = _cacheDir;
    if (cached != null) return cached;
    final Directory dir;
    final provider = _cacheDirectory;
    if (provider != null) {
      dir = await provider();
    } else if (_usesAppDataCacheRoot) {
      final appData = await _appDataDirectory();
      dir = Directory(path.join(appData.path, 'online_album', 'artist'));
    } else {
      dir = await getOnlineAlbumArtistCacheDirectory();
    }
    await dir.create(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  /// 旧缓存位置：`<数据根>/online_album/artist` 与更早的
  /// `<数据根>/cache/online_album/artist`；新写入始终落在当前缓存根。
  Future<List<Directory>> _legacyRoots() async {
    try {
      final appData = await _appDataDirectory();
      final current = await _root();
      final candidates = <Directory>[
        Directory(path.join(appData.path, 'online_album', 'artist')),
        Directory(path.join(appData.path, 'cache', 'online_album', 'artist')),
      ];
      final result = <Directory>[];
      for (final candidate in candidates) {
        if (path.equals(candidate.path, current.path)) continue;
        result.add(candidate);
      }
      return result;
    } catch (error) {
      log.library.debug(
        'online_artist_image_cache_read_failed',
        '旧艺术家头像缓存目录不可用',
        fields: {'error': error.runtimeType.toString()},
      );
      return const <Directory>[];
    }
  }

  Future<File> _cacheFile(String key) async {
    final dir = await _root();
    return File(path.join(dir.path, '$key.json'));
  }

  Future<List<File>> _legacyCacheFiles(String key) async {
    try {
      final files = <File>[];
      for (final root in await _legacyRoots()) {
        final file = File(path.join(root.path, '$key.json'));
        if (await file.exists()) files.add(file);
      }
      return files;
    } catch (error) {
      log.library.debug(
        'online_artist_image_cache_read_failed',
        '旧艺术家头像缓存不可用',
        fields: {'error': error.runtimeType.toString()},
      );
      return const <File>[];
    }
  }

  Future<OnlineArtistCandidateCache?> _readCacheEntry(String key) async {
    try {
      final file = await _cacheFile(key);
      if (await file.exists()) return _readCacheFile(file);
      for (final legacy in await _legacyCacheFiles(key)) {
        final cache = await _readCacheFile(legacy);
        if (cache != null) return cache;
      }
      return null;
    } catch (error) {
      log.library.warn(
        'online_artist_image_cache_read_failed',
        '艺术家头像缓存读取失败',
        fields: {'error': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Future<OnlineArtistCandidateCache?> _readCacheFile(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      final cache = OnlineArtistCandidateCache.fromJson(decoded);
      if (cache == null) {
        await _deleteCacheFile(file);
        return null;
      }
      final savedAt = await file.lastModified();
      final emptyAutomatic =
          cache.candidates.isEmpty &&
          !cache.disabled &&
          cache.selectedCandidateId == null;
      if (_isExpired(savedAt, emptyAutomatic)) {
        await _deleteCacheFile(file);
        return null;
      }
      return cache;
    } catch (error) {
      log.library.warn(
        'online_artist_image_cache_read_failed',
        '艺术家头像缓存读取失败',
        fields: {'error': error.runtimeType.toString()},
      );
      try {
        if (await file.exists()) await file.delete();
      } catch (deleteError) {
        log.library.debug(
          'online_artist_image_cache_delete_failed',
          '损坏的艺术家头像缓存删除失败',
          fields: {'error': deleteError.runtimeType.toString()},
        );
      }
      return null;
    }
  }

  Future<void> _writeCacheEntry(
    String key,
    OnlineArtistCandidateCache cache,
  ) async {
    try {
      final file = await _cacheFile(key);
      await writeTextFileAtomically(file.path, jsonEncode(cache.toJson()));
    } catch (error) {
      log.library.warn(
        'online_artist_image_cache_write_failed',
        '艺术家头像缓存写入失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
  }

  Future<void> _deleteCacheFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      log.library.debug(
        'online_artist_image_cache_delete_failed',
        '艺术家头像缓存清理失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
  }

  bool _isExpired(DateTime savedAt, bool emptyAutomatic) {
    final ttl = emptyAutomatic ? _emptyCacheTtl : cacheTtl;
    return _clock().difference(savedAt) > ttl;
  }
}
