import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/roman_word_mapper.dart';

// ──────────────────────────────────────────────
// KaraOK 格式（YRC/QRC/KRC）解析器
// 使用正则逐字解析，比原有 split 方式更健壮
// ──────────────────────────────────────────────

/// KaraOK 行正则：[start_ms,duration_ms]content
final _karaOkLineRe = RegExp(r'\[(\d+),(\d+)](.*?)(\r?\n|$)');

/// YRC 单词正则：(start,dur,?)text
final _yrcWordRe = RegExp(r'\((\d+),(\d+),\d+\)[^(]*?((?:.(?!\(\d+,))*.)');

/// QRC 单词正则：text(start,dur)
final _qrcWordRe = RegExp(r'[^(]*?((?:.(?!\(\d+,))*.)\((\d+),(\d+)\)');

/// KRC 单词正则：`<start,dur,?>text`
final _krcWordRe = RegExp(r'<(\d+),(\d+),\d+>[^<]*?((?:.(?!<\d+,))*.)');

/// 翻译时间戳：同时支持 KRC 和标准 LRC 时间戳。
final _translationTimestampRe = RegExp(
  r'\[(?:(\d+),\d+|(\d{1,3}):(\d{2}(?:\.\d{1,3})?))\]',
);

// ──────────────────────────────────────────────
// 内部模型
// ──────────────────────────────────────────────
class _Word {
  final int startMs;
  int durationMs;
  final String text;
  _Word(this.startMs, this.durationMs, this.text);
}

// ──────────────────────────────────────────────
// 单词解析配置
// ──────────────────────────────────────────────
class _WordConfig {
  final RegExp regex;
  final int startIdx, durIdx, textIdx;
  const _WordConfig(this.regex, this.startIdx, this.durIdx, this.textIdx);
}

_WordConfig? _configFor(String ext) => switch (ext) {
  '.yrc' => _WordConfig(_yrcWordRe, 1, 2, 3),
  '.qrc' => _WordConfig(_qrcWordRe, 2, 3, 1),
  '.krc' => _WordConfig(_krcWordRe, 1, 2, 3),
  _ => null,
};

// 合并小单词
// ──────────────────────────────────────────────
bool _shouldMerge(_Word curr, _Word last) =>
    curr.startMs == last.startMs ||
    ((curr.durationMs <= 60 || last.durationMs <= 60) && last.startMs > 0);

_Word _merge(_Word last, _Word curr) => _Word(
  last.startMs,
  last.durationMs + curr.durationMs,
  last.text + curr.text,
);

// ──────────────────────────────────────────────
// 单行单词解析
// ──────────────────────────────────────────────
List<_Word> _parseWords(
  String content,
  _WordConfig cfg,
  int lineStartMs,
  bool wordsAreAbsolute,
) {
  final words = <_Word>[];
  for (final m in cfg.regex.allMatches(content)) {
    final startMs = int.parse(m.group(cfg.startIdx)!);
    final durMs = int.parse(m.group(cfg.durIdx)!);
    final text = m.group(cfg.textIdx)!.replaceAll('\n', '');

    if (text.isEmpty) continue;

    final absStart = wordsAreAbsolute ? startMs : startMs + lineStartMs;
    final curr = _Word(absStart, durMs, text);

    if (words.isNotEmpty && _shouldMerge(curr, words.last)) {
      final last = words.last;
      if (last.startMs + last.durationMs >= curr.startMs) {
        words[words.length - 1] = _merge(last, curr);
        continue;
      }
    }
    words.add(curr);
  }
  return words;
}

// ──────────────────────────────────────────────
// 构建 Pure Music 的 SyncLyricLine
// ──────────────────────────────────────────────
SyncLyricLine _buildLine(
  Duration lineStart,
  Duration lineLength,
  List<_Word> words,
  String? translation, {
  String? romanization,
}) {
  final syncWords = words
      .map(
        (w) => SyncLyricWord(
          Duration(milliseconds: w.startMs),
          Duration(milliseconds: w.durationMs),
          w.text,
        ),
      )
      .toList();

  final line = SyncLyricLine(lineStart, lineLength, syncWords, translation);
  if (romanization != null && romanization.isNotEmpty && syncWords.isNotEmpty) {
    line.romanLyric = romanization;
    line.romanWords = mapRomanWords(
      romanText: romanization,
      words: syncWords,
      lineStart: lineStart,
      lineLength: lineLength,
    );
  }
  return line;
}

