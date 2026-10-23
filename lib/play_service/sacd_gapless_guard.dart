import 'package:pure_music/library/audio_library.dart';

/// 异步预建恢复后，列表版本、当前索引、在途对象与目标轨道都必须仍是原样。
///
/// SACD 轨的预建需要先等待缓存 DSF 提取完成，提取期间用户可能切歌、
/// 换列表或让播放器关闭，恢复后必须重新核对目标是否仍是原来的那一轨。
/// SACD 轨按 CueSegmentPath.trackUid 判断同一轨，普通曲目按对象身份判断。
bool isGaplessTargetStillCurrent({
  required bool closed,
  required int playlistRevision,
  required int currentPlaylistRevision,
  required int fromIndex,
  required int? currentIndex,
  required bool pendingStillActive,
  required Audio? currentTarget,
  required Audio target,
}) {
  final currentTrackUid = currentTarget?.cueSegment?.trackUid;
  final targetTrackUid = target.cueSegment?.trackUid;
  return !closed &&
      pendingStillActive &&
      playlistRevision == currentPlaylistRevision &&
      fromIndex == currentIndex &&
      currentTrackUid == targetTrackUid &&
      (targetTrackUid != null || identical(currentTarget, target));
}
