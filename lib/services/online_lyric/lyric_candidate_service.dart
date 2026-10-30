import 'package:flutter/foundation.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/matcher.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/karaok_parser.dart';
import 'package:pure_music/lyric/krc.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_loader.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/lyric/qrc.dart';
import 'package:pure_music/lyric/roman_word_mapper.dart';
import 'package:pure_music/lyric/ttml.dart';
import 'package:pure_music/services/online_lyric/lyric_candidate_cache.dart';
import 'package:pure_music/services/online_lyric/models/lyric_candidate.dart';

/// 搜索并下载每个在线来源的最佳歌词，组成候选列表。
///
/// 只在没有可用缓存（或用户主动刷新）时调用。单个来源失败不影响其它来源；
/// 全部失败时返回空列表，调用方回退到已有缓存。
Future<List<LyricCandidate>> fetchOnlineLyricCandidates(Audio audio) async {
  List<SongSearchResult> results;
  try {
    results = await uniSearch(
      audio,
    ).timeout(const Duration(seconds: 28), onTimeout: () {
      log.lyric.warn('lyric.cache', '歌词候选搜索超时');
      return const <SongSearchResult>[];
    });
  } catch (error, trace) {
    log.lyric.warn(
      'lyric.cache',
      '歌词候选搜索失败',
      error: error,
      stackTrace: trace,
    );
    return const [];
  }
  if (results.isEmpty) return const [];

  final fetchedAtMs = DateTime.now().millisecondsSinceEpoch;
  final loaded = await Future.wait(
    results.map((result) => _candidateForResult(audio, result, fetchedAtMs)),
  );
  final candidates = loaded.whereType<LyricCandidate>().toList();
  candidates.sort((a, b) => b.score.compareTo(a.score));
  log.lyric.info(
    'lyric.cache',
    '获取在线歌词候选',
    fields: {'count': candidates.length, 'sources': results.length},
  );
  return candidates;
}

Future<LyricCandidate?> _candidateForResult(
  Audio audio,
  SongSearchResult result,
  int fetchedAtMs,
) async {
  if (result.score < lyricCandidateMinScore) return null;
  final sourceId = lyricCandidateSourceId(result);
  if (sourceId == null || sourceId.isEmpty) return null;

  Lyric? lyric;
  try {
    lyric = await _requestLyricByResult(result, audio).timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        log.lyric.warn(
          'lyric.cache',
          '候选歌词下载超时',
          fields: {'source': result.source.name},
        );
        return null;
      },
    );
  } catch (error, trace) {
    log.lyric.warn(
      'lyric.cache',
      '候选歌词下载失败',
      fields: {'source': result.source.name},
      error: error,
      stackTrace: trace,
    );
    lyric = null;
  }
  if (lyric == null || lyric.lines.isEmpty) return null;

  return buildLyricCandidate(
    result: result,
    lyric: lyric,
    fetchedAtMs: fetchedAtMs,
  );
}

/// 由搜索结果与实际歌词构造候选记录。
LyricCandidate? buildLyricCandidate({
  required SongSearchResult result,
  required Lyric lyric,
  required int fetchedAtMs,
}) {
  final sourceId = lyricCandidateSourceId(result);
  if (sourceId == null || sourceId.isEmpty) return null;
  final source = lyricCandidateSourceName(result.source);
  final supplemental = lyricCandidateSupplementalText(lyric);
  return LyricCandidate(
    id: '$source:$sourceId',
    source: source,
    sourceId: sourceId,
    title: result.title,
    artist: result.artists,
    album: result.album,
    durationSec: result.duration ?? 0,
    score: result.score,
    format: lyricCandidateFormat(source, lyric),
    wordByWord: lyric.isWordByWord,
    text: lyric.rawText?.trim() ?? '',
    translationText: supplemental.translationText,
    romanizationText: supplemental.romanizationText,
    preview: lyricCandidatePreview(lyric),
    fetchedAtMs: fetchedAtMs,
  );
}

/// 提取每行的翻译与罗马音，写成与主歌词时间戳对齐的 LRC 文本。
///
/// 没有翻译或罗马音时对应字段为 null；本地转写生成的罗马音不写入候选。
({String? translationText, String? romanizationText})
lyricCandidateSupplementalText(Lyric lyric) {
  final supplemental = _supplementalLinesFromLyric(lyric);
  return (
    translationText: _formatSupplementalLines(supplemental.translation),
    romanizationText: _formatSupplementalLines(supplemental.romanization),
  );
}

