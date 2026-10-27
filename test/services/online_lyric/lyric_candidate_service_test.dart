import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/services/online_lyric/lyric_candidate_service.dart';
import 'package:pure_music/services/online_lyric/models/lyric_candidate.dart';

Audio _audio() {
  return Audio(
    'Song',
    'Artist',
    'Album',
    null,
    1,
    200,
    null,
    null,
    r'C:\Music\test.mp3',
    0,
    0,
    null,
  );
}

LyricCandidate _candidate({
  String id = 'qq:1',
  String source = 'qq',
  String sourceId = '1',
  double score = 90,
  String? text,
  String? translationText,
  String? romanizationText,
}) {
  return LyricCandidate(
    id: id,
    source: source,
    sourceId: sourceId,
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    durationSec: 200,
    score: score,
    format: 'lrc',
    wordByWord: false,
    text: text ?? '[00:00.000]first line\n[00:03.200]second line',
    translationText: translationText,
    romanizationText: romanizationText,
    preview: const ['first line', 'second line'],
    fetchedAtMs: 1,
  );
}

Lyric _syncLyric() {
  return Lyric(
    [
      SyncLyricLine(
        Duration.zero,
        const Duration(seconds: 3),
        [
          SyncLyricWord(
            Duration.zero,
            const Duration(milliseconds: 1500),
            'first',
          ),
          SyncLyricWord(
            const Duration(milliseconds: 1500),
            const Duration(milliseconds: 1500),
            ' line',
          ),
        ],
      ),
      SyncLyricLine(
        const Duration(milliseconds: 3200),
        const Duration(seconds: 3),
        [
          SyncLyricWord(
            const Duration(milliseconds: 3200),
            const Duration(milliseconds: 1500),
            'second',
          ),
          SyncLyricWord(
            const Duration(milliseconds: 4700),
            const Duration(milliseconds: 1500),
            ' line',
          ),
        ],
      ),
    ],
    LyricFormat.qqmusic,
  );
}

