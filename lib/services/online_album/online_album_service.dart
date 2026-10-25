import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as path;
import 'package:pure_music/core/app_http.dart';
import 'package:pure_music/core/cover_disk_cache.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/services/online_album/album_match.dart';
import 'package:pure_music/services/online_album/cn_music_client.dart';
import 'package:pure_music/services/online_album/cover_art_client.dart';
import 'package:pure_music/services/online_album/musicbrainz_client.dart';
import 'package:pure_music/services/online_album/online_album_models.dart';

export 'package:pure_music/services/online_album/album_match.dart';
export 'package:pure_music/services/online_album/online_album_models.dart';

/// 专辑信息与候选默认长期保留；只有用户主动刷新或清理缓存才重新请求。
const Duration onlineAlbumCacheTtl = Duration(days: 365);

/// 在线专辑信息服务。
///
/// 每次查询把全部候选写入 `<数据根>/online_album/candidates/<sha1>.json`，
/// 同文件记录当前选择（`selectedCandidateId` 或 `disabled`）。命中缓存时
/// 不再发网络请求，只有 [loadCandidates] / [lookup] 传入 `force: true` 才
/// 重新查询并保留用户选择。封面图片由 [CoverDiskCache] 统一写入
/// `<数据根>/cache/covers/`，同一进程与磁盘有效期内都不再下载。
/// 网络、文件与 JSON 错误都降级为“暂无信息”，不会把错误抛到界面。
class OnlineAlbumService {
  OnlineAlbumService._({
    MusicBrainzClient? musicBrainz,
    CoverArtClient? coverArt,
    CnMusicClient? cnMusic,
    Future<Directory> Function()? appDataDirectory,
    DateTime Function()? clock,
    CoverDiskCache? coverDiskCache,
    this.cacheTtl = onlineAlbumCacheTtl,
  }) : _musicBrainz = musicBrainz ?? MusicBrainzClient(),
       _coverArt = coverArt ?? CoverArtClient(),
       _cnMusic = cnMusic ?? CnMusicClient(),
       _appDataDirectory = appDataDirectory ?? getAppDataDir,
       _clock = clock ?? DateTime.now,
       _coverDiskCache = coverDiskCache ?? CoverDiskCache.instance;

  static final OnlineAlbumService instance = OnlineAlbumService._();

  @visibleForTesting
  static OnlineAlbumService createForTest({
    MusicBrainzClient? musicBrainz,
    CoverArtClient? coverArt,
    CnMusicClient? cnMusic,
    Future<Directory> Function()? appDataDirectory,
    DateTime Function()? clock,
    CoverDiskCache? coverDiskCache,
    Duration cacheTtl = onlineAlbumCacheTtl,
  }) {
    return OnlineAlbumService._(
      musicBrainz: musicBrainz,
      coverArt: coverArt,
      cnMusic: cnMusic,
      appDataDirectory: appDataDirectory,
      clock: clock,
      coverDiskCache: coverDiskCache,
      cacheTtl: cacheTtl,
    );
  }

  final MusicBrainzClient _musicBrainz;
  final CoverArtClient _coverArt;
  final CnMusicClient _cnMusic;
  final Future<Directory> Function() _appDataDirectory;
  final DateTime Function() _clock;
  final CoverDiskCache _coverDiskCache;
  final Duration cacheTtl;

  final Map<String, Future<OnlineAlbumCandidateCache?>> _pendingLookups = {};
  final Map<String, OnlineAlbumCandidateCache> _albumMemory = {};
  final Map<String, Future<ImageProvider?>> _artworkMemory = {};
  Directory? _rootDir;

  String cacheKeyForAlbum(Album album) {
    final raw = [
      normalizeForMatch(album.name),
      normalizeForMatch(albumArtistFor(album)),
      '${album.works.length}',
      '${extractAlbumYearHint(album) ?? ''}',
    ].join('|');
    return sha1.convert(utf8.encode(raw)).toString();
  }

