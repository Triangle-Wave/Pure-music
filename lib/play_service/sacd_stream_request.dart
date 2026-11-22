import 'package:pure_music/library/cue_segment_path.dart';

/// SACD 直播模式的取值：解码到 PCM 输出。
const String sacdStreamModePcm = 'pcm';

/// SACD 直播模式的取值：交给 BASS 的 DSD 解码。
const String sacdStreamModeDsd = 'dsd';

/// Rust 建流会话所需的参数。
class SacdStreamRequest {
  const SacdStreamRequest({
    required this.isoPath,
    required this.area,
    required this.trackNumber,
    required this.mode,
    required this.sampleRate,
    required this.bitDepth,
  });

  /// ISO 镜像路径。
  final String isoPath;

  /// SACD 区标记，`2ch` 或 `mch`。
  final String area;

  /// 区内轨号，从 1 开始。
  final int trackNumber;

  /// [sacdStreamModePcm] 或 [sacdStreamModeDsd]。
  final String mode;

  /// PCM 模式使用的输出采样率；DSD 模式不使用。
  final int sampleRate;

  /// PCM 模式使用的输出位深；DSD 模式不使用。
  final int bitDepth;
}

/// 由虚拟轨路径与播放设置生成建流参数。
///
/// 非 SACD 路径（普通文件、CUE 虚拟轨、非法 `sacd=` 标记）返回 null。
SacdStreamRequest? buildSacdStreamRequest({
  required String path,
  required bool preferPcm,
  required int sampleRate,
  required int bitDepth,
}) {
  final segment = parseCueSegmentPath(path);
  final area = segment?.sacdArea;
  if (segment == null || area == null) return null;
  return SacdStreamRequest(
    isoPath: segment.sourcePath,
    area: area,
    trackNumber: segment.trackNumber,
    mode: preferPcm ? sacdStreamModePcm : sacdStreamModeDsd,
    sampleRate: sampleRate,
    bitDepth: bitDepth,
  );
}