String? _formatSupplementalLines(List<_CandidateSupplementalLine> lines) {
  if (lines.isEmpty) return null;
  final buffer = StringBuffer();
  for (final line in lines) {
    if (_isCandidatePlaceholder(line.text)) continue;
    buffer.writeln('${_candidateLrcTime(line.start)}${line.text}');
  }
  final text = buffer.toString().trim();
  return text.isEmpty ? null : text;
}

/// 候选保存的翻译与罗马音与主歌词行时间戳允许的最大偏差。
const int lyricCandidateSupplementalToleranceMs = 300;

/// 跨候选补齐时其余来源的优先级，数值越小越优先。
///
/// 用户选择或最佳分数的候选始终排在第一位，此表只决定其余候选的顺序。
const Map<String, int> lyricCandidateSourcePriority = {
  'kugou': 0,
  'qq': 1,
  'ne': 2,
  'amll': 3,
};

/// 候选文本解析结果的缓存条目上限。
const int lyricCandidateSupplementalCacheCapacity = 64;

final Map<String, _CandidateSupplemental> _supplementalTextCache = {};

/// 本次运行中候选文本被解析的次数，供测试确认缓存命中。
@visibleForTesting
int lyricCandidateSupplementalParseCount = 0;

/// 清空候选文本解析缓存并重置解析计数。
@visibleForTesting
void resetLyricCandidateSupplementalCache() {
  _supplementalTextCache.clear();
  lyricCandidateSupplementalParseCount = 0;
}

/// 把候选保存的翻译与罗马音按时间戳补回歌词的空字段。
///
/// 只填充空的 [LyricLine.translation] 与 [LyricLine.romanLyric]，
/// 主歌词解析出的内容优先；罗马音同时映射逐词时间供逐字显示使用。
Lyric applyLyricCandidateSupplemental(
  Lyric lyric, {
  String? translationText,
  String? romanizationText,
}) {
  _mergeCandidateSupplemental(
    lyric,
    _parseCandidateSupplemental(translationText),
    hasValue: _hasTranslation,
    apply: (line, text) => line.translation = text,
  );
  _mergeCandidateRomanization(
    lyric,
    _parseCandidateSupplemental(romanizationText),
  );
  return lyric;
}

/// 用同一记录里的其它候选补齐主歌词缺失的翻译与罗马音。
///
/// [candidates] 是同一首歌的全部候选，[primaryId] 是当前显示的候选；
/// 主歌词已齐全时直接返回，不解析任何候选文本。只填充空字段，已有内容
/// 不被覆盖，逐字时间轴保持不变。
Lyric applyCrossCandidateSupplemental(
  Lyric lyric,
  Iterable<LyricCandidate> candidates, {
  String? primaryId,
}) {
  final ordered = candidates
      .where((candidate) => candidate.id.isNotEmpty)
      .toList(growable: false);
  if (ordered.isEmpty) return lyric;
  var needTranslation = _hasMissingTranslation(lyric);
  var needRomanization = _hasMissingRomanization(lyric);
  if (!needTranslation && !needRomanization) return lyric;

  final sorted = [...ordered]
    ..sort((a, b) => _compareCandidatePriority(a, b, primaryId));
  for (final candidate in sorted) {
    if (!needTranslation && !needRomanization) break;
    final supplemental = _supplementalFor(
      candidate,
      needTranslation: needTranslation,
      needRomanization: needRomanization,
    );
    if (needTranslation && supplemental.translation.isNotEmpty) {
      _mergeCandidateSupplemental(
        lyric,
        supplemental.translation,
        hasValue: _hasTranslation,
        apply: (line, text) => line.translation = text,
      );
      needTranslation = _hasMissingTranslation(lyric);
    }
    if (needRomanization && supplemental.romanization.isNotEmpty) {
      _mergeCandidateRomanization(lyric, supplemental.romanization);
      needRomanization = _hasMissingRomanization(lyric);
    }
  }
  return lyric;
}

int _compareCandidatePriority(
  LyricCandidate a,
  LyricCandidate b,
  String? primaryId,
) {
  if (primaryId != null && primaryId.isNotEmpty) {
    final aPrimary = a.id == primaryId;
    final bPrimary = b.id == primaryId;
    if (aPrimary != bPrimary) return aPrimary ? -1 : 1;
  }
  final priorityA = lyricCandidateSourcePriority[a.source] ?? 99;
  final priorityB = lyricCandidateSourcePriority[b.source] ?? 99;
  if (priorityA != priorityB) return priorityA.compareTo(priorityB);
  return b.score.compareTo(a.score);
}