/// 解析带时间戳的翻译或罗马音文本，按行序返回。
List<_LineData> _parseTimedTextLines(String text) {
  final lines = <_LineData>[];
  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final timestamps = _translationTimestampRe
        .allMatches(rawLine)
        .toList(growable: false);
    final textStart = timestamps.isEmpty ? 0 : timestamps.last.end;
    for (final timestamp in timestamps) {
      final startMs = timestamp.group(1) != null
          ? int.parse(timestamp.group(1)!)
          : (((int.parse(timestamp.group(2)!) * 60) +
                        double.parse(timestamp.group(3)!)) *
                    1000)
                .round();
      lines.add(
        _LineData(
          start: Duration(milliseconds: startMs),
          length: Duration.zero,
          words: [],
          rawText: rawLine.substring(textStart).trim(),
        ),
      );
    }
  }
  return lines;
}

/// 把补充文本行（罗马音）对齐到歌词行，返回每条歌词对应的补充行下标。
///
/// 两侧有效行数相等时按行序一一对应，补充行与歌词行的时间戳偏移不影响
/// 对齐结果；行数不等时按时间戳做单向最近邻匹配，首行在
/// [firstLineRelaxedToleranceMs] 内放宽，补偿源文件首行时间戳的整体偏移。
/// 补充行更贴近下一句、或已落在下一句的 [toleranceMs] 内时首行不启用放宽，
/// 该行留给下一句。
/// 返回列表长度为 [lyricStartsMs] 的长度，`null` 表示该行没有补充内容。
List<int?> alignSupplementalLines({
  required List<int> lyricStartsMs,
  required List<int> supplementalStartsMs,
  int toleranceMs = 300,
  int firstLineRelaxedToleranceMs = 3000,
}) {
  final result = List<int?>.filled(lyricStartsMs.length, null);
  if (lyricStartsMs.isEmpty || supplementalStartsMs.isEmpty) {
    return result;
  }

  if (lyricStartsMs.length == supplementalStartsMs.length) {
    for (var i = 0; i < lyricStartsMs.length; i++) {
      result[i] = i;
    }
    return result;
  }

  var cursor = 0;
  for (var i = 0; i < lyricStartsMs.length; i++) {
    // 首行放宽时会把补充行预留给下一句，已填充的行不再处理。
    if (result[i] != null) continue;
    final lineMs = lyricStartsMs[i];
    while (cursor < supplementalStartsMs.length) {
      final diff = lineMs - supplementalStartsMs[cursor];
      if (diff.abs() <= toleranceMs) {
        result[i] = cursor;
        cursor++;
        break;
      }
      // 首行罗马音与歌词的时间戳整体错开时允许较大偏移，提前或滞后都适用，
      // 避免首句永久匹配失败。放宽前先比较首句与下一句到补充行的距离，
      // 更贴近下一句、或已落在下一句容差内时留给下一句，避免首句抢占。
      if (i == 0 &&
          cursor == 0 &&
          diff.abs() <= firstLineRelaxedToleranceMs) {
        final supplementalMs = supplementalStartsMs[cursor];
        final firstDistance = (lyricStartsMs[i] - supplementalMs).abs();
        if (i + 1 < lyricStartsMs.length) {
          final nextDistance = (lyricStartsMs[i + 1] - supplementalMs).abs();
          if (nextDistance <= toleranceMs || nextDistance < firstDistance) {
            result[i + 1] = cursor;
            cursor++;
            break;
          }
        }
        result[i] = cursor;
        cursor++;
        break;
      }
      if (diff < 0) break;
      cursor++;
    }
  }
  return result;
}

// ──────────────────────────────────────────────
// 🎯 主入口：解析 KaraOK 格式文本 → Pure Music Lyric
// ──────────────────────────────────────────────

