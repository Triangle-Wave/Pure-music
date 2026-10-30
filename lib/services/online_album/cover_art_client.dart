import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:pure_music/core/app_http.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/services/online_album/musicbrainz_client.dart';

const String coverArtArchiveBaseUrl = 'https://coverartarchive.org';

class CoverArtImage {
  const CoverArtImage({
    required this.url,
    required this.largeUrl,
    required this.front,
    required this.back,
    required this.types,
  });

  /// 展示用地址，优先使用 500px 缩略图。
  final String url;

  /// 更高清的原图或 1200px 缩略图，供后续扩展使用。
  final String? largeUrl;
  final bool front;
  final bool back;
  final List<String> types;

  Map<String, Object?> toJson() => {
    'url': url,
    'largeUrl': largeUrl,
    'front': front,
    'back': back,
    'types': types,
  };

  static CoverArtImage? fromJson(Object? data) {
    if (data is! Map<dynamic, dynamic>) return null;
    final types = <String>[];
    final rawTypes = data['types'];
    if (rawTypes is List<dynamic>) {
      for (final type in rawTypes) {
        if (type is String && type.trim().isNotEmpty) {
          types.add(type.trim().toLowerCase());
        }
      }
    }
    final thumbnails = data['thumbnails'];
    String? thumbnail(String key) {
      if (thumbnails is! Map<dynamic, dynamic>) return null;
      final value = thumbnails[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      return null;
    }

    final rawUrl = data['url'];
    final url = rawUrl is String && rawUrl.trim().isNotEmpty
        ? rawUrl.trim()
        : thumbnail('500') ??
              thumbnail('large') ??
              thumbnail('1200') ??
              thumbnail('250') ??
              thumbnail('small') ??
              (data['image'] is String ? (data['image'] as String).trim() : null);
    if (url == null || url.isEmpty) return null;
    final rawLargeUrl = data['largeUrl'];
    final largeUrl = rawLargeUrl is String && rawLargeUrl.trim().isNotEmpty
        ? rawLargeUrl.trim()
        : thumbnail('1200') ?? thumbnail('large');
    return CoverArtImage(
      url: url,
      largeUrl: largeUrl,
      front: data['front'] == true || types.contains('front'),
      back: data['back'] == true || types.contains('back'),
      types: List.unmodifiable(types),
    );
  }
}

class CoverArtSet {
  const CoverArtSet({
    this.front,
    this.back,
    this.booklets = const [],
  });

  static const CoverArtSet empty = CoverArtSet();

  final CoverArtImage? front;
  final CoverArtImage? back;
  final List<CoverArtImage> booklets;

  bool get isEmpty => front == null && back == null && booklets.isEmpty;

  Map<String, Object?> toJson() => {
    'front': front?.toJson(),
    'back': back?.toJson(),
    'booklets': booklets.map((image) => image.toJson()).toList(),
  };

  /// 兼容两种结构：Cover Art Archive 接口的 `{images: [...]}`，以及
  /// [toJson] 写出的 `{front, back, booklets}` 快照。
  static CoverArtSet fromJson(Object? data) {
    if (data is! Map<dynamic, dynamic>) return CoverArtSet.empty;
    final rawImages = data['images'];
    if (rawImages is List<dynamic>) return _fromApiImages(rawImages);
    return _fromCachedImages(data);
  }

  static CoverArtSet _fromApiImages(List<dynamic> rawImages) {
    CoverArtImage? front;
    CoverArtImage? back;
    final booklets = <CoverArtImage>[];
    for (final raw in rawImages) {
      final image = CoverArtImage.fromJson(raw);
      if (image == null) continue;
      if (image.front && front == null) {
        front = image;
        continue;
      }
      if (image.back && back == null) {
        back = image;
        continue;
      }
      if (image.types.contains('booklet')) booklets.add(image);
    }
    return CoverArtSet(
      front: front,
      back: back,
      booklets: List.unmodifiable(booklets),
    );
  }

  static CoverArtSet _fromCachedImages(Map<dynamic, dynamic> data) {
    final front = CoverArtImage.fromJson(data['front']);
    final back = CoverArtImage.fromJson(data['back']);
    final booklets = <CoverArtImage>[];
    final rawBooklets = data['booklets'];
    if (rawBooklets is List<dynamic>) {
      for (final raw in rawBooklets) {
        final image = CoverArtImage.fromJson(raw);
        if (image != null) booklets.add(image);
      }
    }
    if (front == null && back == null && booklets.isEmpty) {
      return CoverArtSet.empty;
    }
    return CoverArtSet(
      front: front,
      back: back,
      booklets: List.unmodifiable(booklets),
    );
  }