  Future<OnlineAlbumInfo?> lookup(Album album, {bool force = false}) async {
    final cache = await loadCandidates(album, force: force);
    return cache?.info;
  }

  /// 读取专辑候选与当前选择；缓存缺失或 [force] 为真时重新查询。
  Future<OnlineAlbumCandidateCache?> loadCandidates(
    Album album, {
    bool force = false,
  }) async {
    if (!AppSettings.instance.onlineAlbumInfoEnabled) {
      return null;
    }
    final key = cacheKeyForAlbum(album);
    final pending = _pendingLookups[key];
    if (pending != null) {
      if (!force) return pending;
      await pending;
    }
    if (!force) {
      final memory = _albumMemory[key];
      if (memory != null) return memory;
    }
    final request = _loadCandidates(album, key, force: force);
    _pendingLookups[key] = request;
    unawaited(
      request.whenComplete(() {
        if (identical(_pendingLookups[key], request)) {
          _pendingLookups.remove(key);
        }
      }),
    );
    return request;
  }

  /// 保存用户选择。`candidateId` 为空且 [disabled] 为真表示“不使用”。
  Future<OnlineAlbumCandidateCache?> updateSelection(
    Album album, {
    String? candidateId,
    bool disabled = false,
  }) async {
    final key = cacheKeyForAlbum(album);
    final stored = _albumMemory[key] ?? await _readCandidateCache(key);
    final cache =
        stored ??
        OnlineAlbumCandidateCache(
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
    await _writeCandidateCache(key, updated);
    _albumMemory[key] = updated;
    _pendingLookups.remove(key);
    return updated;
  }

  Future<ImageProvider?> artwork(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return Future<ImageProvider?>.value();
    final cached = _artworkMemory[trimmed];
    if (cached != null) return cached;
    final future = _loadArtwork(trimmed);
    if (_artworkMemory.length >= 64) {
      _artworkMemory.remove(_artworkMemory.keys.first);
    }
    _artworkMemory[trimmed] = future;
    unawaited(
      future.then<void>((provider) {
        if (provider == null && identical(_artworkMemory[trimmed], future)) {
          _artworkMemory.remove(trimmed);
        }
      }),
    );
    return future;
  }

  /// 手动刷新时丢弃单张在线封面的磁盘与内存缓存，下一次显示重新下载。
  Future<void> invalidateArtwork(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    _artworkMemory.remove(trimmed);
    try {
      await _coverDiskCache.deleteNetworkImage(trimmed);
    } catch (error) {
      log.library.debug(
        'online_album_artwork_invalidate_failed',
        '在线封面缓存清理失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
  }

  /// 清空在线专辑信息、候选与在线图片缓存，供设置页手动清理。
  Future<void> clearCache() async {
    _albumMemory.clear();
    _pendingLookups.clear();
    _artworkMemory.clear();
    try {
      final root = await _root();
      for (final name in const ['candidates', 'info']) {
        final directory = Directory(path.join(root.path, name));
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    } catch (error) {
      log.library.warn(
        'online_album_cache_clear_failed',
        '在线专辑缓存清理失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
    try {
      await _coverDiskCache.clearNetworkImages();
    } catch (error) {
      log.library.warn(
        'online_album_artwork_clear_failed',
        '在线封面缓存清理失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
  }

  Future<OnlineAlbumCandidateCache?> _loadCandidates(
    Album album,
    String key, {
    required bool force,
  }) async {
    OnlineAlbumCandidateCache? previous;
    try {
      previous = _albumMemory[key] ?? await _readCandidateCache(key);
    } catch (error) {
      log.library.warn(
        'online_album_cache_read_failed',
        '在线专辑缓存读取失败',
        fields: {'error': error.runtimeType.toString()},
      );
      previous = null;
    }
    if (!force && previous != null) return previous;

    final fetched = await _fetchCandidatesSafely(album);
    if (fetched == null || fetched.isEmpty) {
      // 网络失败或没有结果时继续使用旧缓存，避免刷新把已有信息清空。
      return previous;
    }
    final selectedId = previous?.selectedCandidateId;
    final stillExists =
        selectedId != null &&
        fetched.any((candidate) => candidate.id == selectedId);
    final cache = OnlineAlbumCandidateCache(
      candidates: List.unmodifiable(fetched),
      selectedCandidateId: stillExists ? selectedId : null,
      disabled: previous?.disabled ?? false,
      savedAt: _clock(),
    );
    await _writeCandidateCache(key, cache);
    _albumMemory[key] = cache;
    return cache;
  }

  Future<OnlineAlbumCandidateCache?> _readCandidateCache(String key) async {
    try {
      final file = await _candidateFile(key);
      if (!await file.exists()) return null;
      final modified = await file.lastModified();
      final decoded = jsonDecode(await file.readAsString());
      final cache = OnlineAlbumCandidateCache.fromJson(decoded);
      if (cache == null) {
        await _deleteCacheFile(file, 'invalid');
        return null;
      }
      final savedAt = cache.savedAt ?? modified;
      if (_isExpired(savedAt)) {
        await _deleteCacheFile(file, 'expired');
        return null;
      }
      return cache;
    } catch (error) {
      log.library.warn(
        'online_album_cache_read_failed',
        '在线专辑缓存读取失败',
        fields: {'error': error.runtimeType.toString()},
      );
      try {
        final file = await _candidateFile(key);
        if (await file.exists()) await file.delete();
      } catch (deleteError) {
        log.library.debug(
          'online_album_cache_delete_failed',
          '损坏的在线专辑缓存删除失败',
          fields: {'error': deleteError.runtimeType.toString()},
        );
      }
      return null;
    }
  }

  Future<void> _writeCandidateCache(
    String key,
    OnlineAlbumCandidateCache cache,
  ) async {
    try {
      final file = await _candidateFile(key);
      await writeTextFileAtomically(file.path, jsonEncode(cache.toJson()));
    } catch (error) {
      log.library.warn(
        'online_album_cache_write_failed',
        '在线专辑缓存写入失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
  }

  Future<void> _deleteCacheFile(File file, String reason) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      log.library.debug(
        'online_album_cache_delete_failed',
        '在线专辑缓存清理失败',
        fields: {
          'reason': reason,
          'error': error.runtimeType.toString(),
        },
      );
    }
  }

  Future<List<OnlineAlbumCandidate>?> _fetchCandidatesSafely(Album album) async {
    try {
      final result = await _fetchCandidates(album);
      return result;
    } catch (error) {
      log.library.warn(
        'online_album_fetch_failed',
        '在线专辑候选查询失败',
        fields: {'error': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Future<List<OnlineAlbumCandidate>?> _fetchCandidates(Album album) async {
    final title = album.name.trim();
    if (title.isEmpty || album.works.isEmpty) {
      return const <OnlineAlbumCandidate>[];
    }
    final artist = albumArtistFor(album);
    final trackCount = album.works.length;
    final yearHint = extractAlbumYearHint(album);

    final cnCandidates = await _fetchCnCandidates(
      title: title,
      artist: artist,
      trackCount: trackCount,
      yearHint: yearHint,
    );
    cnCandidates.sort((a, b) => b.score.compareTo(a.score));
    final bestCn = cnCandidates.isEmpty ? null : cnCandidates.first;
    if (bestCn != null && bestCn.score >= minimumOnlineAlbumScore) {
      return cnCandidates;
    }

    final mbCandidates = await _fetchMusicBrainzCandidates(
      title: title,
      artist: artist,
      trackCount: trackCount,
      yearHint: yearHint,
    );
    if (mbCandidates == null) {
      return cnCandidates.isEmpty ? null : cnCandidates;
    }
    final merged = <OnlineAlbumCandidate>[...cnCandidates, ...mbCandidates]
      ..sort((a, b) => b.score.compareTo(a.score));
    return merged;
  }

  Future<List<OnlineAlbumCandidate>> _fetchCnCandidates({
    required String title,
    required String artist,
    required int trackCount,
    required int? yearHint,
  }) async {
    List<CnAlbumCandidate> candidates;
    try {
      candidates = await _cnMusic.searchAlbums(title: title, artist: artist);
    } catch (error) {
      log.library.debug(
        'online_album_cn_search_failed',
        '国内音乐源搜索失败',
        fields: {'error': error.runtimeType.toString()},
      );
      return const <OnlineAlbumCandidate>[];
    }
    final aliases = AppSettings.instance.artistAliases;
    final result = <OnlineAlbumCandidate>[];
    for (final candidate in candidates) {
      final score = scoreCnAlbumCandidate(
        albumTitle: title,
        artist: artist,
        trackCount: trackCount,
        yearHint: yearHint,
        candidate: candidate,
        aliases: aliases,
      );
      final candidateArtist = candidate.artist.trim().isEmpty
          ? artist
          : candidate.artist;
      final year = candidate.year ?? yearHint;
      final coverUrl = candidate.coverUrl;
      final id = 'cn:${candidate.source.name}:${candidate.id}';
      final covers = coverUrl == null || coverUrl.isEmpty
          ? CoverArtSet.empty
          : CoverArtSet(
              front: CoverArtImage(
                url: coverUrl,
                largeUrl: null,
                front: true,
                back: false,
                types: const ['front'],
              ),
            );
      result.add(
        OnlineAlbumCandidate(
          id: id,
          source: candidate.source.label,
          title: candidate.title,
          artist: candidateArtist,
          year: year,
          trackCount: candidate.trackCount,
          imageUrl: coverUrl,
          score: score,
          info: OnlineAlbumInfo(
            releaseGroupId: id,
            title: candidate.title,
            artist: candidateArtist,
            year: year,
            summary: buildOnlineAlbumSummary(
              primaryType: 'Album',
              secondaryTypes: const [],
              releaseDate: null,
              trackCount: candidate.trackCount,
            ),
            trackCount: candidate.trackCount,
            source: candidate.source.label,
            covers: covers,
          ),
        ),
      );
    }
    return result;
  }

  /// MusicBrainz 候选。返回 null 表示请求失败；返回空列表表示确实无结果。
  Future<List<OnlineAlbumCandidate>?> _fetchMusicBrainzCandidates({
    required String title,
    required String artist,
    required int trackCount,
    required int? yearHint,
  }) async {
    List<MbReleaseGroup> groups;
    try {
      groups = await _musicBrainz.searchReleaseGroups(
        release: title,
        artist: artist,
      );
    } catch (error) {
      log.library.debug(
        'online_album_musicbrainz_search_failed',
        'MusicBrainz 搜索失败',
        fields: {'error': error.runtimeType.toString()},
      );
      return null;
    }
    if (groups.isEmpty) return const <OnlineAlbumCandidate>[];

    final ranked = <_RankedGroup>[
      for (final group in groups.take(8))
        _RankedGroup(
          group: group,
          score: scoreReleaseGroupCandidate(
            albumTitle: title,
            artist: artist,
            trackCount: trackCount,
            yearHint: yearHint,
            group: group,
          ),
        ),
    ]..sort((a, b) => b.score.compareTo(a.score));

    final finalists = ranked.take(2).toList();
    for (final candidate in finalists) {
      try {
        final releases = await _musicBrainz.browseReleases(candidate.group.id);
        candidate.release = pickBestRelease(releases, trackCount);
      } on MusicBrainzException catch (error) {
        log.library.debug(
          'online_album_candidate_release_failed',
          '候选发行版查询失败',
          fields: {'error': error.runtimeType.toString()},
        );
      }
      candidate.score = scoreReleaseGroupCandidate(
        albumTitle: title,
        artist: artist,
        trackCount: trackCount,
        yearHint: yearHint,
        group: candidate.group,
        candidateTrackCount: candidate.release?.trackCount,
      );
    }
    finalists.sort((a, b) => b.score.compareTo(a.score));
    final best = finalists.first;

    MbReleaseDetail? detail;
    final release = best.release;
    if (release != null) {
      try {
        detail = await _musicBrainz.lookupRelease(release.id);
      } on MusicBrainzException catch (error) {
        detail = null;
        log.library.debug(
          'online_album_release_detail_failed',
          '发行版详情查询失败',
          fields: {'error': error.runtimeType.toString()},
        );
      }
    }
    final covers = await _coverArt.fetch(
      releaseGroupId: best.group.id,
      releaseId: release?.id,
    );

    final result = <OnlineAlbumCandidate>[];
    for (final candidate in ranked) {
      final isBest = identical(candidate, best);
      result.add(
        _buildMusicBrainzCandidate(
          candidate: candidate,
          fallbackArtist: artist,
          yearHint: yearHint,
          detail: isBest ? detail : null,
          covers: isBest ? covers : null,
        ),
      );
    }
    result.sort((a, b) => b.score.compareTo(a.score));
    return result;
  }

  OnlineAlbumCandidate _buildMusicBrainzCandidate({
    required _RankedGroup candidate,
    required String fallbackArtist,
    required int? yearHint,
    required MbReleaseDetail? detail,
    required CoverArtSet? covers,
  }) {
    final group = candidate.group;
    final release = candidate.release;
    final genreValues = <String>[
      ...group.genres,
      ...group.tags,
      ...?detail?.genres,
      ...?detail?.tags,
    ];
    final genre = genreValues.isEmpty
        ? null
        : genreValues.toSet().take(3).join(' / ');
    final labels = detail?.labels ?? const <String>[];
    final label = labels.isEmpty ? null : labels.first;
    final year =
        yearFromDate(group.firstReleaseDate) ??
        yearFromDate(detail?.date) ??
        yearHint;
    final releaseDate = group.firstReleaseDate ?? detail?.date;
    final resolvedTrackCount =
        detail?.trackCount ?? release?.trackCount ?? candidate.releaseTrackCount;
    final summary = buildOnlineAlbumSummary(
      primaryType: group.primaryType,
      secondaryTypes: group.secondaryTypes,
      releaseDate: releaseDate,
      trackCount: resolvedTrackCount,
    );
    final coversForCandidate =
        covers ??
        CoverArtSet(
          front: CoverArtImage(
            url:
                '$coverArtArchiveBaseUrl/release-group/'
                '${Uri.encodeComponent(group.id)}/front-500',
            largeUrl: null,
            front: true,
            back: false,
            types: const ['front'],
          ),
        );
    final artist = group.artistNames.isNotEmpty
        ? group.artistNames.join(' / ')
        : fallbackArtist;
    return OnlineAlbumCandidate(
      id: 'mb:${group.id}',
      source: 'MusicBrainz',
      title: group.title,
      artist: artist,
      year: year,
      trackCount: resolvedTrackCount,
      imageUrl: coversForCandidate.front?.url,
      score: candidate.score,
      info: OnlineAlbumInfo(
        releaseGroupId: group.id,
        title: group.title,
        artist: artist,
        year: year,
        label: label,
        genre: genre,
        summary: summary,
        trackCount: resolvedTrackCount,
        primaryType: group.primaryType,
        secondaryTypes: group.secondaryTypes,
        covers: coversForCandidate,
        source: 'MusicBrainz',
      ),
    );
  }

  Future<Directory> _root() async {
    final cached = _rootDir;
    if (cached != null) return cached;
    final appData = await _appDataDirectory();
    final dir = Directory(path.join(appData.path, 'online_album'));
    await dir.create(recursive: true);
    _rootDir = dir;
    return dir;
  }

  Future<File> _candidateFile(String key) async {
    final dir = Directory(path.join((await _root()).path, 'candidates'));
    await dir.create(recursive: true);
    return File(path.join(dir.path, '$key.json'));
  }

  Future<ImageProvider?> _loadArtwork(String url) async {
    try {
      final cached = await _coverDiskCache.findNetworkImage(
        url,
        ttl: cacheTtl,
      );
      if (cached != null) return FileImage(cached);
      final bytes = await _downloadBytes(url);
      if (bytes == null) return null;
      if (!await canDecodeImageBytes(bytes)) {
        log.library.warn(
          'online_album_artwork_invalid',
          '在线封面不是可解码的图片，已忽略',
          fields: {'stage': 'download', 'bytes': bytes.length},
        );
        return null;
      }
      final file = await _coverDiskCache.storeNetworkImage(url, bytes);
      if (file != null) return FileImage(file);
      // 磁盘不可用时保留原链路：本次仍用内存图显示。
      return MemoryImage(bytes);
    } catch (error) {
      log.library.warn(
        'online_album_artwork_failed',
        '在线封面读取失败',
        fields: {'stage': 'artwork', 'error': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Future<Uint8List?> _downloadBytes(String url) async {
    try {
      final response = await AppHttp.instance.dio.get<List<int>>(
        url,
        options: Options(
          headers: _artworkHeaders(url),
          responseType: ResponseType.bytes,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          validateStatus: (status) =>
              status != null && status >= 200 && status < 300,
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;
      return Uint8List.fromList(bytes);
    } on DioException catch (error) {
      log.library.warn(
        'online_album_artwork_failed',
        '在线封面下载失败',
        fields: {'stage': 'download', 'error': error.type.name},
      );
      return null;
    }
  }

  /// 国内图片源对 Referer 有校验；按域名补齐，避免封面被 403。
  Map<String, String> _artworkHeaders(String url) {
    final headers = <String, String>{
      'User-Agent': musicBrainzUserAgent,
      'Accept': 'image/*',
    };
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.endsWith('music.126.net') || host.endsWith('music.163.com')) {
      headers['Referer'] = 'https://music.163.com/';
    } else if (host.endsWith('gtimg.cn') || host.endsWith('qq.com')) {
      headers['Referer'] = 'https://y.qq.com/';
    } else if (host.endsWith('kugou.com')) {
      headers['Referer'] = 'https://www.kugou.com/';
    }
    return headers;
  }

  bool _isExpired(DateTime savedAt) => _clock().difference(savedAt) > cacheTtl;
}

class _RankedGroup {
  _RankedGroup({required this.group, required this.score});

  final MbReleaseGroup group;
  double score;
  MbRelease? release;

  int? get releaseTrackCount => release?.trackCount;
}

String albumArtistFor(Album album) {
  for (final audio in album.works) {
    final albumArtist = audio.albumArtist?.trim();
    if (albumArtist != null && albumArtist.isNotEmpty) return albumArtist;
  }
  for (final name in album.artistsMap.keys) {
    if (name.trim().isNotEmpty) return name.trim();
  }
  if (album.works.isNotEmpty) return album.works.first.artist;
  return '';
}

/// 从专辑名、首曲路径与首曲标题中提取 4 位年份，作为候选打分的辅助信号。
///
/// `Audio` 模型不保存发行年份，因此这里只使用文件名与目录名里常见的年份写法。
int? extractAlbumYearHint(Album album) {
  return extractYearHintFromTexts([
    album.name,
    if (album.primaryPath != null) album.primaryPath!,
    for (final audio in album.works.take(1)) audio.title,
  ]);
}

int? extractYearHintFromTexts(Iterable<String> texts) {
  final pattern = RegExp(r'(?:^|[^0-9])((?:19|20)\d{2})(?![0-9])');
  for (final text in texts) {
    if (text.trim().isEmpty) continue;
    int? year;
    for (final match in pattern.allMatches(text)) {
      final value = int.tryParse(match.group(1)!);
      if (value != null && value >= 1900 && value <= 2100) year = value;
    }
    if (year != null) return year;
  }
  return null;
}

double scoreReleaseGroupCandidate({
  required String albumTitle,
  required String artist,
  required int trackCount,
  required int? yearHint,
  required MbReleaseGroup group,
  int? candidateTrackCount,
}) {
  final titleScore = albumTitleSimilarity(albumTitle, group.title);
  final artistScore = albumArtistSimilarity(artist, group.artistNames);
  var score = titleScore * 55 + artistScore * 25;
  if (titleScore >= 0.999) score += 12;
  if (artistScore >= 0.999) score += 8;
  if (artist.trim().isNotEmpty &&
      group.artistNames.isNotEmpty &&
      artistScore < 0.5) {
    score -= 30;
  }
  final candidateYear = yearFromDate(group.firstReleaseDate);
  if (yearHint != null && candidateYear != null) {
    final diff = (yearHint - candidateYear).abs();
    score += diff == 0
        ? 12
        : diff == 1
        ? 6
        : diff <= 3
        ? 2
        : -6;
  }
  if (candidateTrackCount != null && trackCount > 0) {
    final diff = (candidateTrackCount - trackCount).abs();
    score += diff == 0
        ? 18
        : diff <= 1
        ? 12
        : diff <= 2
        ? 7
        : diff <= 4
        ? 2
        : -6;
  }
  return score;
}

MbRelease? pickBestRelease(List<MbRelease> releases, int localTrackCount) {
  if (releases.isEmpty) return null;
  MbRelease? best;
  var bestScore = double.negativeInfinity;
  for (final release in releases) {
    var score = 0.0;
    if ((release.status ?? '').toLowerCase() == 'official') score += 6;
    final tracks = release.trackCount;
    if (tracks != null && localTrackCount > 0) {
      final diff = (tracks - localTrackCount).abs();
      score += diff == 0
          ? 10
          : diff <= 1
          ? 7
          : diff <= 2
          ? 5
          : diff <= 4
          ? 2
          : -6;
    }
    final year = yearFromDate(release.date);
    if (year != null) score -= year / 10000;
    if (score > bestScore) {
      bestScore = score;
      best = release;
    }
  }
  return best;
}

String? buildOnlineAlbumSummary({
  required String? primaryType,
  required List<String> secondaryTypes,
  required String? releaseDate,
  required int? trackCount,
}) {
  final parts = <String>[];
  if (primaryType != null && primaryType.isNotEmpty) {
    final secondary = secondaryTypes
        .where((type) => type.trim().isNotEmpty)
        .join(' / ');
    parts.add(secondary.isEmpty ? primaryType : '$primaryType（$secondary）');
  }
  if (releaseDate != null && releaseDate.isNotEmpty) {
    parts.add(releaseDate);
  }
  if (trackCount != null && trackCount > 0) parts.add('$trackCount 首');
  return parts.isEmpty ? null : parts.join(' · ');
}

/// 校验字节是否为可解码的图片。
///
/// Cover Art Archive 在异常时可能返回 HTML 或截断的图片数据；这些内容
/// 交给 `Image` 时才报 `Could not decompress image.`。在写入缓存与设置
/// 主封面之前先解码一次，损坏内容直接丢弃。
Future<bool> canDecodeImageBytes(Uint8List bytes) async {
  if (bytes.isEmpty) return false;
  ui.Codec? codec;
  ui.FrameInfo? frame;
  try {
    final activeCodec = await ui.instantiateImageCodec(bytes);
    codec = activeCodec;
    final activeFrame = await activeCodec.getNextFrame();
    frame = activeFrame;
    return activeFrame.image.width > 0 && activeFrame.image.height > 0;
  } catch (error) {
    log.library.debug(
      'online_album_artwork_decode_failed',
      '在线封面解码校验失败',
      fields: {
        'bytes': bytes.length,
        'error': error.runtimeType.toString(),
      },
    );
    return false;
  } finally {
    frame?.image.dispose();
    codec?.dispose();
  }
}
