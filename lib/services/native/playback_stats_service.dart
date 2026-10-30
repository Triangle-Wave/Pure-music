import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/native/rust/api/library_db.dart' as rust_library_db;

/// 单曲播放排行条目。
class PlayCountRecord {
  const PlayCountRecord({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.playCount,
  });

  final String path;
  final String title;
  final String artist;
  final String album;
  final int playCount;
}

/// 一首曲目的播放时间戳（秒）。
class PlayHistoryRecord {
  const PlayHistoryRecord({required this.path, required this.playedAt});

  final String path;
  final List<int> playedAt;
}

/// 按日期聚合的播放次数。
class PlayHistoryDayCount {
  const PlayHistoryDayCount({required this.day, required this.count});

  final String day;
  final int count;
}

/// 统计页消费的播放流水聚合结果。
class PlayHistoryStats {
  const PlayHistoryStats({
    required this.total,
    required this.firstAt,
    required this.lastAt,
    required this.earliestAt,
    required this.daily,
    required this.hourly,
    required this.weekdayHourly,
  });

  final int total;
  final int firstAt;
  final int lastAt;
  final int earliestAt;
  final List<PlayHistoryDayCount> daily;
  final List<int> hourly;
  final List<int> weekdayHourly;
}

/// 播放统计入口，底层复用本地曲库的播放计数与流水。
class PlaybackStatsService {
  PlaybackStatsService._();

  static final instance = PlaybackStatsService._();

  String? _supportPath;

  Future<String> _indexPath() async =>
      _supportPath ??= (await getAppDataDir()).path;

  Future<List<PlayCountRecord>> getTopPlayed({required int limit}) async {
    try {
      final entries = await rust_library_db.getTopPlayed(
        indexPath: await _indexPath(),
        limit: limit,
      );
      return [
        for (final entry in entries)
          PlayCountRecord(
            path: entry.path,
            title: entry.title,
            artist: entry.artist,
            album: entry.album,
            playCount: entry.playCount.toInt(),
          ),
      ];
    } catch (error, stackTrace) {
      log.library.warn(
        'stats.top',
        '[stats] 读取播放排行失败',
        fields: {'limit': limit},
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<List<PlayHistoryRecord>> exportPlayHistory() async {
    try {
      final entries = await rust_library_db.exportPlayHistory(
        indexPath: await _indexPath(),
      );
      return [
        for (final entry in entries)
          PlayHistoryRecord(
            path: entry.path,
            playedAt: [for (final at in entry.playedAt) at.toInt()],
          ),
      ];
    } catch (error, stackTrace) {
      log.library.warn(
        'stats.history',
        '[stats] 导出播放流水失败',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}