/// 解析 YRC/QRC/KRC 格式歌词文本，返回 Pure Music 的 Lyric 对象。
///
/// [ext] 扩展名（.yrc / .qrc / .krc）
/// [content] 已解密/解码的歌词文本
/// [transContent] 可选的翻译文本（QRC/YRC 配对的 .lrc）
/// [romanizationText] 可选的罗马音文本，需带行时间戳
Lyric? parseKaraokToPureLyric(
  String ext,
  String content, {
  String? transContent,
  bool? keepMetadata,
  String? romanizationText,
}) {
  final shouldKeepMetadata =
      keepMetadata ?? AppSettings.instance.keepLyricMetadata;
  final cfg = _configFor(ext);
  if (cfg == null) return null;

  final wordsAreAbsolute = ext != '.krc'; // YRC/QRC 绝对时间，KRC 相对时间

  final List<_LineData> lines = [];

  for (final m in _karaOkLineRe.allMatches(content)) {
    final startMs = int.parse(m.group(1)!);
    final durMs = int.parse(m.group(2)!);
    final lineContent = m.group(3)!;

    final words = _parseWords(lineContent, cfg, startMs, wordsAreAbsolute);
    // 过滤元数据行（作詞：xxx、作曲/編曲：xxx 等）
    final lineText = words.map((w) => w.text).join();
    if (lineText.isNotEmpty &&
        !shouldKeepMetadata &&
        LrcLine.isLyricMetadataLine(lineText)) {
      continue;
    }

    lines.add(
      _LineData(
        start: Duration(milliseconds: startMs),
        length: Duration(milliseconds: durMs),
        words: words,
      ),
    );
  }

  if (lines.isEmpty) return null;

  // 合并翻译
  final transLines = transContent != null && transContent.isNotEmpty
      ? _parseTimedTextLines(transContent)
      : <_LineData>[];

  // 合并罗马音
  final romanLines = romanizationText != null && romanizationText.isNotEmpty
      ? _parseTimedTextLines(romanizationText)
      : <_LineData>[];
  final romanEntries = <_LineData>[];
  for (final r in romanLines) {
    final text = r.rawText?.trim();
    if (text == null || text.isEmpty || text == '//') continue;
    romanEntries.add(r);
  }

  // 罗马音按有效歌词行对齐：行数相等走行序，不等走时间戳兜底。
  // `//` 占位行与空行不占用行序，避免挤掉后续行的罗马音。
  final effectiveLineIndices = <int>[];
  final lyricStartsMs = <int>[];
  for (var i = 0; i < lines.length; i++) {
    final lineText = lines[i].words.map((word) => word.text).join().trim();
    if (lineText.isEmpty || lineText == '//') continue;
    effectiveLineIndices.add(i);
    lyricStartsMs.add(lines[i].start.inMilliseconds);
  }
  final romanAlignment = alignSupplementalLines(
    lyricStartsMs: lyricStartsMs,
    supplementalStartsMs: [
      for (final r in romanEntries) r.start.inMilliseconds,
    ],
  );
  final romanizationByLine = <int, String>{};
  for (var i = 0; i < romanAlignment.length; i++) {
    final romanIndex = romanAlignment[i];
    if (romanIndex == null) continue;
    romanizationByLine[effectiveLineIndices[i]] = romanEntries[romanIndex]
        .rawText!
        .trim();
  }

  // 构建最终的 SyncLyricLine 列表（翻译用两指针法按时间戳匹配）
  final resultLines = <SyncLyricLine>[];
  final metadataResultLines = <SyncLyricLine>{};
  const toleranceMs = 300;
  int transIdx = 0;

  for (int i = 0; i < lines.length; i++) {
    final l = lines[i];

    String? translation;

    while (transIdx < transLines.length) {
      final t = transLines[transIdx];
      final diff = l.start.inMilliseconds - t.start.inMilliseconds;

      if (diff.abs() <= toleranceMs) {
        translation = t.rawText?.trim();
        if (translation == '//') translation = null;
        transIdx++;
        break;
      } else if (diff < 0) {
        break;
      } else {
        transIdx++;
      }
    }

    final romanization = romanizationByLine[i];

    final line = _buildLine(
      l.start,
      l.length,
      l.words,
      translation,
      romanization: romanization,
    );
    resultLines.add(line);
    if (LrcLine.isLyricMetadataLine(l.words.map((word) => word.text).join())) {
      metadataResultLines.add(line);
    }
  }

  // 添加前奏空白行
  if (resultLines.isNotEmpty &&
      resultLines.first.start > const Duration(seconds: 5)) {
    resultLines.insert(
      0,
      SyncLyricLine(Duration.zero, resultLines.first.start, []),
    );
  }

  // 添加间奏空白行
  for (int i = resultLines.length - 1; i >= 1; i--) {
    final curr = resultLines[i - 1];
    final next = resultLines[i];
    // 元数据行后的空档属于前奏，不应显示成额外的间奏行。
    if (metadataResultLines.contains(curr)) continue;
    final gap = next.start - (curr.start + curr.length);
    if (gap > const Duration(seconds: 5)) {
      resultLines.insert(i, SyncLyricLine(curr.start + curr.length, gap, []));
    }
  }

  // UI 只检查 is SyncLyricLine，统一用 Lyric 包装即可
  return Lyric(resultLines.cast<LyricLine>(), LyricFormat.local);
}

class _LineData {
  final Duration start;
  final Duration length;
  final List<_Word> words;
  final String? rawText;
  _LineData({
    required this.start,
    required this.length,
    required this.words,
    this.rawText,
  });
}
