import 'package:pure_music/library/audio_library.dart';

/// 播放器建流所需的位置参数。
///
/// SACD 交虚拟路径：外部流解析器据此打开 ISO 会话，段边界由会话自身给出。
/// CUE 虚拟轨与普通文件交真实源文件，段边界按毫秒截断。
({String path, int startMs, int endMs}) resolvePlaybackSource(Audio audio) {
  if (audio.isSacdTrack) {
    return (path: audio.path, startMs: 0, endMs: 0);
  }
  return (
    path: audio.filePath,
    startMs: audio.segmentStartMs,
    endMs: audio.segmentEndMs,
  );
}
