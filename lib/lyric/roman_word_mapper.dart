import 'package:pure_music/lyric/lyric.dart';

/// 罗马音 token 的独立时间窗口。
class RomanToken {
  final String text;
  final Duration start;
  final Duration length;

  const RomanToken(this.text, this.start, this.length);
}

/// 按空白拆分罗马音文本，保留标点。
List<String> splitRomanTokens(String text) {
  return RegExp(r'\S+')
      .allMatches(text)
      .map((match) => match.group(0)!)
      .toList();
}

/// 将整行罗马音映射为逐词时间。
///
/// 主词数量与罗马音 token 数量相同时直接继承主词时间；
/// 数量不等时，以主词时间范围（没有主词时用行时长）为轴，
/// 按罗马音 token 自身的字符数权重分配时间。
List<SyncLyricWord>? mapRomanWords({
  required String romanText,
  required List<SyncLyricWord>? words,
  required Duration lineStart,
  required Duration lineLength,
}) {
  final tokens = splitRomanTokens(romanText);
  if (tokens.isEmpty) return null;
  final timings = mapRomanTokenTimings(
    tokens: tokens,
    words: words,
    lineStart: lineStart,
    lineLength: lineLength,
  );
  if (timings == null) return null;
  return [
    for (final timing in timings)
      SyncLyricWord(timing.start, timing.length, timing.text),
  ];
}

/// 与 [mapRomanWords] 相同的映射规则，返回不依赖歌词模型的 token 时间。
List<RomanToken>? mapRomanTokenTimings({
  required List<String> tokens,
  required List<SyncLyricWord>? words,
  required Duration lineStart,
  required Duration lineLength,
}) {
  if (tokens.isEmpty) return null;

  if (words != null && words.length == tokens.length) {
    return [
      for (var i = 0; i < tokens.length; i++)
        RomanToken(tokens[i], words[i].start, words[i].length),
    ];
  }

  final axis = _timeAxis(words, lineStart, lineLength);
  if (axis == null) return null;
  final axisStartMs = axis.$1.inMilliseconds;
  final axisLengthMs = axis.$2.inMilliseconds;
  if (axisLengthMs <= 0) return null;

  final weights = [for (final token in tokens) _tokenWeight(token)];
  final totalWeight = weights.fold<int>(0, (sum, weight) => sum + weight);
  if (totalWeight <= 0) return null;

  final result = <RomanToken>[];
  var accumulated = 0;
  for (var i = 0; i < tokens.length; i++) {
    final startMs =
        axisStartMs + (axisLengthMs * accumulated / totalWeight).round();
    accumulated += weights[i];
    final endMs =
        axisStartMs + (axisLengthMs * accumulated / totalWeight).round();
    result.add(
      RomanToken(
        tokens[i],
        Duration(milliseconds: startMs),
        Duration(milliseconds: endMs - startMs),
      ),
    );
  }
  return result;
}

(Duration, Duration)? _timeAxis(
  List<SyncLyricWord>? words,
  Duration lineStart,
  Duration lineLength,
) {
  if (words != null && words.isNotEmpty) {
    final first = words.first.start;
    final last = words.last;
    final end = last.start + last.length;
    if (end > first) return (first, end - first);
  }
  if (lineLength > Duration.zero) return (lineStart, lineLength);
  return null;
}

int _tokenWeight(String text) {
  final count = text.runes.length;
  return count < 1 ? 1 : count;
}
