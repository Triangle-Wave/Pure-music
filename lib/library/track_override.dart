import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pure_music/core/database.dart';
import 'package:sqlite3/sqlite3.dart';

/// CUE 虚拟轨的本地标签覆盖值；不写回源音频文件。
class TrackOverride {
  const TrackOverride({
    required this.trackUid,
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.track,
    this.disc,
    this.genre,
    this.year,
    this.trackTotal,
    this.discTotal,
    this.composer,
    this.lyricist,
    this.label,
    this.comment,
    this.bpm,
    this.language,
    this.copyright,
    this.license,
    required this.updatedAt,
  });

  final String trackUid;
  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final int? track;
  final int? disc;
  final String? genre;
  final String? year;
  final int? trackTotal;
  final int? discTotal;
  final String? composer;
  final String? lyricist;
  final String? label;
  final String? comment;

  /// 保留原始文本，兼容 `128.5` 这类非整数 BPM。
  final String? bpm;
  final String? language;
  final String? copyright;
  final String? license;
  final int updatedAt;
}

/// 读写 `track_overrides` 表；失败时由调用方捕获并提示。
class TrackOverrideStore {
  TrackOverrideStore._() : _databaseProvider = null;

  static final TrackOverrideStore instance = TrackOverrideStore._();

  /// 用独立数据库构造，供测试隔离真实应用数据库。
  @visibleForTesting
  TrackOverrideStore.withDatabase(
    Future<Database> Function() databaseProvider,
  ) : _databaseProvider = databaseProvider;

  final Future<Database> Function()? _databaseProvider;

  Future<Database> _database() =>
      _databaseProvider?.call() ?? AppDb.instance.db();

  Future<Map<String, TrackOverride>> loadAll() async {
    final db = await _database();
    final rows = db.select(
      'SELECT track_uid, title, artist, album, album_artist, track, disc, '
      'genre, year, track_total, disc_total, composer, lyricist, label, '
      'comment, bpm, language, copyright, license, updated_at '
      'FROM track_overrides',
    );
    final result = <String, TrackOverride>{};
    for (final row in rows) {
      final trackUid = row['track_uid'] as String?;
      if (trackUid == null || trackUid.isEmpty) continue;
      result[trackUid] = TrackOverride(
        trackUid: trackUid,
        title: row['title'] as String?,
        artist: row['artist'] as String?,
        album: row['album'] as String?,
        albumArtist: row['album_artist'] as String?,
        track: _readInt(row['track']),
        disc: _readInt(row['disc']),
        genre: _readText(row['genre']),
        year: _readText(row['year']),
        trackTotal: _readInt(row['track_total']),
        discTotal: _readInt(row['disc_total']),
        composer: _readText(row['composer']),
        lyricist: _readText(row['lyricist']),
        label: _readText(row['label']),
        comment: _readText(row['comment']),
        bpm: _readText(row['bpm']),
        language: _readText(row['language']),
        copyright: _readText(row['copyright']),
        license: _readText(row['license']),
        updatedAt: _readInt(row['updated_at']) ?? 0,
      );
    }
    return result;
  }

  Future<void> save(TrackOverride override) async {
    final db = await _database();
    db.execute(
      'INSERT INTO track_overrides(track_uid, title, artist, album, '
      'album_artist, track, disc, genre, year, track_total, disc_total, '
      'composer, lyricist, label, comment, bpm, language, copyright, '
      'license, updated_at) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(track_uid) DO UPDATE SET '
      'title = excluded.title, artist = excluded.artist, '
      'album = excluded.album, album_artist = excluded.album_artist, '
      'track = excluded.track, disc = excluded.disc, '
      'genre = excluded.genre, year = excluded.year, '
      'track_total = excluded.track_total, disc_total = excluded.disc_total, '
      'composer = excluded.composer, lyricist = excluded.lyricist, '
      'label = excluded.label, comment = excluded.comment, '
      'bpm = excluded.bpm, language = excluded.language, '
      'copyright = excluded.copyright, license = excluded.license, '
      'updated_at = excluded.updated_at',
      [
        override.trackUid,
        override.title,
        override.artist,
        override.album,
        override.albumArtist,
        override.track,
        override.disc,
        override.genre,
        override.year,
        override.trackTotal,
        override.discTotal,
        override.composer,
        override.lyricist,
        override.label,
        override.comment,
        override.bpm,
        override.language,
        override.copyright,
        override.license,
        override.updatedAt,
      ],
    );
  }

  Future<void> remove(String trackUid) async {
    final db = await _database();
    db.execute('DELETE FROM track_overrides WHERE track_uid = ?', [trackUid]);
  }
}

int? _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString().trim() ?? '');
}

String? _readText(Object? value) {
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}
