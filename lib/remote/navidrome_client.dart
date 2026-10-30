import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:pure_music/remote/remote_client.dart';
import 'package:pure_music/remote/remote_source.dart';

class NavidromeClient implements RemoteClient {
  static const _songCount = 500;
  static const _maxSongs = 200000;

  String _restBase(RemoteSource source) {
    final base = source.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    return base.endsWith('/rest') ? base : '$base/rest';
  }

  Map<String, String> _authParams(RemoteSource source, String password) {
    final salt = List.generate(
      8,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return {
      'u': source.username,
      't': md5.convert(utf8.encode('$password$salt')).toString(),
      's': salt,
      'v': '1.16.1',
      'c': 'PureMusic',
      'f': 'json',
    };
  }

  Map<String, dynamic> _decode(Response<dynamic> response) {
    final data = response.data;
    final map = data is String
        ? jsonDecode(data) as Map<String, dynamic>
        : data as Map<String, dynamic>;
    final body = map['subsonic-response'] ?? map['subsonicResponse'];
    if (body is! Map<String, dynamic>) {
      throw StateError('Navidrome 返回格式异常');
    }
    if (body['status'] == 'failed') {
      final error = body['error'];
      final message = error is Map ? error['message'] : null;
      throw StateError(message?.toString() ?? 'Navidrome 请求失败');
    }
    return body;
  }

  @override
  Future<List<RemoteTrack>> fetchTracks(
    RemoteSource source,
    String password, {
    RemoteSyncProgress? onProgress,
  }) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 30),
        responseType: ResponseType.plain,
      ),
    );
    final tracks = <RemoteTrack>[];
    final seenIds = <String>{};
    var offset = 0;
    while (offset < _maxSongs) {
      final response = await dio.get<dynamic>(
        '${_restBase(source)}/search3.view',
        queryParameters: {
          ..._authParams(source, password),
          'query': '',
          'songCount': _songCount,
          'songOffset': offset,
          'artistCount': 0,
          'albumCount': 0,
        },
      );
      final body = _decode(response);
      final result = body['searchResult3'];
      final songs = result is Map ? result['song'] : null;
      final list = songs is List ? songs : const <Object?>[];
      var added = 0;
      for (final raw in list) {
        if (raw is! Map) continue;
        final song = Map<String, dynamic>.from(raw);
        final track = _trackFromSong(source, song);
        if (!seenIds.add(track.trackId)) continue;
        tracks.add(track);
        added++;
      }
      onProgress?.call(
        (tracks.length / _maxSongs).clamp(0.0, 0.99),
        '已获取 ${tracks.length} 首',
      );
      if (list.length < _songCount) break;
      // 服务器忽略 songOffset 时本页不会带来新歌曲，避免重复拉取。
      if (added == 0) break;
      offset += list.length;
    }
    onProgress?.call(1, '已获取 ${tracks.length} 首');
    return tracks;
  }

  RemoteTrack _trackFromSong(RemoteSource source, Map<String, dynamic> song) {
    final created = _parseDate(song['created']);
    final modified = _parseDate(song['changed']);
    return RemoteTrack(
      sourceId: source.id,
      trackId: '${song['id']}',
      title: (song['title'] ?? '').toString(),
      artist: (song['artist'] ?? '').toString(),
      album: (song['album'] ?? '').toString(),
      albumArtist: song['albumArtist']?.toString(),
      track: _int(song['track']),
      disc: _int(song['discNumber']),
      duration: _int(song['duration']),
      bitrate: _int(song['bitRate']),
      sampleRate: _int(song['samplingRate']),
      bitDepth: _optionalInt(song['bitDepth']),
      modified: modified ?? created ?? 0,
      created: created ?? 0,
      by: song['artist']?.toString(),
      coverId: song['coverArt']?.toString(),
    );
  }

  int? _parseDate(Object? value) {
    if (value == null) return null;
    final parsed = DateTime.tryParse(value.toString());
    return parsed == null ? null : parsed.millisecondsSinceEpoch ~/ 1000;
  }

  int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  int? _optionalInt(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.isFinite ? value.toInt() : null;
    final text = value.toString().trim();
    return int.tryParse(text);
  }

  @override
  String playbackUrl(RemoteSource source, String password, String trackId) {
    final uri = Uri.parse('${_restBase(source)}/stream.view');
    return uri
        .replace(
          queryParameters: {
            ..._authParams(source, password),
            'id': trackId,
            'format': 'raw',
          },
        )
        .toString();
  }

  @override
  Future<Uint8List?> cover(
    RemoteSource source,
    String password,
    String? coverId,
    int size,
  ) async {
    if (coverId == null || coverId.isEmpty) return null;
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          responseType: ResponseType.bytes,
        ),
      );
      final response = await dio.get<List<int>>(
        '${_restBase(source)}/getCoverArt.view',
        queryParameters: {
          ..._authParams(source, password),
          'id': coverId,
          'size': size,
        },
      );
      final data = response.data;
      return data == null ? null : Uint8List.fromList(data);
    } catch (_) {
      return null;
    }
  }
}
