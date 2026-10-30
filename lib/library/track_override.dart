import 'package:pure_music/core/database.dart';

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
    required this.updatedAt,
  });

  final String trackUid;
  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final int? track;
  final int? disc;
  final int updatedAt;
}

/// 读写 `track_overrides` 表；失败时由调用方捕获并提示。
class TrackOverrideStore {
  TrackOverrideStore._();

  static final TrackOverrideStore instance = TrackOverrideStore._();

  Future<Map<String, TrackOverride>> loadAll() async {
    final db = await AppDb.instance.db();
    final rows = db.select(
      'SELECT track_uid, title, artist, album, album_artist, track, disc, '
      'updated_at FROM track_overrides',
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
        updatedAt: _readInt(row['updated_at']) ?? 0,
      );
    }
    return result;
  }

  Future<void> save(TrackOverride override) async {
    final db = await AppDb.instance.db();
    db.execute(
      'INSERT INTO track_overrides(track_uid, title, artist, album, '
      'album_artist, track, disc, updated_at) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(track_uid) DO UPDATE SET '
      'title = excluded.title, artist = excluded.artist, '
      'album = excluded.album, album_artist = excluded.album_artist, '
      'track = excluded.track, disc = excluded.disc, '
      'updated_at = excluded.updated_at',
      [
        override.trackUid,
        override.title,
        override.artist,
        override.album,
        override.albumArtist,
        override.track,
        override.disc,
        override.updatedAt,
      ],
    );
  }

  Future<void> remove(String trackUid) async {
    final db = await AppDb.instance.db();
    db.execute('DELETE FROM track_overrides WHERE track_uid = ?', [trackUid]);
  }
}

int? _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString().trim() ?? '');
}
