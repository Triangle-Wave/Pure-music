import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:pure_music/core/app_http.dart';
import 'package:pure_music/core/log/app_log.dart';

/// MusicBrainz 要求带可联系的 User-Agent，并限制匿名客户端每秒 1 个请求。
const String musicBrainzUserAgent =
    'PureMusic/2.3.3 (https://github.com/Triangle-Wave/Pure-music)';
const String musicBrainzBaseUrl = 'https://musicbrainz.org/ws/2';

class MusicBrainzException implements Exception {
  MusicBrainzException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'MusicBrainzException: $message';
}

/// MusicBrainz Web Service 客户端。
///
/// 所有请求进入同一条串行队列，相邻请求至少间隔 [minInterval]；遇到
/// 429/503 按 Retry-After 或固定退避重试。客户端不记录请求 URL，避免
/// 把专辑名写入日志。
class MusicBrainzClient {
  MusicBrainzClient({
    Dio? dio,
    this.minInterval = const Duration(seconds: 1),
    this.attempts = 3,
  }) : _dio = dio;

  final Dio? _dio;
  final Duration minInterval;
  final int attempts;

  Dio get _client => _dio ?? AppHttp.instance.dio;

  Future<void> _queue = Future<void>.value();
  DateTime? _lastRequestAt;

  Future<List<MbReleaseGroup>> searchReleaseGroups({
    required String release,
    required String artist,
    int limit = 8,
  }) async {
    final title = release.trim();
    if (title.isEmpty) return const [];
    final stopwatch = Stopwatch()..start();
    final clauses = <String>['release:"${_escapeLucene(title)}"'];
    final artistName = artist.trim();
    if (artistName.isNotEmpty) {
      clauses.add('artist:"${_escapeLucene(artistName)}"');
    }
    final data = await _get('/release-group', {
      'query': clauses.join(' AND '),
      'fmt': 'json',
      'limit': '$limit',
    });
    final groups = data == null
        ? const <MbReleaseGroup>[]
        : MbReleaseGroup.listFromJson(data['release-groups']);
    log.library.info(
      'online_album_mb_search',
      'MusicBrainz 搜索完成',
      fields: {
        'host': 'musicbrainz.org',
        'count': groups.length,
        'elapsedMs': stopwatch.elapsedMilliseconds,
      },
    );
    return groups;
  }

  Future<List<MbRelease>> browseReleases(
    String releaseGroupId, {
    int limit = 10,
  }) async {
    if (releaseGroupId.trim().isEmpty) return const [];
    final data = await _get('/release', {
      'release-group': releaseGroupId,
      'fmt': 'json',
      'limit': '$limit',
    });
    if (data == null) return const [];
    return MbRelease.listFromJson(data['releases']);
  }

  Future<MbReleaseDetail?> lookupRelease(String releaseId) async {
    if (releaseId.trim().isEmpty) return null;
    final data = await _get(
      '/release/${Uri.encodeComponent(releaseId)}',
      {'fmt': 'json', 'inc': 'labels+genres+tags'},
    );
    return MbReleaseDetail.fromJson(data);
  }

