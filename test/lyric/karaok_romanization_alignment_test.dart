import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/karaok_parser.dart';
import 'package:pure_music/lyric/lyric.dart';

const _karaokText =
    '[0,1000]<0,500,0>Blue <500,500,0>sky\n'
    '[3200,1000]<0,500,0>second <500,500,0>line';

Lyric _parse(String? romanizationText) {
  return parseKaraokToPureLyric(
    '.krc',
    _karaokText,
    romanizationText: romanizationText,
  )!;
}

Lyric _parseText(String karaokText, String? romanizationText) {
  return parseKaraokToPureLyric(
    '.krc',
    karaokText,
    romanizationText: romanizationText,
  )!;
}

List<String?> _romaji(Lyric lyric) {
  return [
    for (final line in lyric.lines.cast<SyncLyricLine>()) line.romanLyric,
  ];
}

void main() {
  group('alignSupplementalLines', () {
    test('行数相等时按行序对齐，忽略首条时间戳偏移', () {
      expect(
        alignSupplementalLines(
          lyricStartsMs: [0, 3200],
          supplementalStartsMs: [2000, 5200],
        ),
        [0, 1],
      );
    });

    test('行数不等且补充缺首条时按时间戳匹配后续行', () {
      expect(
        alignSupplementalLines(
          lyricStartsMs: [0, 3200],
          supplementalStartsMs: [3200],
        ),
        [null, 0],
      );
    });

    test('行数不等且首条偏移在宽容差内时采用首条', () {
      expect(
        alignSupplementalLines(
          lyricStartsMs: [0, 3200],
          supplementalStartsMs: [800],
        ),
        [0, null],
      );
    });

    test('行数不等且首条偏移超出宽容差时不补首行', () {
      expect(
        alignSupplementalLines(
          lyricStartsMs: [0, 3200],
          supplementalStartsMs: [5000],
        ),
        [null, null],
      );
    });

    test('首条罗马音早于首句 2800ms 时采用首条', () {
      expect(
        alignSupplementalLines(
          lyricStartsMs: [3200, 6400],
          supplementalStartsMs: [400],
        ),
        [0, null],
      );
    });

    test('首条罗马音早于首句 5000ms 时不补首行', () {
      expect(
        alignSupplementalLines(
          lyricStartsMs: [5000, 8200],
          supplementalStartsMs: [0],
        ),
        [null, null],
      );
    });

    test('首条罗马音与第二句时间戳相同时留给第二句', () {
      expect(
        alignSupplementalLines(
          lyricStartsMs: [0, 2000],
          supplementalStartsMs: [2000],
        ),
        [null, 0],
      );
    });

    test('首条罗马音更贴近首句时按宽容差采用首条', () {
      expect(
        alignSupplementalLines(
          lyricStartsMs: [0, 2000],
          supplementalStartsMs: [800],
        ),
        [0, null],
      );
    });

    test('首条罗马音更贴近第二句时留给第二句', () {
      expect(
        alignSupplementalLines(
          lyricStartsMs: [0, 2000],
          supplementalStartsMs: [2800],
        ),
        [null, 0],
      );
    });

    test('首条罗马音超出宽容差且远离第二句时不补行', () {
      expect(
        alignSupplementalLines(
          lyricStartsMs: [0, 2000],
          supplementalStartsMs: [5000],
        ),
        [null, null],
      );
    });
  });

  group('parseKaraokToPureLyric 罗马音对齐', () {
    test('行数相等但首条罗马音晚 2 秒时第一句仍有罗马音', () {
      final lyric = _parse('[00:02.000]bu ruu\n[00:05.200]se kan do');

      expect(_romaji(lyric), ['bu ruu', 'se kan do']);
    });

    test('罗马音缺首句时第一句无罗马音，第二句正常', () {
      final lyric = _parse('[00:03.200]se kan do');

      expect(_romaji(lyric), [null, 'se kan do']);
    });

    test('罗马音首条只晚 800ms 时第一句按宽容差补齐', () {
      final lyric = _parse('[00:00.800]bu ruu');

      expect(_romaji(lyric), ['bu ruu', null]);
    });

    test('罗马音首条晚 5 秒时第一句不误配', () {
      final lyric = _parse('[00:05.000]bu ruu');

      expect(_romaji(lyric), [null, null]);
    });

    test('罗马音仍映射逐词时间且不标记为自动转写', () {
      final lyric = _parse('[00:02.000]bu ruu\n[00:05.200]se kan do');
      final first = lyric.lines.first as SyncLyricLine;

      expect(first.romanWords, isNotNull);
      expect(
        first.romanWords!.map((word) => word.content).join(' '),
        'bu ruu',
      );
      expect(first.autoRomanized, isFalse);
    });

    test('行数相等但含 // 占位行时不抢占罗马音', () {
      const karaokText =
          '[0,1000]<0,500,0>//\n'
          '[3200,1000]<0,500,0>first\n'
          '[6400,1000]<0,500,0>second';
      final lyric = _parseText(
        karaokText,
        '[00:05.200]roma one\n[00:08.400]roma two',
      );

      expect(_romaji(lyric), [null, 'roma one', 'roma two']);
    });
  });
}