bool _hasTranslation(LyricLine line) {
  final text = line.translation?.trim() ?? '';
  return text.isNotEmpty && !_isCandidatePlaceholder(text);
}

bool _hasRomanization(LyricLine line) {
  if (line.autoRomanized) return false;
  final text = line.romanLyric?.trim() ?? '';
  return text.isNotEmpty && !_isCandidatePlaceholder(text);
}

void _applyRomanization(LyricLine line, String text) {
  line.romanLyric = text;
  line.autoRomanized = false;
  line.romanWords = mapRomanWords(
    romanText: text,
    words: line is SyncLyricLine ? line.words : null,
    lineStart: line.start,
    lineLength: line.length,
  );
}

bool _hasMissingTranslation(Lyric lyric) {
  for (final line in lyric.lines) {
    if (_candidateLineContent(line).isEmpty) continue;
    if (!_hasTranslation(line)) return true;
  }
  return false;
}

bool _hasMissingRomanization(Lyric lyric) {
  for (final line in lyric.lines) {
    if (_candidateLineContent(line).isEmpty) continue;
    if (!_hasRomanization(line)) return true;
  }
  return false;
}

/// 候选的翻译与罗马音行；优先使用候选保存的文本，缺失字段再从候选歌词
/// 文本解析出的内容补齐。
_CandidateSupplemental _supplementalFor(
  LyricCandidate candidate, {
  required bool needTranslation,
  required bool needRomanization,
}) {
  final translation = needTranslation
      ? _parseCandidateSupplemental(candidate.translationText)
      : const <_CandidateSupplementalLine>[];
  final romanization = needRomanization
      ? _parseCandidateSupplemental(candidate.romanizationText)
      : const <_CandidateSupplementalLine>[];
  final needsTextParse =
      (needTranslation && translation.isEmpty) ||
      (needRomanization && romanization.isEmpty);
  if (!needsTextParse || !candidate.hasText) {
    return _CandidateSupplemental(
      translation: translation,
      romanization: romanization,
    );
  }
  final parsed = _parsedSupplementalFor(candidate);
  return _CandidateSupplemental(
    translation: translation.isEmpty ? parsed.translation : translation,
    romanization: romanization.isEmpty ? parsed.romanization : romanization,
  );
}

_CandidateSupplemental _parsedSupplementalFor(LyricCandidate candidate) {
  final key = _supplementalTextCacheKey(candidate);
  final cached = _supplementalTextCache.remove(key);
  if (cached != null) {
    _supplementalTextCache[key] = cached;
    return cached;
  }
  lyricCandidateSupplementalParseCount++;
  var supplemental = _CandidateSupplemental.empty;
  try {
    final lyric = parseLyricCandidateText(candidate.text, candidate.format);
    if (lyric != null && lyric.lines.isNotEmpty) {
      supplemental = _supplementalLinesFromLyric(lyric);
    }
  } catch (error, trace) {
    log.lyric.warn(
      'lyric.cache',
      '候选补充内容解析失败',
      fields: {'candidate': candidate.id},
      error: error,
      stackTrace: trace,
    );
  }
  _supplementalTextCache[key] = supplemental;
  while (_supplementalTextCache.length >
      lyricCandidateSupplementalCacheCapacity) {
    _supplementalTextCache.remove(_supplementalTextCache.keys.first);
  }
  return supplemental;
}

String _supplementalTextCacheKey(LyricCandidate candidate) {
  final text = candidate.text;
  return '${candidate.id}\u0000${candidate.format}\u0000'
      '${text.length}\u0000${text.hashCode}';
}

_CandidateSupplemental _supplementalLinesFromLyric(Lyric lyric) {
  final translation = <_CandidateSupplementalLine>[];
  final romanization = <_CandidateSupplementalLine>[];
  for (final line in lyric.lines) {
    final translated = line.translation?.trim() ?? '';
    if (translated.isNotEmpty && !_isCandidatePlaceholder(translated)) {
      translation.add(_CandidateSupplementalLine(line.start, translated));
    }
    if (line.autoRomanized) continue;
    final roman = line.romanLyric?.trim() ?? '';
    if (roman.isNotEmpty && !_isCandidatePlaceholder(roman)) {
      romanization.add(_CandidateSupplementalLine(line.start, roman));
    }
  }
  return _CandidateSupplemental(
    translation: translation,
    romanization: romanization,
  );
}