void main() {
  setUp(resetLyricCandidateSupplementalCache);

  test('LRC 候选文本可离线重建歌词', () {
    final lyric = parseLyricCandidateText(
      '[00:00.00]first line\n[00:03.20]second line\n[00:06.40]third line',
      'lrc',
    );

    expect(lyric, isNotNull);
    expect(lyric!.lines.length, greaterThanOrEqualTo(3));
  });

  test('格式标识不可靠时仍按 LRC 兜底解析', () {
    final lyric = parseLyricCandidateText(
      '[00:01.00]line one\n[00:02.00]line two',
      'qrc',
    );

    expect(lyric, isNotNull);
    expect(lyric!.isNotEmpty, isTrue);
  });

  test('空文本返回 null', () {
    expect(parseLyricCandidateText('', 'lrc'), isNull);
    expect(parseLyricCandidateText('   ', 'lrc'), isNull);
  });

  test('候选提取每行翻译与罗马音并跳过本地转写', () {
    final lyric = Lrc(
      [
        LrcLine(Duration.zero, 'line one', requiredIsBlank: false)
          ..translation = '译文一'
          ..romanLyric = 'romaji one',
        LrcLine(const Duration(seconds: 3), 'line two', requiredIsBlank: false)
          ..romanLyric = 'local romanization'
          ..autoRomanized = true,
      ],
      LyricFormat.local,
      '[00:00.000]line one',
    );

    final supplemental = lyricCandidateSupplementalText(lyric);

    expect(supplemental.translationText, '[00:00.000]译文一');
    expect(supplemental.romanizationText, '[00:00.000]romaji one');
  });

  test('候选重建后按时间戳补回翻译与罗马音', () async {
    final lyric = await loadLyricFromCandidate(
      _candidate(
        translationText: '[00:00.000]第一行翻译\n[00:03.200]第二行翻译',
        romanizationText: '[00:00.120]romaji one\n[00:03.320]romaji two',
      ),
      _audio(),
      loader: (_) async => null,
    );

    expect(lyric, isNotNull);
    final first = lyric!.lines.firstWhere(
      (line) => line.start == Duration.zero,
    );
    final second = lyric.lines.firstWhere(
      (line) => line.start == const Duration(milliseconds: 3200),
    );

    expect(first.translation, '第一行翻译');
    expect(first.romanLyric, 'romaji one');
    expect(second.translation, '第二行翻译');
    expect(second.romanLyric, 'romaji two');
    expect(second.romanWords, isNotNull);
    expect(
      second.romanWords!.map((word) => word.content).join(' '),
      'romaji two',
    );
  });

  test('已有翻译与罗马音不被候选补充文本覆盖', () {
    final lyric = Lrc(
      [
        LrcLine(Duration.zero, 'line one', requiredIsBlank: false)
          ..translation = '原有翻译'
          ..romanLyric = '原有罗马音',
      ],
      LyricFormat.local,
    );

    applyLyricCandidateSupplemental(
      lyric,
      translationText: '[00:00.000]候选翻译',
      romanizationText: '[00:00.000]candidate romaji',
    );

    final line = lyric.lines.first;
    expect(line.translation, '原有翻译');
    expect(line.romanLyric, '原有罗马音');
  });

  test('已有翻译不被候选补充文本覆盖', () async {
    final lyric = await loadLyricFromCandidate(
      _candidate(
        text:
            '[00:00.000]first line\n'
            '[00:00.000]原有翻译\n'
            '[00:03.200]second line',
        translationText: '[00:00.000]候选翻译\n[00:03.200]第二行翻译',
        romanizationText: '[00:03.200]romaji two',
      ),
      _audio(),
      loader: (_) async => null,
    );

    expect(lyric, isNotNull);
    final first = lyric!.lines.firstWhere(
      (line) => line.start == Duration.zero,
    );
    final second = lyric.lines.firstWhere(
      (line) => line.start == const Duration(milliseconds: 3200),
    );

    expect(first.translation, '原有翻译');
    expect(second.translation, '第二行翻译');
    expect(second.romanLyric, 'romaji two');
  });

  group('跨候选补充', () {
    test('主候选只有逐字时由其它候选补齐翻译与罗马音', () {
      final lyric = _syncLyric();
      final primary = _candidate(id: 'qq:1', source: 'qq', score: 95);
      final translated = _candidate(
        id: 'ne:2',
        source: 'ne',
        sourceId: '2',
        score: 80,
        translationText: '[00:00.000]第一行翻译\n[00:03.200]第二行翻译',
      );
      final romanized = _candidate(
        id: 'kugou:3',
        source: 'kugou',
        sourceId: '3',
        score: 70,
        romanizationText: '[00:00.000]romaji one\n[00:03.200]romaji two',
      );

      final merged = applyCrossCandidateSupplemental(
        lyric,
        [primary, translated, romanized],
        primaryId: primary.id,
      );

      expect(merged, same(lyric));
      final first = lyric.lines[0] as SyncLyricLine;
      final second = lyric.lines[1] as SyncLyricLine;
      expect(first.translation, '第一行翻译');
      expect(second.translation, '第二行翻译');
      expect(first.romanLyric, 'romaji one');
      expect(second.romanLyric, 'romaji two');
      expect(first.romanWords, isNotNull);
      expect(second.romanWords, isNotNull);
      expect(first.words.map((word) => word.content).join(), 'first line');
      expect(
        first.words.map((word) => word.start),
        [Duration.zero, const Duration(milliseconds: 1500)],
      );
    });

    test('主歌词已有翻译与罗马音时不被其它候选覆盖', () {
      final lyric = _syncLyric();
      for (final line in lyric.lines) {
        line.translation = '原有翻译';
        line.romanLyric = '原有罗马音';
      }
      final primary = _candidate(id: 'qq:1', source: 'qq', score: 95);
      final other = _candidate(
        id: 'kugou:3',
        source: 'kugou',
        sourceId: '3',
        score: 70,
        translationText: '[00:00.000]候选翻译\n[00:03.200]候选翻译二',
        romanizationText: '[00:00.000]candidate romaji\n'
            '[00:03.200]candidate romaji two',
      );

      applyCrossCandidateSupplemental(
        lyric,
        [primary, other],
        primaryId: primary.id,
      );

      for (final line in lyric.lines) {
        expect(line.translation, '原有翻译');
        expect(line.romanLyric, '原有罗马音');
      }
      expect(lyricCandidateSupplementalParseCount, 0);
    });

    test('部分字段已有时只补缺失字段', () {
      final lyric = _syncLyric();
      lyric.lines[0].translation = '原有翻译';
      final other = _candidate(
        id: 'kugou:3',
        source: 'kugou',
        sourceId: '3',
        score: 70,
        translationText: '[00:00.000]候选翻译\n[00:03.200]第二候选翻译',
        romanizationText: '[00:00.000]romaji one\n[00:03.200]romaji two',
      );

      applyCrossCandidateSupplemental(lyric, [other]);

      expect(lyric.lines[0].translation, '原有翻译');
      expect(lyric.lines[1].translation, '第二候选翻译');
      expect(lyric.lines[0].romanLyric, 'romaji one');
      expect(lyric.lines[1].romanLyric, 'romaji two');
    });

    test('时间戳不一致时按容差匹配，超出容差不匹配', () {
      final lyric = _syncLyric();
      final primary = _candidate(id: 'qq:1', source: 'qq', score: 95);
      final other = _candidate(
        id: 'ne:2',
        source: 'ne',
        sourceId: '2',
        score: 80,
        translationText:
            '[00:00.150]偏移在容差内的翻译\n'
            '[00:03.550]偏移超出容差的翻译',
      );

      applyCrossCandidateSupplemental(
        lyric,
        [primary, other],
        primaryId: primary.id,
      );

      expect(lyric.lines[0].translation, '偏移在容差内的翻译');
      expect(lyric.lines[1].translation, isNull);
    });

    test('候选文本解析出的翻译被缓存，重复加载不再解析', () {
      final candidate = _candidate(
        id: 'ne:9',
        source: 'ne',
        sourceId: '9',
        text:
            '[00:00.000]first line\n'
            '[00:00.000]文本翻译一\n'
            '[00:03.200]second line\n'
            '[00:03.200]文本翻译二',
      );

      applyCrossCandidateSupplemental(
        _syncLyric(),
        [candidate],
        primaryId: candidate.id,
      );
      expect(lyricCandidateSupplementalParseCount, 1);

      final secondLyric = _syncLyric();
      applyCrossCandidateSupplemental(
        secondLyric,
        [candidate],
        primaryId: candidate.id,
      );
      expect(lyricCandidateSupplementalParseCount, 1);
      expect(secondLyric.lines[0].translation, '文本翻译一');
      expect(secondLyric.lines[1].translation, '文本翻译二');
    });

    test('候选都有罗马音时按来源优先级选取', () {
      final lyric = _syncLyric();
      final primary = _candidate(id: 'qq:1', source: 'qq', score: 95);
      final amll = _candidate(
        id: 'amll:a',
        source: 'amll',
        sourceId: 'a',
        score: 99,
        romanizationText: '[00:00.000]amll romaji\n[00:03.200]amll romaji two',
      );
      final kugou = _candidate(
        id: 'kugou:3',
        source: 'kugou',
        sourceId: '3',
        score: 60,
        romanizationText: '[00:00.000]kugou romaji\n[00:03.200]kugou romaji two',
      );

      applyCrossCandidateSupplemental(
        lyric,
        [primary, amll, kugou],
        primaryId: primary.id,
      );

      expect(lyric.lines[0].romanLyric, 'kugou romaji');
      expect(lyric.lines[1].romanLyric, 'kugou romaji two');
    });

    test('loadLyricFromCandidate 接收同记录其余候选并补齐', () async {
      final primary = _candidate(id: 'qq:1', source: 'qq');
      final peer = _candidate(
        id: 'kugou:2',
        source: 'kugou',
        sourceId: '2',
        score: 70,
        translationText: '[00:00.000]第一行翻译\n[00:03.200]第二行翻译',
        romanizationText: '[00:00.000]romaji one\n[00:03.200]romaji two',
      );

      final lyric = await loadLyricFromCandidate(
        primary,
        _audio(),
        loader: (_) async => null,
        peers: [peer],
      );

      expect(lyric, isNotNull);
      final first = lyric!.lines.firstWhere(
        (line) => line.start == Duration.zero,
      );
      final second = lyric.lines.firstWhere(
        (line) => line.start == const Duration(milliseconds: 3200),
      );
      expect(first.translation, '第一行翻译');
      expect(first.romanLyric, 'romaji one');
      expect(second.translation, '第二行翻译');
      expect(second.romanLyric, 'romaji two');
    });
  });
}
