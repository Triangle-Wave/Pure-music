/// 虚拟轨的合成路径：
/// - CUE：`<源文件>::track=01::start=0::end=200000`
/// - SACD：`<iso 路径>::track=01::start=0::end=200000::sacd=2ch`
class CueSegmentPath {
  const CueSegmentPath({
    required this.sourcePath,
    required this.trackNumber,
    required this.startMs,
    required this.endMs,
    this.sacdArea,
  });

  final String sourcePath;
  final int trackNumber;
  final int startMs;
  final int endMs;

  /// SACD 区标记："2ch"/"mch"；CUE 虚拟轨为 null。
  final String? sacdArea;

  int get durationMs => endMs > startMs ? endMs - startMs : 0;

  /// 是否为 SACD ISO 虚拟轨。
  bool get isSacd => sacdArea != null;

  /// 覆盖标签的稳定主键：源路径小写并统一分隔符，轨号至少两位。
  String get trackUid {
    final source = sourcePath.replaceAll('\\', '/').toLowerCase();
    final track = trackNumber.toString().padLeft(2, '0');
    final area = sacdArea;
    if (area == null) return 'cue:$source#$track';
    return 'sacd:$source#$area#$track';
  }
}

/// 解析合成路径；普通文件路径或非法后缀返回 null。
CueSegmentPath? parseCueSegmentPath(String path) {
  final marker = path.lastIndexOf('::track=');
  if (marker <= 0) return null;

  final sourcePath = path.substring(0, marker);
  final suffix = path.substring(marker + 2);
  final parts = suffix.split('::');
  if (parts.length != 3 && parts.length != 4) return null;

  final trackNumber = _parsePart(parts[0], 'track=');
  final startMs = _parsePart(parts[1], 'start=');
  final endMs = _parsePart(parts[2], 'end=');
  if (trackNumber == null || startMs == null || endMs == null) return null;
  if (trackNumber < 1 || endMs < startMs) return null;

  String? sacdArea;
  if (parts.length == 4) {
    final areaPart = parts[3];
    if (!areaPart.startsWith('sacd=')) return null;
    final areaLabel = areaPart.substring('sacd='.length);
    if (areaLabel != '2ch' && areaLabel != 'mch') return null;
    sacdArea = areaLabel;
  }

  return CueSegmentPath(
    sourcePath: sourcePath,
    trackNumber: trackNumber,
    startMs: startMs,
    endMs: endMs,
    sacdArea: sacdArea,
  );
}

int? _parsePart(String value, String prefix) {
  if (!value.startsWith(prefix)) return null;
  return int.tryParse(value.substring(prefix.length));
}