class _CandidateSupplemental {
  const _CandidateSupplemental({
    required this.translation,
    required this.romanization,
  });

  static const _CandidateSupplemental empty = _CandidateSupplemental(
    translation: <_CandidateSupplementalLine>[],
    romanization: <_CandidateSupplementalLine>[],
  );

  final List<_CandidateSupplementalLine> translation;
  final List<_CandidateSupplementalLine> romanization;
}

class _CandidateSupplementalLine {
  const _CandidateSupplementalLine(this.start, this.text);

  final Duration start;
  final String text;
}

final _candidateSupplementalTimePattern = RegExp(
  r'^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]\s*(.*)$',
);

List<_CandidateSupplementalLine> _parseCandidateSupplemental(String? text) {
  final content = text?.trim() ?? '';
  if (content.isEmpty) return const [];
  final parsed = <_CandidateSupplementalLine>[];
  for (final raw in content.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final match = _candidateSupplementalTimePattern.firstMatch(line);
    if (match == null) continue;
    final minutes = int.tryParse(match.group(1) ?? '');
    final seconds = int.tryParse(match.group(2) ?? '');
    if (minutes == null || seconds == null) continue;
    final fraction = match.group(3);
    final milliseconds = fraction == null || fraction.isEmpty
        ? 0
        : int.tryParse(fraction.padRight(3, '0').substring(0, 3)) ?? 0;
    final body = (match.group(4) ?? '').trim();
    if (body.isEmpty || _isCandidatePlaceholder(body)) continue;
    parsed.add(
      _CandidateSupplementalLine(
        Duration(milliseconds: minutes * 60000 + seconds * 1000 + milliseconds),
        body,
      ),
    );
  }
  parsed.sort((a, b) => a.start.compareTo(b.start));
  return parsed;
}

void _mergeCandidateSupplemental(
  Lyric lyric,
  List<_CandidateSupplementalLine> supplemental, {
  required bool Function(LyricLine line) hasValue,
  required void Function(LyricLine line, String text) apply,
}) {
  final effective = _withoutCandidatePlaceholders(supplemental);
  if (effective.isEmpty) return;
  var cursor = 0;
  for (final line in lyric.lines) {
    if (_candidateLineContent(line).isEmpty) continue;
    if (hasValue(line)) continue;
    final lineMs = line.start.inMilliseconds;
    while (cursor + 1 < effective.length) {
      final currentMs = effective[cursor].start.inMilliseconds;
      final nextMs = effective[cursor + 1].start.inMilliseconds;
      if ((nextMs - lineMs).abs() >= (currentMs - lineMs).abs()) break;
      cursor++;
    }
    while (cursor > 0) {
      final currentMs = effective[cursor].start.inMilliseconds;
      final previousMs = effective[cursor - 1].start.inMilliseconds;
      if ((previousMs - lineMs).abs() >= (currentMs - lineMs).abs()) break;
      cursor--;
    }
    final diff = (effective[cursor].start.inMilliseconds - lineMs).abs();
    if (diff > lyricCandidateSupplementalToleranceMs) continue;
    apply(line, effective[cursor].text);
  }
}

/// 把候选罗马音补回缺失的行。
///
/// 有效歌词行与罗马音行数相等时按行序对齐，时间戳偏移不影响首行；
/// 行数不等时按时间戳匹配，并对首行使用较大的宽容差。`//` 占位行在
/// 歌词与罗马音两侧都按空行处理，不写入 [LyricLine.romanLyric]。
void _mergeCandidateRomanization(
  Lyric lyric,
  List<_CandidateSupplementalLine> supplemental,
) {
  final effective = _withoutCandidatePlaceholders(supplemental);
  if (effective.isEmpty) return;
  final targetLines = <LyricLine>[];
  final lyricStartsMs = <int>[];
  for (final line in lyric.lines) {
    if (_candidateLineContent(line).isEmpty) continue;
    targetLines.add(line);
    lyricStartsMs.add(line.start.inMilliseconds);
  }
  final alignment = alignSupplementalLines(
    lyricStartsMs: lyricStartsMs,
    supplementalStartsMs: [
      for (final line in effective) line.start.inMilliseconds,
    ],
    toleranceMs: lyricCandidateSupplementalToleranceMs,
  );
  for (var i = 0; i < alignment.length; i++) {
    final supplementalIndex = alignment[i];
    if (supplementalIndex == null) continue;
    final line = targetLines[i];
    if (_hasRomanization(line)) continue;
    _applyRomanization(line, effective[supplementalIndex].text);
  }
}

