import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pure_music/core/app_http.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/services/online_album/album_match.dart';
import 'package:pure_music/services/online_lyric/api/net_lyric_api.dart'
    as lyric;

enum CnMusicSource {
  netease('网易云音乐'),
  qq('QQ 音乐'),
  kugou('酷狗音乐');

  const CnMusicSource(this.label);

  final String label;
}

class CnAlbumCandidate {
  const CnAlbumCandidate({
    required this.source,
    required this.id,
    required this.title,
    required this.artist,
    this.coverUrl,
    this.trackCount,
    this.year,
  });

  final CnMusicSource source;
  final String id;
  final String title;
  final String artist;
  final String? coverUrl;
  final int? trackCount;
  final int? year;
}

class CnArtistCandidate {
  const CnArtistCandidate({
    required this.source,
    required this.id,
    required this.name,
    this.picUrl,
    this.albumCount,
  });

  final CnMusicSource source;
  final String id;
  final String name;
  final String? picUrl;
  final int? albumCount;
}

const Map<String, String> _neteaseHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
  'Accept': 'application/json,text/plain,*/*',
  'Referer': 'https://music.163.com/',
};

const Map<String, String> _qqHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
  'Accept': 'application/json,text/plain,*/*',
  'Referer': 'https://y.qq.com/',
  'Origin': 'https://y.qq.com',
  'Content-Type': 'application/json',
};

const Map<String, String> _kugouHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
  'Accept': 'application/json,text/plain,*/*',
  'Referer': 'https://www.kugou.com/',
};

/// 国内音乐源元数据客户端。
///
/// 请求统一使用 [AppHttp] 的共享客户端，跟随全局代理配置。三个源的失败
/// 相互独立，任何一个源超时或返回异常结构都只降级为该源没有结果。
class CnMusicClient {
  CnMusicClient({
    Dio? dio,
    this.timeout = const Duration(seconds: 8),
  }) : _dio = dio;

  final Dio? _dio;
  final Duration timeout;

  Dio get _client => _dio ?? AppHttp.instance.dio;

  /// 当前使用的 Dio，供测试确认使用统一客户端。
  @visibleForTesting
  Dio get clientForTest => _client;

  Future<List<CnAlbumCandidate>> searchAlbums({
    required String title,
    required String artist,
    int limit = 8,
  }) async {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) return const [];
    final keyword = [
      trimmedTitle,
      artist.trim(),
    ].where((value) => value.isNotEmpty).join(' ');

