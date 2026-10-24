import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/roman_word_mapper.dart';

void main() {
  group('mapRomanWords', () {
    test('按主词数量 1:1 继承逐词时间', () {
      final words = [
        SyncLyricWord(
          const Duration(milliseconds: 1000),
          const Duration(milliseconds: 400),
          '君',
        ),
        SyncLyricWord(
          const Duration(milliseconds: 1400),
          const Duration(milliseconds: 600),
          'の',
        ),
      ];

      final roman = mapRomanWords(
        romanText: 'kimi no',
        words: words,
        lineStart: const Duration(seconds: 1),
        lineLength: const Duration(seconds: 1),
      );

      expect(roman, isNotNull);
      expect(roman, hasLength(2));
      expect(roman![0].content, 'kimi');
      expect(roman[0].start, const Duration(milliseconds: 1000));
      expect(roman[0].length, const Duration(milliseconds: 400));
      expect(roman[1].content, 'no');
      expect(roman[1].start, const Duration(milliseconds: 1400));
      expect(roman[1].length, const Duration(milliseconds: 600));
    });

    test('数量不等时按罗马音 token 字符数分配行内时长', () {
      final words = [
        SyncLyricWord(
          const Duration(seconds: 2),
          const Duration(milliseconds: 300),
          'あ',
        ),
        SyncLyricWord(
          const Duration(milliseconds: 2300),
          const Duration(milliseconds: 300),
          'い',
        ),
        SyncLyricWord(
          const Duration(milliseconds: 2600),
          const Duration(milliseconds: 400),
          'う',
        ),
      ];

      final roman = mapRomanWords(
        romanText: 'a iu',
        words: words,
        lineStart: const Duration(seconds: 2),
        lineLength: const Duration(seconds: 1),
      );

      expect(roman, isNotNull);
      expect(roman, hasLength(2));
      // 时间轴取第一个主词到最后一个主词结束：2000ms..3000ms
      expect(roman![0].start, const Duration(seconds: 2));
      expect(roman[0].length, const Duration(milliseconds: 333));
      expect(roman[1].start, const Duration(milliseconds: 2333));
      expect(roman[1].length, const Duration(milliseconds: 667));
    });

    test('没有主词时按行时长分配', () {
      final roman = mapRomanWords(
        romanText: 'a bbb',
        words: null,
        lineStart: const Duration(seconds: 10),
        lineLength: const Duration(seconds: 4),
      );

      expect(roman, isNotNull);
      expect(roman, hasLength(2));
      expect(roman![0].start, const Duration(seconds: 10));
      expect(roman[0].length, const Duration(seconds: 1));
      expect(roman[1].start, const Duration(seconds: 11));
      expect(roman[1].length, const Duration(seconds: 3));
    });

    test('没有可用行时长时返回 null 以便渲染回退', () {
      final roman = mapRomanWords(
        romanText: 'a b',
        words: null,
        lineStart: const Duration(seconds: 3),
        lineLength: Duration.zero,
      );

      expect(roman, isNull);
    });

    test('空罗马音返回 null', () {
      final roman = mapRomanWords(
        romanText: '   ',
        words: null,
        lineStart: Duration.zero,
        lineLength: const Duration(seconds: 1),
      );

      expect(roman, isNull);
    });
  });
}