/// `//` 是占位行，与空行一样不参与有效行对齐。
bool _isCandidatePlaceholder(String text) => text.trim() == '//';

List<_CandidateSupplementalLine> _withoutCandidatePlaceholders(
  List<_CandidateSupplementalLine> lines,
) {
  return lines
      .where((line) => !_isCandidatePlaceholder(line.text))
      .toList(growable: false);
}

String _candidateLineContent(LyricLine line) {
  final String content;
  if (line is SyncLyricLine) {
    content = line.words.map((word) => word.content).join().trim();
  } else if (line is UnsyncLyricLine) {
    content = line.content.trim();
  } else {
    return '';
  }
  return _isCandidatePlaceholder(content) ? '' : content;
}

String _candidateLrcTime(Duration duration) {
  final totalMs = duration.inMilliseconds < 0 ? 0 : duration.inMilliseconds;
  final minutes = totalMs ~/ 60000;
  final seconds = (totalMs % 60000) ~/ 1000;
  final milliseconds = totalMs % 1000;
  return '[${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}.'
      '${milliseconds.toString().padLeft(3, '0')}]';
}

/// 候选的来源标识。
String lyricCandidateSourceName(ResultSource source) {
  return switch (source) {
    ResultSource.qq => 'qq',
    ResultSource.kugou => 'kugou',
    ResultSource.ne => 'ne',
    ResultSource.amll => 'amll',
  };
}

/// 搜索结果在来源内的歌曲标识。
String? lyricCandidateSourceId(SongSearchResult result) {
  return switch (result.source) {
    ResultSource.qq => result.qqSongId,
    ResultSource.kugou => result.kugouSongHash,
    ResultSource.ne => result.neSongId?.toString(),
    ResultSource.amll => result.amllTtmlFile,
  };
}

/// 候选歌词的文本格式，用于离线重建。
String lyricCandidateFormat(String source, Lyric lyric) {
  if (lyric is Ttml) return 'ttml';
  if (lyric is Krc) return 'krc';
  if (lyric is Qrc) {
    if (source == 'ne') return 'yrc';
    if (source == 'kugou') return 'krc';
    return 'qrc';
  }
  if (lyric is Lrc) return 'lrc';
  if (lyric is EnhancedLrc) return 'lrc';
  if (source == 'amll') return 'ttml';
  if (source == 'kugou') return 'krc';
  if (source == 'qq') return 'qrc';
  if (source == 'ne') return 'yrc';
  return 'lrc';
}

/// 提取候选的前几行歌词作为预览。
List<String> lyricCandidatePreview(Lyric lyric) {
  final preview = <String>[];
  for (final line in lyric.lines) {
    final content = switch (line) {
      SyncLyricLine() => line.content,
      UnsyncLyricLine() => line.content,
      _ => '',
    };
    final trimmed = content.trim();
    if (trimmed.isEmpty) continue;
    preview.add(trimmed);
    if (preview.length >= lyricCandidatePreviewLineCount) break;
  }
  return preview;
}

/// 把候选文本解析成歌词；格式解析失败时依次尝试 LRC 与内嵌歌词的检测规则。
Lyric? parseLyricCandidateText(String text, String format) {
  final content = text.trim();
  if (content.isEmpty) return null;
  final looksLikeTtml =
      content.startsWith('<?xml') ||
      content.startsWith('<tt') ||
      content.contains('<body>');
  final attempts = <String>[
    if (looksLikeTtml) '.ttml',
    if (format == 'qrc') '.qrc',
    if (format == 'krc') '.krc',
    if (format == 'yrc') '.yrc',
    if (format == 'ttml') '.ttml',
    '.lrc',
  ];
  final tried = <String>{};
  for (final extension in attempts) {
    if (!tried.add(extension)) continue;
    try {
      final lyric = parseExternalLyricText(content, extension);
      if (lyric != null && lyric.lines.isNotEmpty) return lyric;
    } catch (error, trace) {
      log.lyric.warn(
        'lyric.cache',
        '候选文本按 $extension 解析失败',
        error: error,
        stackTrace: trace,
      );
    }
  }
  try {
    final lyric = parseEmbeddedLyricText(content);
    if (lyric != null && lyric.lines.isNotEmpty) return lyric;
  } catch (error, trace) {
    log.lyric.warn(
      'lyric.cache',
      '候选文本按内嵌规则解析失败',
      error: error,
      stackTrace: trace,
    );
  }
  return null;
}

