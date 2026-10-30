import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/services/online_lyric/lyric_candidate_service.dart';
import 'package:pure_music/services/online_lyric/models/lyric_candidate.dart';

Lyric _lyric() {
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

Lyric _shiftedLyric(int firstStartMs) {
  final secondStartMs = firstStartMs + 3200;
  return Lyric(
    [
      SyncLyricLine(
        Duration(milliseconds: firstStartMs),
        const Duration(seconds: 3),
        [
          SyncLyricWord(
            Duration(milliseconds: firstStartMs),
            const Duration(milliseconds: 1500),
            'first',
          ),
        ],
      ),
      SyncLyricLine(
        Duration(milliseconds: secondStartMs),
        const Duration(seconds: 3),
        [
          SyncLyricWord(
            Duration(milliseconds: secondStartMs),
            const Duration(milliseconds: 1500),
            'second',
          ),
        ],
      ),
    ],
    LyricFormat.qqmusic,
  );
}

Lyric _lyricWithPlaceholder() {
  return Lyric(
    [
      SyncLyricLine(
        Duration.zero,
        const Duration(seconds: 1),
        [
          SyncLyricWord(
            Duration.zero,
            const Duration(milliseconds: 500),
            '//',
          ),
        ],
      ),
      SyncLyricLine(
        const Duration(milliseconds: 3200),
        const Duration(seconds: 1),
        [
          SyncLyricWord(
            const Duration(milliseconds: 3200),
            const Duration(milliseconds: 500),
            'first',
          ),
        ],
      ),
      SyncLyricLine(
        const Duration(milliseconds: 6400),
        const Duration(seconds: 1),
        [
          SyncLyricWord(
            const Duration(milliseconds: 6400),
            const Duration(milliseconds: 500),
            'second',
          ),
        ],
      ),
    ],
    LyricFormat.qqmusic,
  );
}

LyricCandidate _candidate({
  required String id,
  required String source,
  String? romanizationText,
}) {
  return LyricCandidate(
    id: id,
    source: source,
    sourceId: id,
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    durationSec: 200,
    score: 90,
    format: 'lrc',
    wordByWord: false,
    text: '[00:00.000]first line\n[00:03.200]second line',
    romanizationText: romanizationText,
    preview: const ['first line', 'second line'],
    fetchedAtMs: 1,
  );
}

List<String?> _romaji(Lyric lyric) {
  return [for (final line in lyric.lines) line.romanLyric];
}

void main() {
  group('applyLyricCandidateSupplemental 罗马音对齐', () {
    test('行数相等但首条晚 2 秒时第一句仍补齐', () {
      final lyric = _lyric();

      applyLyricCandidateSupplemental(
        lyric,
        romanizationText: '[00:02.000]romaji one\n[00:05.200]romaji two',
      );

      expect(_romaji(lyric), ['romaji one', 'romaji two']);
    });

    test('罗马音缺首句时第一句不补，第二句正常', () {
      final lyric = _lyric();

      applyLyricCandidateSupplemental(
        lyric,
        romanizationText: '[00:03.200]romaji two',
      );

      expect(_romaji(lyric), [null, 'romaji two']);
    });

    test('首条只晚 800ms 时第一句按宽容差补齐', () {
      final lyric = _lyric();

      applyLyricCandidateSupplemental(
        lyric,
        romanizationText: '[00:00.800]romaji one',
      );

      expect(_romaji(lyric), ['romaji one', null]);
    });

    test('首条晚 5 秒时第一句不误配', () {
      final lyric = _lyric();

      applyLyricCandidateSupplemental(
        lyric,
        romanizationText: '[00:05.000]romaji one',
      );

      expect(_romaji(lyric), [null, null]);
    });

    test('行数相等但含 // 占位行时不错位', () {
      final lyric = _lyricWithPlaceholder();

      applyLyricCandidateSupplemental(
        lyric,
        romanizationText: '[00:05.200]romaji one\n[00:08.400]romaji two',
      );

      expect(_romaji(lyric), [null, 'romaji one', 'romaji two']);
    });

    test('首条罗马音早于首句 2800ms 时第一句仍补齐', () {
      final lyric = _shiftedLyric(3200);

      applyLyricCandidateSupplemental(
        lyric,
        romanizationText: '[00:00.400]romaji one',
      );

      expect(_romaji(lyric), ['romaji one', null]);
    });

    test('首条罗马音早于首句 5000ms 时第一句不补', () {
      final lyric = _shiftedLyric(5000);

      applyLyricCandidateSupplemental(
        lyric,
        romanizationText: '[00:00.000]romaji one',
      );

      expect(_romaji(lyric), [null, null]);
    });

    test('行数相等时已有罗马音的行跳过且索引照常前进', () {
      final lyric = _lyric();
      lyric.lines[0].romanLyric = '原有罗马音';

      applyLyricCandidateSupplemental(
        lyric,
        romanizationText: '[00:02.000]romaji one\n[00:05.200]romaji two',
      );

      expect(_romaji(lyric), ['原有罗马音', 'romaji two']);
    });

    test('候选罗马音含 // 占位行时不写入且行数对齐正确', () {
      final lyric = _lyricWithPlaceholder();

      applyLyricCandidateSupplemental(
        lyric,
        romanizationText:
            '[00:00.000]//\n'
            '[00:03.200]romaji one\n'
            '[00:06.400]romaji two',
      );

      expect(_romaji(lyric), [null, 'romaji one', 'romaji two']);
      expect(
        lyric.lines.where((line) => line.romanLyric == '//'),
        isEmpty,
      );
    });

    test('候选罗马音只有 // 占位行时不写入任何行', () {
      final lyric = _lyric();

      applyLyricCandidateSupplemental(
        lyric,
        romanizationText: '[00:00.000]//\n[00:03.200]//',
      );

      expect(_romaji(lyric), [null, null]);
    });

    test('已有 // 罗马音视为缺失并被候选补齐', () {
      final lyric = _lyric();
      lyric.lines[0].romanLyric = '//';

      applyLyricCandidateSupplemental(
        lyric,
        romanizationText: '[00:00.000]romaji one\n[00:03.200]romaji two',
      );

      expect(_romaji(lyric), ['romaji one', 'romaji two']);
    });
  });

  group('跨候选补罗马音', () {
    test('行数相等但首条晚 2 秒时第一句仍补齐', () {
      final lyric = _lyric();
      final primary = _candidate(id: 'qq:1', source: 'qq');
      final peer = _candidate(
        id: 'kugou:3',
        source: 'kugou',
        romanizationText: '[00:02.000]romaji one\n[00:05.200]romaji two',
      );

      applyCrossCandidateSupplemental(
        lyric,
        [primary, peer],
        primaryId: primary.id,
      );

      expect(_romaji(lyric), ['romaji one', 'romaji two']);
      expect(lyric.lines[0].romanWords, isNotNull);
      expect(lyric.lines[1].romanWords, isNotNull);
    });

    test('罗马音缺首句时第一句不补，第二句正常', () {
      final lyric = _lyric();
      final primary = _candidate(id: 'qq:1', source: 'qq');
      final peer = _candidate(
        id: 'kugou:3',
        source: 'kugou',
        romanizationText: '[00:03.200]romaji two',
      );

      applyCrossCandidateSupplemental(
        lyric,
        [primary, peer],
        primaryId: primary.id,
      );

      expect(_romaji(lyric), [null, 'romaji two']);
    });
  });
}