  Future<Map<String, dynamic>?> _get(
    String path,
    Map<String, String> query,
  ) {
    return _enqueue(() async {
      Object? lastError;
      int? lastStatus;
      for (var attempt = 0; attempt < attempts; attempt++) {
        await _throttle();
        final stopwatch = Stopwatch()..start();
        try {
          final response = await _client.get<dynamic>(
            '$musicBrainzBaseUrl$path',
            queryParameters: query,
            options: Options(
              headers: const {
                'User-Agent': musicBrainzUserAgent,
                'Accept': 'application/json',
              },
              responseType: ResponseType.json,
              sendTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              validateStatus: (status) =>
                  status != null && (status < 500 || status == 503),
            ),
          );
          final status = response.statusCode ?? 0;
          log.library.info(
            'online_album_mb_request',
            'MusicBrainz 请求完成',
            fields: {
              'host': 'musicbrainz.org',
              'path': path,
              'status': status,
              'elapsedMs': stopwatch.elapsedMilliseconds,
              'attempt': attempt + 1,
            },
          );
          if (status == 429 || status == 503) {
            lastStatus = status;
            await Future<void>.delayed(_retryAfter(response.headers));
            continue;
          }
          if (status >= 400) {
            lastStatus = status;
            log.library.warn(
              'online_album_mb_request_failed',
              'MusicBrainz 请求返回错误状态',
              fields: {
                'host': 'musicbrainz.org',
                'path': path,
                'status': status,
                'elapsedMs': stopwatch.elapsedMilliseconds,
              },
            );
            return null;
          }
          final data = response.data;
          if (data is Map<String, dynamic>) return data;
          if (data is Map<dynamic, dynamic>) return Map<String, dynamic>.from(data);
          if (data is String) {
            final decoded = jsonDecode(data);
            if (decoded is Map<String, dynamic>) return decoded;
            if (decoded is Map<dynamic, dynamic>) return Map<String, dynamic>.from(decoded);
          }
          throw MusicBrainzException('unexpected response body');
        } on DioException catch (error) {
          lastError = error;
          lastStatus = error.response?.statusCode;
          if (attempt == attempts - 1) break;
          await Future<void>.delayed(Duration(seconds: 2 << attempt));
        } on MusicBrainzException catch (error) {
          lastError = error;
          break;
        }
      }
      log.library.warn(
        'online_album_mb_request_failed',
        'MusicBrainz 请求失败',
        fields: {
          'host': 'musicbrainz.org',
          'path': path,
          'status': lastStatus ?? 0,
          if (lastError is DioException)
            'error': (lastError as DioException).type.name
          else if (lastError != null)
            'error': lastError.runtimeType.toString(),
        },
      );
      throw MusicBrainzException('request failed', lastError);
    });
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _throttle() async {
    final last = _lastRequestAt;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < minInterval) {
        await Future<void>.delayed(minInterval - elapsed);
      }
    }
    _lastRequestAt = DateTime.now();
  }

  Duration _retryAfter(Headers headers) {
    final raw = headers.value('retry-after');
    final seconds = raw == null ? null : int.tryParse(raw.trim());
    if (seconds == null || seconds <= 0 || seconds > 30) {
      return const Duration(seconds: 3);
    }
    return Duration(seconds: seconds);
  }
}

