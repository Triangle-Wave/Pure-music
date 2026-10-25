import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as path;
import 'package:pure_music/core/app_http.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/services/online_album/cover_art_client.dart';
import 'package:pure_music/services/online_album/musicbrainz_client.dart';

/// 达到该分数才认为找到了可信的在线专辑，避免把同名合辑当成目标专辑。
const double minimumOnlineAlbumScore = 60;

const Duration onlineAlbumCacheTtl = Duration(days: 7);

class OnlineAlbumArtwork {
  const OnlineAlbumArtwork({
    required this.url,
    required this.role,
    required this.label,
  });

  final String url;

  /// `front`、`back` 或 `booklet`。
  final String role;
  final String label;
}

class OnlineAlbumInfo {
  const OnlineAlbumInfo({
    required this.releaseGroupId,
    required this.title,
    this.artist,
    this.year,
    this.label,
    this.genre,
    this.summary,
    this.trackCount,
    this.primaryType,
    this.secondaryTypes = const [],
    this.covers = CoverArtSet.empty,
  });

  final String releaseGroupId;
  final String title;
  final String? artist;
  final int? year;
  final String? label;
  final String? genre;
  final String? summary;
  final int? trackCount;
  final String? primaryType;
  final List<String> secondaryTypes;
  final CoverArtSet covers;

  List<OnlineAlbumArtwork> get artworks {
    final result = <OnlineAlbumArtwork>[];
    final front = covers.front;
    if (front != null) {
      result.add(
        OnlineAlbumArtwork(url: front.url, role: 'front', label: '封面'),
      );
    }
    final back = covers.back;
    if (back != null) {
      result.add(OnlineAlbumArtwork(url: back.url, role: 'back', label: '封底'));
    }
    for (var i = 0; i < covers.booklets.length; i++) {
      result.add(
        OnlineAlbumArtwork(
          url: covers.booklets[i].url,
          role: 'booklet',
          label: '内页 ${i + 1}',
        ),
      );
    }
    return List.unmodifiable(result);
  }

  Map<String, Object?> toJson() => {
    'releaseGroupId': releaseGroupId,
    'title': title,
    'artist': artist,
    'year': year,
    'label': label,
    'genre': genre,
    'summary': summary,
    'trackCount': trackCount,
    'primaryType': primaryType,
    'secondaryTypes': secondaryTypes,
    'covers': covers.toJson(),
  };

  static OnlineAlbumInfo? fromJson(Object? data) {
    if (data is! Map<dynamic, dynamic>) return null;
    final releaseGroupId = _text(data['releaseGroupId']);
    final title = _text(data['title']);
    if (releaseGroupId == null || title == null) return null;
    return OnlineAlbumInfo(
      releaseGroupId: releaseGroupId,
      title: title,
      artist: _text(data['artist']),
      year: _number(data['year']),
      label: _text(data['label']),
      genre: _text(data['genre']),
      summary: _text(data['summary']),
      trackCount: _number(data['trackCount']),
      primaryType: _text(data['primaryType']),
      secondaryTypes: _textList(data['secondaryTypes']),
      covers: CoverArtSet.fromJson(data['covers']),
    );
  }
}

/// 在线专辑信息服务。
///
/// 结果写入 `getAppDataDir()/online_album/`：`info/` 保存 7 天有效的
/// JSON，`art/` 保存按 URL 哈希命名的图片。网络、文件与 JSON 错误
/// 都降级为“暂无信息”，不会把错误抛到界面。
class OnlineAlbumService {
  OnlineAlbumService._({
    MusicBrainzClient? musicBrainz,
    CoverArtClient? coverArt,
    Future<Directory> Function()? appDataDirectory,
    DateTime Function()? clock,
    this.cacheTtl = onlineAlbumCacheTtl,
  }) : _musicBrainz = musicBrainz ?? MusicBrainzClient(),
       _coverArt = coverArt ?? CoverArtClient(),
       _appDataDirectory = appDataDirectory ?? getAppDataDir,
       _clock = clock ?? DateTime.now;

  static final OnlineAlbumService instance = OnlineAlbumService._();

  @visibleForTesting
  static OnlineAlbumService createForTest({
    MusicBrainzClient? musicBrainz,
    CoverArtClient? coverArt,
    Future<Directory> Function()? appDataDirectory,
    DateTime Function()? clock,
    Duration cacheTtl = onlineAlbumCacheTtl,
  }) {
    return OnlineAlbumService._(
      musicBrainz: musicBrainz,
      coverArt: coverArt,
      appDataDirectory: appDataDirectory,
      clock: clock,
      cacheTtl: cacheTtl,
    );
  }

  final MusicBrainzClient _musicBrainz;
  final CoverArtClient _coverArt;
  final Future<Directory> Function() _appDataDirectory;
  final DateTime Function() _clock;
  final Duration cacheTtl;

