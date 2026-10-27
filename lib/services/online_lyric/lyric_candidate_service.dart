import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/matcher.dart';
import 'package:pure_music/library/audio_library.dart';
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
  final translations = StringBuffer();
  final romanizations = StringBuffer();
  for (final line in lyric.lines) {
    final timeTag = _candidateLrcTime(line.start);
    final translation = line.translation?.trim() ?? '';
    if (translation.isNotEmpty) {
      translations.writeln('$timeTag$translation');
    }
    if (line.autoRomanized) continue;
    final romanization = line.romanLyric?.trim() ?? '';
    if (romanization.isNotEmpty) {
      romanizations.writeln('$timeTag$romanization');
    }
  }
  final translationText = translations.toString().trim();
  final romanizationText = romanizations.toString().trim();
  return (
    translationText: translationText.isEmpty ? null : translationText,
    romanizationText: romanizationText.isEmpty ? null : romanizationText,
  );
}

/// 候选保存的翻译与罗马音与主歌词行时间戳允许的最大偏差。
const int lyricCandidateSupplementalToleranceMs = 300;

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
    hasValue: (line) => (line.translation?.trim() ?? '').isNotEmpty,
    apply: (line, text) => line.translation = text,
  );
  _mergeCandidateSupplemental(
    lyric,
    _parseCandidateSupplemental(romanizationText),
    hasValue: (line) =>
        !line.autoRomanized && (line.romanLyric?.trim() ?? '').isNotEmpty,
    apply: (line, text) {
      line.romanLyric = text;
      line.autoRomanized = false;
      line.romanWords = mapRomanWords(
        romanText: text,
        words: line is SyncLyricLine ? line.words : null,
        lineStart: line.start,
        lineLength: line.length,
      );
    },
  );
  return lyric;
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
    if (body.isEmpty) continue;
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
  if (supplemental.isEmpty) return;
  var cursor = 0;
  for (final line in lyric.lines) {
    if (_candidateLineContent(line).isEmpty) continue;
    if (hasValue(line)) continue;
    final lineMs = line.start.inMilliseconds;
    while (cursor + 1 < supplemental.length) {
      final currentMs = supplemental[cursor].start.inMilliseconds;
      final nextMs = supplemental[cursor + 1].start.inMilliseconds;
      if ((nextMs - lineMs).abs() >= (currentMs - lineMs).abs()) break;
      cursor++;
    }
    while (cursor > 0) {
      final currentMs = supplemental[cursor].start.inMilliseconds;
      final previousMs = supplemental[cursor - 1].start.inMilliseconds;
      if ((previousMs - lineMs).abs() >= (currentMs - lineMs).abs()) break;
      cursor--;
    }
    final diff = (supplemental[cursor].start.inMilliseconds - lineMs).abs();
    if (diff > lyricCandidateSupplementalToleranceMs) continue;
    apply(line, supplemental[cursor].text);
  }
}

String _candidateLineContent(LyricLine line) {
  if (line is SyncLyricLine) {
    return line.words.map((word) => word.content).join().trim();
  }
  if (line is UnsyncLyricLine) return line.content.trim();
  return '';
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
Future<Lyric?> loadLyricFromCandidate(
  LyricCandidate candidate,
  Audio audio, {
  Future<Lyric?> Function(LyricCandidate candidate)? loader,
}) async {
  if (candidate.hasText) {
    final parsed = parseLyricCandidateText(candidate.text, candidate.format);
    if (parsed != null && parsed.lines.isNotEmpty) {
      return applyLyricCandidateSupplemental(
        parsed,
        translationText: candidate.translationText,
        romanizationText: candidate.romanizationText,
      );
    }
    log.lyric.warn(
      'lyric.cache',
      '候选歌词文本不可用，改为按来源重新请求',
      fields: {'source': candidate.source},
    );
  }
  try {
    final lyric = await (loader?.call(candidate) ??
            _requestLyricById(candidate, audio))
        .timeout(const Duration(seconds: 12), onTimeout: () => null);
    if (lyric != null && lyric.lines.isNotEmpty) return lyric;
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