    final groups = await Future.wait<List<CnAlbumCandidate>>([
      _neteaseAlbums(trimmedTitle, limit),
      _qqAlbums(keyword, limit),
      _kugouAlbums(trimmedTitle, limit),
    ]);
    final merged = _dedupeAlbums([...groups[0], ...groups[1], ...groups[2]]);
    if (merged.isNotEmpty) return merged;
    return _lyricSearchFallback(keyword, limit);
  }

  Future<List<CnArtistCandidate>> searchArtists({
    required String name,
    int limit = 8,
  }) async {
    final keyword = name.trim();
    if (keyword.isEmpty) return const [];
    final groups = await Future.wait<List<CnArtistCandidate>>([
      _neteaseArtists(keyword, limit),
      _qqArtists(keyword, limit),
      _kugouArtists(keyword, limit),
    ]);
    return _dedupeArtists([...groups[0], ...groups[1], ...groups[2]]);
  }

  Future<List<CnAlbumCandidate>> _neteaseAlbums(
    String keyword,
    int limit,
  ) async {
    final primary = await _getJson(
      'https://music.163.com/api/cloudsearch/pc',
      query: {
        's': keyword,
        'type': '10',
        'offset': '0',
        'total': 'true',
        'limit': '$limit',
      },
      headers: _neteaseHeaders,
      stage: 'netease_album',
    );
    final albums = parseNeteaseAlbums(primary);
    if (albums.isNotEmpty) return albums;
    final fallback = await _getJson(
      'https://music.163.com/api/search/get/web',
      query: {'s': keyword, 'type': '10', 'offset': '0', 'limit': '$limit'},
      headers: _neteaseHeaders,
      stage: 'netease_album_fallback',
    );
    return parseNeteaseAlbums(fallback);
  }

  Future<List<CnAlbumCandidate>> _qqAlbums(String keyword, int limit) async {
    final data = await _postJson(
      'https://u.y.qq.com/cgi-bin/musicu.fcg',
      _qqSearchPayload(keyword: keyword, searchType: 0, limit: limit),
      headers: _qqHeaders,
      stage: 'qq_album',
    );
    return parseQqAlbums(data);
  }

  Future<List<CnAlbumCandidate>> _kugouAlbums(
    String keyword,
    int limit,
  ) async {
    final data = await _getJson(
      'https://mobilecdn.kugou.com/api/v3/search/album',
      query: {
        'format': 'json',
        'keyword': keyword,
        'page': '1',
        'pagesize': '$limit',
      },
      headers: _kugouHeaders,
      stage: 'kugou_album',
    );
    final albums = parseKugouAlbums(data);
    if (albums.isNotEmpty) return albums;
    final songs = await _getJson(
      'https://mobilecdn.kugou.com/api/v3/search/song',
      query: {
        'format': 'json',
        'keyword': keyword,
        'page': '1',
        'pagesize': '$limit',
      },
      headers: _kugouHeaders,
      stage: 'kugou_album_song_fallback',
    );
    return parseKugouSongAlbums(songs);
  }

  Future<List<CnArtistCandidate>> _neteaseArtists(
    String keyword,
    int limit,
  ) async {
    final primary = await _getJson(
      'https://music.163.com/api/cloudsearch/pc',
      query: {
        's': keyword,
        'type': '100',
        'offset': '0',
        'total': 'true',
        'limit': '$limit',
      },
      headers: _neteaseHeaders,
      stage: 'netease_artist',
    );
    final artists = parseNeteaseArtists(primary);
    if (artists.isNotEmpty) return artists;
    final fallback = await _getJson(
      'https://music.163.com/api/search/get/web',
      query: {'s': keyword, 'type': '100', 'offset': '0', 'limit': '$limit'},
      headers: _neteaseHeaders,
      stage: 'netease_artist_fallback',
    );
    return parseNeteaseArtists(fallback);
  }

  Future<List<CnArtistCandidate>> _qqArtists(String keyword, int limit) async {
    final data = await _postJson(
      'https://u.y.qq.com/cgi-bin/musicu.fcg',
      _qqSearchPayload(keyword: keyword, searchType: 1, limit: limit),
      headers: _qqHeaders,
      stage: 'qq_artist',
    );
    return parseQqArtists(data);
  }

  Future<List<CnArtistCandidate>> _kugouArtists(
    String keyword,
    int limit,
  ) async {
    final data = await _getJson(
      'https://mobilecdn.kugou.com/api/v3/search/singer',
      query: {
        'format': 'json',
        'keyword': keyword,
        'page': '1',
        'pagesize': '$limit',
      },
      headers: _kugouHeaders,
      stage: 'kugou_artist',
    );
    return parseKugouArtists(data);
  }

  /// 三个源都返回空时，复用歌词模块已有的搜索客户端再补一次。
  /// 这些客户端使用 HttpClient 直连，属于快速兜底路径。
  Future<List<CnAlbumCandidate>> _lyricSearchFallback(
    String keyword,
    int limit,
  ) async {
    final albums = <CnAlbumCandidate>[];
    try {
      final items = await lyric.qqSearchLyric(
        keyword: keyword,
        pageSize: limit,
        timeout: const Duration(seconds: 4),
      );
      for (final item in items) {
        if (item.album.trim().isEmpty) continue;
        albums.add(
          CnAlbumCandidate(
            source: CnMusicSource.qq,
            id: item.mid.isEmpty ? item.id : item.mid,
            title: item.album.trim(),
            artist: item.artist,
            coverUrl: _httpsUrl(item.picUrl),
          ),
        );
      }
    } catch (error) {
      _logFailure('qq_lyric_fallback', error);
    }
    try {
      final items = await lyric.kgSearchLyric(
        keyword: keyword,
        pageSize: limit,
        timeout: const Duration(seconds: 4),
      );
      for (final item in items) {
        if (item.album.trim().isEmpty) continue;
        albums.add(
          CnAlbumCandidate(
            source: CnMusicSource.kugou,
            id: item.id.isEmpty ? item.hash : item.id,
            title: item.album.trim(),
            artist: item.artist,
            coverUrl: _httpsUrl(item.picUrl),
          ),
        );
      }
    } catch (error) {
      _logFailure('kugou_lyric_fallback', error);
    }
    return _dedupeAlbums(albums);
  }

  static Map<String, dynamic> _qqSearchPayload({
    required String keyword,
    required int searchType,
    required int limit,
  }) {
    return {
      'comm': {'ct': '19', 'cv': '1873', 'uin': '0'},
      'req_0': {
        'method': 'DoSearchForQQMusicDesktop',
        'module': 'music.search.SearchCgiService',
        'param': {
          'grp': 1,
          'num_per_page': limit,
          'page_num': 1,
          'query': keyword,
          'search_type': searchType,
        },
      },
    };
  }

  Future<Map<String, dynamic>?> _getJson(
    String url, {
    required Map<String, String> query,
    required Map<String, String> headers,
    required String stage,
  }) async {
    try {
      final response = await _client.get<dynamic>(
        url,
        queryParameters: query,
        options: Options(
          headers: headers,
          responseType: ResponseType.json,
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 300,
        ),
      );
      return asJsonMap(response.data);
    } on DioException catch (error) {
      _logFailure(stage, error.type.name);
      return null;
    } catch (error) {
      _logFailure(stage, error);
      return null;
    }
  }

  Future<Map<String, dynamic>?> _postJson(
    String url,
    Map<String, dynamic> body, {
    required Map<String, String> headers,
    required String stage,
  }) async {
    try {
      final response = await _client.post<dynamic>(
        url,
        data: jsonEncode(body),
        options: Options(
          headers: headers,
          responseType: ResponseType.json,
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 300,
        ),
      );
      return asJsonMap(response.data);
    } on DioException catch (error) {
      _logFailure(stage, error.type.name);
      return null;
    } catch (error) {
      _logFailure(stage, error);
      return null;
    }
  }

  void _logFailure(String stage, Object error) {
    log.library.debug(
      'cn_music_request_failed',
      '国内音乐接口请求失败',
      fields: {
        'stage': stage,
        'error': error.runtimeType.toString(),
      },
    );
  }

  @visibleForTesting
  static Map<String, dynamic>? asJsonMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map<dynamic, dynamic>) {
      return Map<String, dynamic>.from(data);
    }
    if (data is String && data.trim().isNotEmpty) {
      try {
        return asJsonMap(jsonDecode(data));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  @visibleForTesting
  static List<CnAlbumCandidate> parseNeteaseAlbums(Object? data) {
    final root = asJsonMap(data);
    final result = _dig(root, const ['result']);
    final list = _dig(result, const ['albums']) ??
        _dig(result, const ['album']);
    if (list is! List<dynamic>) return const [];
    final albums = <CnAlbumCandidate>[];
    for (final raw in list) {
      final item = asJsonMap(raw);
      if (item == null) continue;
      final id = _text(item['id']);
      final title = _text(item['name']);
      if (id == null || title == null) continue;
      final artistNode = item['artist'] ?? item['artists'];
      var artist = '';
      if (artistNode is List<dynamic>) {
        artist = artistNode
            .map((entry) => _text(asJsonMap(entry)?['name']))
            .whereType<String>()
            .join('/');
      } else if (artistNode is Map<dynamic, dynamic>) {
        artist = _text(artistNode['name']) ?? '';
      } else {
        artist = _text(artistNode) ?? '';
      }
      albums.add(
        CnAlbumCandidate(
          source: CnMusicSource.netease,
          id: id,
          title: title,
          artist: artist,
          coverUrl: _httpsUrl(_text(item['picUrl']) ?? _text(item['pic'])),
          trackCount: _integer(item['size'] ?? item['songCount']),
        ),
      );
    }
    return List.unmodifiable(albums);
  }

  @visibleForTesting
  static List<CnArtistCandidate> parseNeteaseArtists(Object? data) {
    final root = asJsonMap(data);
    final result = _dig(root, const ['result']);
    final list = _dig(result, const ['artists']) ??
        _dig(result, const ['artist']);
    if (list is! List<dynamic>) return const [];
    final artists = <CnArtistCandidate>[];
    for (final raw in list) {
      final item = asJsonMap(raw);
      if (item == null) continue;
      final id = _text(item['id']);
      final name = _text(item['name']);
      if (id == null || name == null) continue;
      artists.add(
        CnArtistCandidate(
          source: CnMusicSource.netease,
          id: id,
          name: name,
          picUrl: _httpsUrl(_text(item['picUrl']) ?? _text(item['img1v1Url'])),
          albumCount: _integer(item['albumSize'] ?? item['albumSizeValue']),
        ),
      );
    }
    return List.unmodifiable(artists);
  }

  @visibleForTesting
  static List<CnAlbumCandidate> parseQqAlbums(Object? data) {
    final root = asJsonMap(data);
    final songs = _qqSongItems(root);
    if (songs == null) return const [];
    final albums = <CnAlbumCandidate>[];
    for (final raw in songs) {
      final item = asJsonMap(raw);
      if (item == null) continue;
      final albumNode = item['album'];
      final albumMap = asJsonMap(albumNode);
      final title = _text(albumMap?['name']) ??
          _text(item['albumname']) ??
          _text(item['album_name']);
      if (title == null) continue;
      final mid = _text(albumMap?['mid']) ??
          _text(item['albummid']) ??
          _text(item['album_mid']);
      final artistNode = item['singer'] ?? item['singers'];
      final artist = artistNode is List<dynamic>
          ? artistNode
                .map((entry) {
                  final singer = asJsonMap(entry);
                  return _text(singer?['name']) ?? _text(singer?['title']);
                })
                .whereType<String>()
                .join('/')
          : _text(item['singername']) ?? '';
      albums.add(
        CnAlbumCandidate(
          source: CnMusicSource.qq,
          id: mid ?? title,
          title: title,
          artist: artist,
          coverUrl: qqAlbumCover(mid),
        ),
      );
    }
    return List.unmodifiable(albums);
  }

  @visibleForTesting
  static List<CnArtistCandidate> parseQqArtists(Object? data) {
    final root = asJsonMap(data);
    final body = _dig(root, const ['req_0', 'data', 'body']);
    final list = _dig(body, const ['singer', 'list']) ??
        _dig(body, const ['item_singer']) ??
        _dig(body, const ['singer_list']) ??
        _dig(body, const ['singer', 'itemlist']);
    if (list is! List<dynamic>) return const [];
    final artists = <CnArtistCandidate>[];
    for (final raw in list) {
      final item = asJsonMap(raw);
      if (item == null) continue;
      final name = _text(item['name']) ??
          _text(item['singerName']) ??
          _text(item['singer_name']) ??
          _text(item['title']);
      if (name == null || name == 'UNKNOWN') continue;
      final mid = _text(item['mid']) ??
          _text(item['singerMid']) ??
          _text(item['singer_mid']) ??
          _text(item['id']);
      final pic = _text(item['pic']) ??
          _text(item['singerPic']) ??
          _text(item['singer_pic']) ??
          qqArtistCover(mid);
      artists.add(
        CnArtistCandidate(
          source: CnMusicSource.qq,
          id: mid ?? name,
          name: name,
          picUrl: _httpsUrl(pic),
          albumCount: _integer(
            item['albumNum'] ?? item['album_num'] ?? item['albumCount'],
          ),
        ),
      );
    }
    return List.unmodifiable(artists);
  }

  @visibleForTesting
  static List<CnAlbumCandidate> parseKugouAlbums(Object? data) {
    final info = _kugouInfo(data);
    if (info == null) return const [];
    final albums = <CnAlbumCandidate>[];
    for (final raw in info) {
      final item = asJsonMap(raw);
      if (item == null) continue;
      final title = _text(item['albumname']) ??
          _text(item['album_name']) ??
          _text(item['name']);
      final id = _text(item['albumid']) ??
          _text(item['album_id']) ??
          _text(item['id']);
      if (title == null || id == null) continue;
      albums.add(
        CnAlbumCandidate(
          source: CnMusicSource.kugou,
          id: id,
          title: title,
          artist: _text(item['singername']) ??
              _text(item['singer_name']) ??
              _text(item['author_name']) ??
              '',
          coverUrl: _kugouCover(item),
          trackCount: _integer(
            item['songcount'] ?? item['song_count'] ?? item['songCount'],
          ),
        ),
      );
    }
    return List.unmodifiable(albums);
  }

  @visibleForTesting
  static List<CnAlbumCandidate> parseKugouSongAlbums(Object? data) {
    final info = _kugouInfo(data);
    if (info == null) return const [];
    final albums = <CnAlbumCandidate>[];
    for (final raw in info) {
      final item = asJsonMap(raw);
      if (item == null) continue;
      final title = _text(item['album_name']) ??
          _text(item['albumname']) ??
          _text(item['albumName']);
      if (title == null) continue;
      albums.add(
        CnAlbumCandidate(
          source: CnMusicSource.kugou,
          id: _text(item['album_id']) ?? _text(item['albumid']) ?? title,
          title: title,
          artist: _text(item['singername']) ??
              _text(item['singer_name']) ??
              '',
          coverUrl: _kugouCover(item),
        ),
      );
    }
    return List.unmodifiable(albums);
  }

  @visibleForTesting
  static List<CnArtistCandidate> parseKugouArtists(Object? data) {
    final info = _kugouInfo(data);
    if (info == null) return const [];
    final artists = <CnArtistCandidate>[];
    for (final raw in info) {
      final item = asJsonMap(raw);
      if (item == null) continue;
      final name = _text(item['singername']) ??
          _text(item['singer_name']) ??
          _text(item['name']);
      if (name == null) continue;
      artists.add(
        CnArtistCandidate(
          source: CnMusicSource.kugou,
          id: _text(item['singerid']) ??
              _text(item['singer_id']) ??
              _text(item['id']) ??
              name,
          name: name,
          picUrl: _httpsUrl(_text(item['imgurl']) ?? _text(item['img_url'])),
          albumCount: _integer(
            item['albumcount'] ?? item['album_count'] ?? item['album_num'],
          ),
        ),
      );
    }
    return List.unmodifiable(artists);
  }

  static List<dynamic>? _qqSongItems(Map<String, dynamic>? root) {
    if (root == null) return null;
    for (final key in const [
      'req_0',
      'req_1',
      'music.search.SearchCgiService',
    ]) {
      final body = _dig(root, [key, 'data', 'body']);
      final itemSong = _dig(body, const ['item_song']);
      if (itemSong is List<dynamic> && itemSong.isNotEmpty) return itemSong;
      final songList = _dig(body, const ['song', 'list']);
      if (songList is List<dynamic> && songList.isNotEmpty) return songList;
    }
    final webList = _dig(root, const ['data', 'song', 'list']);
    if (webList is List<dynamic> && webList.isNotEmpty) return webList;
    return null;
  }

  static List<dynamic>? _kugouInfo(Object? data) {
    final root = asJsonMap(data);
    final dataNode = root?['data'];
    final info = dataNode is List<dynamic>
        ? dataNode
        : _dig(dataNode, const ['info']);
    return info is List<dynamic> ? info : null;
  }

  static List<CnAlbumCandidate> _dedupeAlbums(
    List<CnAlbumCandidate> items,
  ) {
    final result = <String, CnAlbumCandidate>{};
    for (final item in items) {
      final key = '${item.source.name}|'
          '${normalizeForMatch(item.title)}|'
          '${normalizeForMatch(item.artist)}';
      final existing = result[key];
      final betterTrackCount =
          (item.trackCount ?? 0) > (existing?.trackCount ?? 0);
      final fillsCover = existing?.coverUrl == null && item.coverUrl != null;
      if (existing == null || betterTrackCount || fillsCover) {
        result[key] = item;
      }
    }
    return List.unmodifiable(result.values);
  }

  static List<CnArtistCandidate> _dedupeArtists(
    List<CnArtistCandidate> items,
  ) {
    final result = <String, CnArtistCandidate>{};
    for (final item in items) {
      final key = '${item.source.name}|${normalizeForMatch(item.name)}';
      final existing = result[key];
      if (existing == null ||
          (existing.picUrl == null && item.picUrl != null)) {
        result[key] = item;
      }
    }
    return List.unmodifiable(result.values);
  }

  static dynamic _dig(Object? node, List<String> path) {
    var current = node;
    for (final key in path) {
      if (current is Map<dynamic, dynamic>) {
        current = current[key];
      } else {
        return null;
      }
    }
    return current;
  }

  static String? _text(Object? value) {
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    if (value is num) return '$value';
    return null;
  }

  static int? _integer(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static String? _httpsUrl(String? url) {
    final trimmed = url?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.startsWith('http://')) {
      return trimmed.replaceFirst('http://', 'https://');
    }
    if (trimmed.startsWith('//')) return 'https:$trimmed';
    return trimmed;
  }

  static String? _kugouCover(Map<String, dynamic> item) {
    final raw = _text(item['imgurl']) ??
        _text(item['img_url']) ??
        _text(item['Image']) ??
        _text(item['img']);
    if (raw == null) return null;
    return _httpsUrl(raw.replaceFirst('{size}', '480'));
  }
}

String? qqAlbumCover(String? albumMid) {
  final mid = albumMid?.trim();
  if (mid == null || mid.isEmpty) return null;
  return 'https://y.gtimg.cn/music/photo_new/T002R800x800M000$mid.jpg';
}

String? qqArtistCover(String? singerMid) {
  final mid = singerMid?.trim();
  if (mid == null || mid.isEmpty) return null;
  return 'https://y.gtimg.cn/music/photo_new/T001R300x300M000$mid.jpg';
}

double scoreCnAlbumCandidate({
  required String albumTitle,
  required String artist,
  required int trackCount,
  required int? yearHint,
  required CnAlbumCandidate candidate,
  Map<String, String> aliases = const {},
}) {
  final titleScore = albumTitleSimilarity(albumTitle, candidate.title);
  final artistScore = artist.trim().isEmpty
      ? 0.0
      : artistNameSimilarity(artist, candidate.artist, aliases: aliases);
  var score = titleScore * 55 + artistScore * 25;
  if (titleScore >= 0.999) score += 12;
  if (artistScore >= 0.999) score += 8;
  if (artist.trim().isNotEmpty &&
      candidate.artist.trim().isNotEmpty &&
      artistScore < 0.5) {
    score -= 30;
  }
  if (candidate.trackCount != null && trackCount > 0) {
    final diff = (candidate.trackCount! - trackCount).abs();
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
  if (yearHint != null && candidate.year != null) {
    final diff = (yearHint - candidate.year!).abs();
    score += diff == 0
        ? 12
        : diff == 1
        ? 6
        : diff <= 3
        ? 2
        : -6;
  }
  score += switch (candidate.source) {
    CnMusicSource.netease => 3,
    CnMusicSource.qq => 2,
    CnMusicSource.kugou => 1,
  };
  return score;
}

CnAlbumCandidate? pickBestCnAlbumCandidate({
  required String albumTitle,
  required String artist,
  required int trackCount,
  required int? yearHint,
  required List<CnAlbumCandidate> candidates,
  Map<String, String> aliases = const {},
}) {
  CnAlbumCandidate? best;
  var bestScore = double.negativeInfinity;
  for (final candidate in candidates) {
    final score = scoreCnAlbumCandidate(
      albumTitle: albumTitle,
      artist: artist,
      trackCount: trackCount,
      yearHint: yearHint,
      candidate: candidate,
      aliases: aliases,
    );
    if (score > bestScore) {
      bestScore = score;
      best = candidate;
    }
  }
  if (best == null || bestScore < minimumOnlineAlbumScore) return null;
  return best;
}

CnArtistCandidate? pickBestArtistCandidate({
  required String name,
  required List<CnArtistCandidate> candidates,
  Map<String, String> aliases = const {},
  double threshold = minimumArtistNameScore,
}) {
  CnArtistCandidate? best;
  var bestScore = 0.0;
  for (final candidate in candidates) {
    final pic = candidate.picUrl;
    if (pic == null || pic.isEmpty) continue;
    final score = artistNameSimilarity(name, candidate.name, aliases: aliases);
    if (score > bestScore) {
      bestScore = score;
      best = candidate;
    }
  }
  return bestScore >= threshold ? best : null;
}