/// 由候选得到可播放的歌词；文本不可用或解析失败时按来源标识重新请求。
///
/// [peers] 为同一记录里的其它候选，用于补齐当前候选缺失的翻译与罗马音。
Future<Lyric?> loadLyricFromCandidate(
  LyricCandidate candidate,
  Audio audio, {
  Future<Lyric?> Function(LyricCandidate candidate)? loader,
  Iterable<LyricCandidate> peers = const <LyricCandidate>[],
}) async {
  final pool = _candidatePool(candidate, peers);
  if (candidate.hasText) {
    final parsed = parseLyricCandidateText(candidate.text, candidate.format);
    if (parsed != null && parsed.lines.isNotEmpty) {
      final merged = applyLyricCandidateSupplemental(
        parsed,
        translationText: candidate.translationText,
        romanizationText: candidate.romanizationText,
      );
      return applyCrossCandidateSupplemental(
        merged,
        pool,
        primaryId: candidate.id,
      );
    }
    log.lyric.warn(
      'lyric.cache',
      '候选歌词文本不可用，改为按来源重新请求',
      fields: {'source': candidate.source},
    );
  }
  try {
    final lyric =
        await (loader?.call(candidate) ?? _requestLyricById(candidate, audio))
            .timeout(const Duration(seconds: 12), onTimeout: () => null);
    if (lyric != null && lyric.lines.isNotEmpty) {
      return applyCrossCandidateSupplemental(
        lyric,
        pool,
        primaryId: candidate.id,
      );
    }
  } catch (error, trace) {
    log.lyric.warn(
      'lyric.cache',
      '按来源重新获取候选歌词失败',
      fields: {'source': candidate.source},
      error: error,
      stackTrace: trace,
    );
  }
  return null;
}

List<LyricCandidate> _candidatePool(
  LyricCandidate primary,
  Iterable<LyricCandidate> peers,
) {
  final pool = <String, LyricCandidate>{};
  for (final peer in peers) {
    pool[peer.id] = peer;
  }
  pool[primary.id] = primary;
  return pool.values.toList(growable: false);
}

/// 将候选转换为播放器现有的来源记录，供 lyric_sources 持久化。
LyricSource lyricSourceForCandidate(LyricCandidate candidate) {
  final type = switch (candidate.source) {
    'qq' => LyricSourceType.qq,
    'kugou' => LyricSourceType.kugou,
    'ne' => LyricSourceType.ne,
    'amll' => LyricSourceType.amll,
    _ => LyricSourceType.local,
  };
  return LyricSource(
    type,
    qqSongId: candidate.source == 'qq' ? candidate.sourceId : null,
    kugouSongHash: candidate.source == 'kugou' ? candidate.sourceId : null,
    neSongId: candidate.source == 'ne'
        ? int.tryParse(candidate.sourceId)
        : null,
    amllTtmlFile: candidate.source == 'amll' ? candidate.sourceId : null,
  );
}

/// 清空全部歌词候选缓存，返回删除的文件数。
Future<int> clearLyricCandidateCache() {
  return LyricCandidateCache.instance.clearAll();
}

/// 清空超过有效期的歌词候选缓存，返回删除的文件数。
Future<int> clearExpiredLyricCandidateCache() {
  return LyricCandidateCache.instance.clearExpired();
}

Future<Lyric?> _requestLyricByResult(
  SongSearchResult result,
  Audio audio,
) {
  return getOnlineLyric(
    qqSongId: result.qqSongId,
    kugouSongHash: result.kugouSongHash,
    neSongId: result.neSongId,
    amllTtmlFile: result.amllTtmlFile,
    title: audio.title,
    album: audio.album,
    artist: audio.artist,
    durationSec: audio.duration,
  );
}

Future<Lyric?> _requestLyricById(LyricCandidate candidate, Audio audio) {
  return getOnlineLyric(
    qqSongId: candidate.source == 'qq' ? candidate.sourceId : null,
    kugouSongHash: candidate.source == 'kugou' ? candidate.sourceId : null,
    neSongId: candidate.source == 'ne'
        ? int.tryParse(candidate.sourceId)
        : null,
    amllTtmlFile: candidate.source == 'amll' ? candidate.sourceId : null,
    title: audio.title,
    album: audio.album,
    artist: audio.artist,
    durationSec: audio.duration,
  );
}