  /// 合并 release-group 与 release 两处结果，优先保留前者的正反面。
  static CoverArtSet merge(CoverArtSet first, CoverArtSet second) {
    final booklets = <CoverArtImage>[];
    final seen = <String>{};
    for (final image in [...first.booklets, ...second.booklets]) {
      if (seen.add(image.url)) booklets.add(image);
    }
    return CoverArtSet(
      front: first.front ?? second.front,
      back: first.back ?? second.back,
      booklets: List.unmodifiable(booklets),
    );
  }
}

/// Cover Art Archive 客户端。
///
/// 同时查询 release 与 release-group，并合并两处的正反面与内页；404 视为
/// 没有封面而不是错误，网络失败记录不含 URL 的告警并返回空结果。
class CoverArtClient {
  CoverArtClient({Dio? dio}) : _dio = dio;

  final Dio? _dio;

  Dio get _client => _dio ?? AppHttp.instance.dio;

  Future<CoverArtSet?> fetch({
    required String releaseGroupId,
    String? releaseId,
  }) async {
    CoverArtSet? combined;
    final release = releaseId?.trim();
    if (release != null && release.isNotEmpty) {
      final data = await _getJson(
        '$coverArtArchiveBaseUrl/release/${Uri.encodeComponent(release)}',
      );
      if (data != null) combined = CoverArtSet.fromJson(data);
    }
    final groupId = releaseGroupId.trim();
    if (groupId.isNotEmpty) {
      final data = await _getJson(
        '$coverArtArchiveBaseUrl/release-group/${Uri.encodeComponent(groupId)}',
      );
      if (data != null) {
        final set = CoverArtSet.fromJson(data);
        combined = combined == null ? set : CoverArtSet.merge(combined, set);
      }
    }
    return combined == null || combined.isEmpty ? null : combined;
  }

  Future<Map<String, dynamic>?> _getJson(String url) async {
    final host = Uri.tryParse(url)?.host ?? 'coverartarchive.org';
    final stopwatch = Stopwatch()..start();
    int? lastStatus;
    try {
      final response = await _client.get<dynamic>(
        url,
        options: Options(
          headers: const {
            'User-Agent': musicBrainzUserAgent,
            'Accept': 'application/json',
          },
          responseType: ResponseType.json,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final status = response.statusCode ?? 0;
      lastStatus = status;
      if (status < 200 || status >= 300) {
        log.library.info(
          'online_album_caa_request',
          '封面接口请求完成',
          fields: {
            'source': 'Cover Art Archive',
            'host': host,
            'status': status,
            'elapsedMs': stopwatch.elapsedMilliseconds,
            'count': 0,
          },
        );
        return null;
      }
      final data = response.data;
      Map<String, dynamic>? result;
      if (data is Map<String, dynamic>) {
        result = data;
      } else if (data is Map<dynamic, dynamic>) {
        result = Map<String, dynamic>.from(data);
      } else if (data is String) {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) result = decoded;
        if (decoded is Map<dynamic, dynamic>) {
          result = Map<String, dynamic>.from(decoded);
        }
      }
      final images = result?['images'];
      log.library.info(
        'online_album_caa_request',
        '封面接口请求完成',
        fields: {
          'source': 'Cover Art Archive',
          'host': host,
          'status': status,
          'elapsedMs': stopwatch.elapsedMilliseconds,
          'count': images is List<dynamic> ? images.length : 0,
        },
      );
      return result;
    } on DioException catch (error) {
      log.library.warn(
        'online_album_caa_request_failed',
        '封面接口请求失败',
        fields: {
          'source': 'Cover Art Archive',
          'host': host,
          'status': error.response?.statusCode ?? lastStatus ?? 0,
          'elapsedMs': stopwatch.elapsedMilliseconds,
          'error': error.type.name,
        },
      );
      return null;
    } catch (error) {
      log.library.warn(
        'online_album_caa_request_failed',
        '封面接口解析失败',
        fields: {
          'source': 'Cover Art Archive',
          'host': host,
          'status': lastStatus ?? 0,
          'elapsedMs': stopwatch.elapsedMilliseconds,
          'error': error.runtimeType.toString(),
        },
      );
      return null;
    }
  }
}
