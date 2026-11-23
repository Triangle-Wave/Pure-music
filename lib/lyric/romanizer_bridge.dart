import 'package:flutter/foundation.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/native/rust/api/lyric_romanizer.dart' as rust_romanizer;

/// 批量转写实现：把若干行歌词转换为罗马音。
typedef RomanizeBatch =
    Future<List<String>> Function(List<String> texts, bool includeKanjiOnly);

/// 词典预热实现。
typedef RomanizerWarmup = Future<void> Function();

RomanizeBatch _romanizeBatch = _romanizeViaRust;
RomanizerWarmup _warmup = _warmupViaRust;

Future<List<String>> _romanizeViaRust(
  List<String> texts,
  bool includeKanjiOnly,
) {
  return rust_romanizer.romanizeJapaneseTexts(
    texts: texts,
    includeKanjiOnly: includeKanjiOnly,
  );
}

Future<void> _warmupViaRust() => rust_romanizer.romanizerWarmup();

/// 批量把歌词行转成罗马音。
///
/// 空输入直接返回空列表，不调用词典。词典失败或返回行数不符时按输入行数返回
/// 空串，保证调用方按行对齐；[includeKanjiOnly] 为 true 时纯汉字行也交给词典。
Future<List<String>> romanizeLines(
  List<String> lines, {
  bool includeKanjiOnly = false,
}) async {
  if (lines.isEmpty) return const <String>[];
  try {
    final result = await _romanizeBatch(lines, includeKanjiOnly);
    if (result.length == lines.length) return result;
    log.lyric.warn(
      'lyric.romanizer',
      '词典返回行数不一致，按空串补齐',
      fields: {'input': lines.length, 'output': result.length},
    );
    return List<String>.generate(
      lines.length,
      (index) => index < result.length ? result[index] : '',
    );
  } catch (err, trace) {
    log.lyric.warn(
      'lyric.romanizer',
      '词典转写失败，按空结果处理',
      fields: {'lines': lines.length},
      error: err,
      stackTrace: trace,
    );
    return List<String>.filled(lines.length, '');
  }
}

/// 启动后预热词典，失败只记 WARN，不影响启动。
Future<void> warmUpRomanizer() async {
  try {
    await _warmup();
  } catch (err, trace) {
    log.lyric.warn(
      'lyric.romanizer',
      '罗马音词典预热失败',
      error: err,
      stackTrace: trace,
    );
  }
}

/// 测试专用：替换批量转写与预热实现。
@visibleForTesting
void debugOverrideRomanizer({
  RomanizeBatch? romanize,
  RomanizerWarmup? warmup,
}) {
  _romanizeBatch = romanize ?? _romanizeViaRust;
  _warmup = warmup ?? _warmupViaRust;
}

/// 测试专用：恢复默认实现。
@visibleForTesting
void debugResetRomanizer() {
  _romanizeBatch = _romanizeViaRust;
  _warmup = _warmupViaRust;
}