String _escapeLucene(String value) {
  return value
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"')
      .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
      .trim();
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

String? _asString(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}

List<String> _nameList(Object? value) {
  if (value is! List<dynamic>) return const [];
  final names = <String>[];
  for (final item in value) {
    if (item is Map<dynamic, dynamic>) {
      final name = _asString(item['name']);
      if (name != null) names.add(name);
    } else if (item is String) {
      final name = _asString(item);
      if (name != null) names.add(name);
    }
  }
  return List.unmodifiable(names);
}

int? yearFromDate(String? date) {
  if (date == null) return null;
  final match = RegExp(r'(19|20)\d{2}').firstMatch(date);
  if (match == null) return null;
  final year = int.tryParse(match.group(0)!);
  if (year == null || year < 1900 || year > 2100) return null;
  return year;
}

class MbReleaseGroup {
  const MbReleaseGroup({
    required this.id,
    required this.title,
    required this.score,
    required this.primaryType,
    required this.secondaryTypes,
    required this.firstReleaseDate,
    required this.disambiguation,
    required this.artistNames,
    required this.genres,
    required this.tags,
  });

  final String id;
  final String title;
  final int score;
  final String? primaryType;
  final List<String> secondaryTypes;
  final String? firstReleaseDate;
  final String? disambiguation;
  final List<String> artistNames;
  final List<String> genres;
  final List<String> tags;

  static List<MbReleaseGroup> listFromJson(Object? data) {
    if (data is! List<dynamic>) return const [];
    final result = <MbReleaseGroup>[];
    for (final item in data) {
      if (item is! Map<dynamic, dynamic>) continue;
      final id = _asString(item['id']);
      final title = _asString(item['title']);
      if (id == null || title == null) continue;
      final artists = <String>[];
      final credits = item['artist-credit'];
      if (credits is List<dynamic>) {
        for (final credit in credits) {
          if (credit is! Map<dynamic, dynamic>) continue;
          final name = _asString(credit['name']) ??
              _asString(credit['artist'] is Map<dynamic, dynamic>
                  ? (credit['artist'] as Map<dynamic, dynamic>)['name']
                  : null);
          if (name != null) artists.add(name);
        }
      }
      result.add(
        MbReleaseGroup(
          id: id,
          title: title,
          score: _asInt(item['score']) ?? 0,
          primaryType: _asString(item['primary-type']),
          secondaryTypes: _nameList(item['secondary-types']),
          firstReleaseDate: _asString(item['first-release-date']),
          disambiguation: _asString(item['disambiguation']),
          artistNames: List.unmodifiable(artists),
          genres: _nameList(item['genres']),
          tags: _nameList(item['tags']),
        ),
      );
    }
    return List.unmodifiable(result);
  }
}

class MbRelease {
  const MbRelease({
    required this.id,
    required this.title,
    required this.date,
    required this.status,
    required this.trackCount,
    required this.genres,
    required this.tags,
  });

  final String id;
  final String title;
  final String? date;
  final String? status;
  final int? trackCount;
  final List<String> genres;
  final List<String> tags;

  static List<MbRelease> listFromJson(Object? data) {
    if (data is! List<dynamic>) return const [];
    final result = <MbRelease>[];
    for (final item in data) {
      if (item is! Map<dynamic, dynamic>) continue;
      final id = _asString(item['id']);
      final title = _asString(item['title']);
      if (id == null || title == null) continue;
      result.add(
        MbRelease(
          id: id,
          title: title,
          date: _asString(item['date']),
          status: _asString(item['status']),
          trackCount: _releaseTrackCount(item),
          genres: _nameList(item['genres']),
          tags: _nameList(item['tags']),
        ),
      );
    }
    return List.unmodifiable(result);
  }
}

class MbReleaseDetail {
  const MbReleaseDetail({
    required this.id,
    required this.title,
    required this.date,
    required this.trackCount,
    required this.labels,
    required this.genres,
    required this.tags,
  });

  final String id;
  final String title;
  final String? date;
  final int? trackCount;
  final List<String> labels;
  final List<String> genres;
  final List<String> tags;

  static MbReleaseDetail? fromJson(Object? data) {
    if (data is! Map<dynamic, dynamic>) return null;
    final id = _asString(data['id']);
    final title = _asString(data['title']);
    if (id == null || title == null) return null;
    final labels = <String>[];
    final labelInfo = data['label-info'];
    if (labelInfo is List<dynamic>) {
      for (final item in labelInfo) {
        if (item is! Map<dynamic, dynamic>) continue;
        final label = item['label'];
        if (label is Map<dynamic, dynamic>) {
          final name = _asString(label['name']);
          if (name != null) labels.add(name);
        }
      }
    }
    return MbReleaseDetail(
      id: id,
      title: title,
      date: _asString(data['date']),
      trackCount: _releaseTrackCount(data),
      labels: List.unmodifiable(labels),
      genres: _nameList(data['genres']),
      tags: _nameList(data['tags']),
    );
  }
}

int? _releaseTrackCount(Map<dynamic, dynamic> data) {
  final direct = _asInt(data['track-count']);
  if (direct != null && direct > 0) return direct;
  final media = data['media'];
  if (media is! List<dynamic>) return null;
  var total = 0;
  var found = false;
  for (final medium in media) {
    if (medium is! Map<dynamic, dynamic>) continue;
    final count = _asInt(medium['track-count']);
    if (count != null) {
      total += count;
      found = true;
    }
  }
  return found ? total : null;
}
