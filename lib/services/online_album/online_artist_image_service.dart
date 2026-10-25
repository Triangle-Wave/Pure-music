import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as path;
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/services/online_album/album_match.dart';
import 'package:pure_music/services/online_album/cn_music_client.dart';
import 'package:pure_music/services/online_album/online_album_service.dart';

/// 艺术家头像服务。
///
/// 按艺术家名搜索网易云、QQ 音乐与酷狗音乐的歌手头像，命中后把 URL
/// 写入 `getAppDataDir()/online_album/artist/`，图片本身复用
/// [OnlineAlbumService.artwork] 的磁盘缓存与解码校验。没有结果时缓存
/// 空结果，避免列表反复请求；所有失败都静默降级为占位图。
class OnlineArtistImageService {
  OnlineArtistImageService._({
    CnMusicClient? cnMusic,
    Future<Directory> Function()? appDataDirectory,
    DateTime Function()? clock,
    Future<ImageProvider?> Function(String url)? artworkLoader,
    this.cacheTtl = onlineAlbumCacheTtl,
  }) : _cnMusic = cnMusic ?? CnMusicClient(),
       _appDataDirectory = appDataDirectory ?? getAppDataDir,
       _clock = clock ?? DateTime.now,
       _artworkLoader =
           artworkLoader ?? OnlineAlbumService.instance.artwork;

  static final OnlineArtistImageService instance =
      OnlineArtistImageService._();

  @visibleForTesting
  static OnlineArtistImageService createForTest({
    CnMusicClient? cnMusic,
    Future<Directory> Function()? appDataDirectory,
    DateTime Function()? clock,
    Future<ImageProvider?> Function(String url)? artworkLoader,
    Duration cacheTtl = onlineAlbumCacheTtl,
  }) {
    return OnlineArtistImageService._(
      cnMusic: cnMusic,
      appDataDirectory: appDataDirectory,
      clock: clock,
      artworkLoader: artworkLoader,
      cacheTtl: cacheTtl,
    );
  }

  final CnMusicClient _cnMusic;
  final Future<Directory> Function() _appDataDirectory;
  final DateTime Function() _clock;
  final Future<ImageProvider?> Function(String url) _artworkLoader;
  final Duration cacheTtl;

  final Map<String, Future<ImageProvider?>> _memory = {};
  final List<Completer<void>> _searchWaiters = [];
  Directory? _cacheDir;
  int _activeSearches = 0;

  Future<ImageProvider?> imageFor(String artistName) {
    if (!AppSettings.instance.onlineArtistImageEnabled) {
      return Future<ImageProvider?>.value();
    }
    final name = artistName.trim();
    if (name.isEmpty) return Future<ImageProvider?>.value();
    final key = cacheKeyForArtist(name);
    final cached = _memory[key];
    if (cached != null) return cached;
    if (_memory.length >= 256) {
      _memory.remove(_memory.keys.first);
    }
    final future = _load(name, key);
    _memory[key] = future;
    return future;
  }

  String cacheKeyForArtist(String artistName) {
    return sha1.convert(utf8.encode(normalizeForMatch(artistName))).toString();
  }

  Future<ImageProvider?> _load(String name, String key) async {
    try {
      final entry = await _readCacheEntry(key);
      if (entry != null) {
        final url = entry.url;
        if (url == null || url.isEmpty) return null;
        return _artworkLoader(url);
      }
      final candidates = await _withSearchSlot(
        () => _cnMusic.searchArtists(name: name),
      );
      final best = pickBestArtistCandidate(
        name: name,
        candidates: candidates,
        aliases: AppSettings.instance.artistAliases,
      );
      final url = best?.picUrl;
      await _writeCacheEntry(key, url);
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

  Future<Directory> _root() async {
    final cached = _cacheDir;
    if (cached != null) return cached;
    final appData = await _appDataDirectory();
    final dir = Directory(
      path.join(appData.path, 'online_album', 'artist'),
    );
    await dir.create(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  Future<File> _cacheFile(String key) async {
    final dir = await _root();
    return File(path.join(dir.path, '$key.json'));
  }

  Future<_ArtistImageCacheEntry?> _readCacheEntry(String key) async {
    try {
      final file = await _cacheFile(key);
      if (!await file.exists()) return null;
      if (_isExpired(await file.lastModified())) {
        await file.delete();
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<dynamic, dynamic>) return null;
      final url = decoded['url'];
      return _ArtistImageCacheEntry(
        url: url is String && url.trim().isNotEmpty ? url.trim() : null,
      );
    } catch (error) {
      log.library.warn(
        'online_artist_image_cache_read_failed',
        '艺术家头像缓存读取失败',
        fields: {'error': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Future<void> _writeCacheEntry(String key, String? url) async {
    try {
      final file = await _cacheFile(key);
      await writeTextFileAtomically(
        file.path,
        jsonEncode({
          'url': url,
          'savedAt': _clock().toIso8601String(),
        }),
      );
    } catch (error) {
      log.library.warn(
        'online_artist_image_cache_write_failed',
        '艺术家头像缓存写入失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
  }

  bool _isExpired(DateTime savedAt) => _clock().difference(savedAt) > cacheTtl;
}

class _ArtistImageCacheEntry {
  const _ArtistImageCacheEntry({required this.url});

  final String? url;
}