  final Map<String, Future<OnlineAlbumInfo?>> _pendingLookups = {};
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

  Future<OnlineAlbumInfo?> lookup(Album album, {bool force = false}) {
    if (!AppSettings.instance.onlineAlbumInfoEnabled) {
      return Future<OnlineAlbumInfo?>.value();
    }
    final key = cacheKeyForAlbum(album);
    final pending = _pendingLookups[key];
    if (!force && pending != null) return pending;
    final request = _lookup(album, key, force: force);
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

  Future<OnlineAlbumInfo?> _lookup(
    Album album,
    String key, {
    required bool force,
  }) async {
    try {
      if (force) {
        await _deleteInfoCache(key);
      } else {
        final cached = await _readInfoCache(key);
        if (cached != null) return cached;
      }
      final info = await _fetchInfo(album);
      if (info != null) await _writeInfoCache(key, info);
      return info;
    } catch (error) {
      log.library.warn(
        'online_album_lookup_failed',
        '在线专辑信息获取失败',
        fields: {'stage': 'lookup', 'error': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Future<OnlineAlbumInfo?> _fetchInfo(Album album) async {
    final title = album.name.trim();
    if (title.isEmpty || album.works.isEmpty) return null;
    final artist = albumArtistFor(album);
    final trackCount = album.works.length;
    final yearHint = extractAlbumYearHint(album);

    final groups = await _musicBrainz.searchReleaseGroups(
      release: title,
      artist: artist,
    );
    if (groups.isEmpty) return null;

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
    if (best.score < minimumOnlineAlbumScore) return null;

    var release = best.release;
    if (release == null) {
      try {
        final releases = await _musicBrainz.browseReleases(best.group.id);
        release = pickBestRelease(releases, trackCount);
      } on MusicBrainzException catch (error) {
        release = null;
        log.library.debug(
          'online_album_release_lookup_failed',
          '发行版查询失败',
          fields: {'error': error.runtimeType.toString()},
        );
      }
    }

    MbReleaseDetail? detail;
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
    final detailGenres = detail?.genres ?? const <String>[];
    final detailTags = detail?.tags ?? const <String>[];
    final genreValues = <String>[
      ...best.group.genres,
      ...best.group.tags,
      ...detailGenres,
      ...detailTags,
    ];
    final genre = genreValues.isEmpty
        ? null
        : genreValues.toSet().take(3).join(' / ');
    final labels = detail?.labels ?? const <String>[];
    final label = labels.isEmpty ? null : labels.first;
    final year =
        yearFromDate(best.group.firstReleaseDate) ?? yearFromDate(detail?.date);
    final releaseDate = best.group.firstReleaseDate ?? detail?.date;
    final resolvedTrackCount = detail?.trackCount ?? release?.trackCount;
    final summary = buildOnlineAlbumSummary(
      primaryType: best.group.primaryType,
      secondaryTypes: best.group.secondaryTypes,
      releaseDate: releaseDate,
      trackCount: resolvedTrackCount,
    );

    return OnlineAlbumInfo(
      releaseGroupId: best.group.id,
      title: best.group.title,
      artist: best.group.artistNames.isNotEmpty
          ? best.group.artistNames.join(' / ')
          : artist,
      year: year,
      label: label,
      genre: genre,
      summary: summary,
      trackCount: resolvedTrackCount,
      primaryType: best.group.primaryType,
      secondaryTypes: best.group.secondaryTypes,
      covers: covers ?? CoverArtSet.empty,
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

  Future<File> _infoFile(String key) async {
    final dir = Directory(path.join((await _root()).path, 'info'));
    await dir.create(recursive: true);
    return File(path.join(dir.path, '$key.json'));
  }

  Future<File> _artworkFile(String url) async {
    final dir = Directory(path.join((await _root()).path, 'art'));
    await dir.create(recursive: true);
    final digest = sha1.convert(utf8.encode(url)).toString();
    return File(path.join(dir.path, '$digest${_imageExtension(url)}'));
  }

  Future<OnlineAlbumInfo?> _readInfoCache(String key) async {
    try {
      final file = await _infoFile(key);
      if (!await file.exists()) return null;
      final modified = await file.lastModified();
      if (_isExpired(modified)) {
        await file.delete();
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      return OnlineAlbumInfo.fromJson(decoded);
    } catch (error) {
      log.library.warn(
        'online_album_cache_read_failed',
        '在线专辑缓存读取失败',
        fields: {'error': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Future<void> _writeInfoCache(String key, OnlineAlbumInfo info) async {
    try {
      final file = await _infoFile(key);
      final payload = <String, Object?>{
        ...info.toJson(),
        'savedAt': _clock().toIso8601String(),
      };
      await writeTextFileAtomically(file.path, jsonEncode(payload));
    } catch (error) {
      log.library.warn(
        'online_album_cache_write_failed',
        '在线专辑缓存写入失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
  }

  Future<void> _deleteInfoCache(String key) async {
    try {
      final file = await _infoFile(key);
      if (await file.exists()) await file.delete();
    } catch (error) {
      log.library.debug(
        'online_album_cache_delete_failed',
        '在线专辑缓存清理失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
  }

  Future<ImageProvider?> _loadArtwork(String url) async {
    try {
      final file = await _artworkFile(url);
      if (await file.exists()) {
        if (_isExpired(await file.lastModified())) {
          await _deleteArtworkFile(file, 'expired');
        } else {
          final cachedBytes = await file.readAsBytes();
          if (await canDecodeImageBytes(cachedBytes)) {
            return MemoryImage(cachedBytes);
          }
          log.library.warn(
            'online_album_artwork_cache_invalid',
            '在线封面缓存无法解码，已删除并重新下载',
            fields: {'stage': 'cache'},
          );
          await _deleteArtworkFile(file, 'invalid');
        }
      }
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
      await _writeBytesAtomically(file, bytes);
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

  Future<void> _deleteArtworkFile(File file, String reason) async {
    try {
      await file.delete();
    } catch (error) {
      log.library.debug(
        'online_album_artwork_cleanup_failed',
        '在线封面缓存清理失败',
        fields: {'reason': reason, 'error': error.runtimeType.toString()},
      );
    }
  }

  Future<Uint8List?> _downloadBytes(String url) async {
    try {
      final response = await AppHttp.instance.dio.get<List<int>>(
        url,
        options: Options(
          headers: const {
            'User-Agent': musicBrainzUserAgent,
            'Accept': 'image/*',
          },
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

  Future<void> _writeBytesAtomically(File file, Uint8List bytes) async {
    final tmp = File(
      '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      try {
        await tmp.rename(file.path);
      } catch (_) {
        if (await file.exists()) await file.delete();
        await tmp.rename(file.path);
      }
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (error) {
        log.library.debug(
          'online_album_temp_cleanup_failed',
          '在线封面临时文件清理失败',
          fields: {'error': error.runtimeType.toString()},
        );
      }
    }
  }

  bool _isExpired(DateTime savedAt) => _clock().difference(savedAt) > cacheTtl;
}

class _RankedGroup {
  _RankedGroup({required this.group, required this.score});

  final MbReleaseGroup group;
  double score;
  MbRelease? release;
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

String normalizeForMatch(String value) {
  var text = value.toLowerCase();
  text = text.replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ');
  text = text.replaceAll(
    RegExp('[^a-z0-9\\u4e00-\\u9fff\\u3040-\\u30ff\\uac00-\\ud7af]+'),
    ' ',
  );
  return text.trim().replaceAll(RegExp(r'\s+'), ' ');
}

double albumTitleSimilarity(String left, String right) {
  final a = normalizeForMatch(left);
  final b = normalizeForMatch(right);
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  final shorter = a.length <= b.length ? a : b;
  final longer = a.length <= b.length ? b : a;
  if (shorter.length >= 4 && longer.contains(shorter)) {
    return 0.82 + 0.18 * (shorter.length / longer.length);
  }
  final distance = _levenshtein(a, b);
  final maxLength = a.length >= b.length ? a.length : b.length;
  return (1 - distance / maxLength).clamp(0.0, 1.0).toDouble();
}

double albumArtistSimilarity(String artist, List<String> candidates) {
  if (normalizeForMatch(artist).isEmpty) return 0;
  var best = 0.0;
  for (final candidate in candidates) {
    final score = albumTitleSimilarity(artist, candidate);
    if (score > best) best = score;
  }
  return best;
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

int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var previous = List<int>.generate(b.length + 1, (index) => index);
  for (var i = 0; i < a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0);
    current[0] = i + 1;
    final codeUnit = a.codeUnitAt(i);
    for (var j = 0; j < b.length; j++) {
      final cost = codeUnit == b.codeUnitAt(j) ? 0 : 1;
      final insert = current[j] + 1;
      final delete = previous[j + 1] + 1;
      final replace = previous[j] + cost;
      current[j + 1] = math.min(
        insert,
        math.min(delete, replace),
      );
    }
    previous = current;
  }
  return previous[b.length];
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

String _imageExtension(String url) {
  final uri = Uri.tryParse(url);
  final extension = uri == null ? '' : path.extension(uri.path).toLowerCase();
  return switch (extension) {
    '.jpg' || '.jpeg' || '.png' || '.webp' || '.gif' => extension,
    _ => '.img',
  };
}

String? _text(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}

int? _number(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

List<String> _textList(Object? value) {
  if (value is! List<dynamic>) return const [];
  final result = <String>[];
  for (final item in value) {
    final text = _text(item);
    if (text != null) result.add(text);
  }
  return List.unmodifiable(result);
}
