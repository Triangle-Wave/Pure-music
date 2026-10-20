/// CUE 虚拟轨的合成路径：`<源文件>::track=01::start=0::end=200000`。
class CueSegmentPath {
  const CueSegmentPath({
    required this.sourcePath,
    required this.trackNumber,
    required this.startMs,
    required this.endMs,
  });

  final String sourcePath;
  final int trackNumber;
  final int startMs;
  final int endMs;

  int get durationMs => endMs > startMs ? endMs - startMs : 0;
}

/// 解析合成路径；普通文件路径返回 null。
CueSegmentPath? parseCueSegmentPath(String path) {
  final marker = path.lastIndexOf('::track=');
  if (marker <= 0) return null;

  final sourcePath = path.substring(0, marker);
  final suffix = path.substring(marker + 2);
  final parts = suffix.split('::');
  if (parts.length != 3) return null;

  final trackNumber = _parsePart(parts[0], 'track=');
  final startMs = _parsePart(parts[1], 'start=');
  final endMs = _parsePart(parts[2], 'end=');
  if (trackNumber == null || startMs == null || endMs == null) return null;
  if (trackNumber < 1 || endMs < startMs) return null;

  return CueSegmentPath(
    sourcePath: sourcePath,
    trackNumber: trackNumber,
    startMs: startMs,
    endMs: endMs,
  );
}

int? _parsePart(String value, String prefix) {
  if (!value.startsWith(prefix)) return null;
  return int.tryParse(value.substring(prefix.length));
}
