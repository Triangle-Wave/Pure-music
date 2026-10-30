import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/online_lyric/models/lyric_entry.dart';
import 'package:pure_music/services/online_lyric/parsers/lrc_tool.dart';

void main() {
  group('LrcTool 罗马音逐词时间', () {
    test('主词数量一致时继承逐词时间', () {
      final result = LrcTool.parse(
        '[1000,1000](1000,500,0)君(1500,500,0)の',
        romanizationText: 'kimi no',
      );

      final line = result!.lines.single;
      expect(line.romanization, 'kimi no');
      expect(line.romanWords, isNotNull);
      expect(line.romanWords, hasLength(2));
      expect(line.romanWords![0].content, 'kimi');
      expect(line.romanWords![0].start, const Duration(seconds: 1));
      expect(line.romanWords![0].length, const Duration(milliseconds: 500));
      expect(line.romanWords![1].content, 'no');
      expect(line.romanWords![1].start, const Duration(milliseconds: 1500));
      expect(line.romanWords![1].length, const Duration(milliseconds: 500));
    });

    test('主词数量不一致时按字符权重分配行内时间', () {
      final result = LrcTool.parse(
        '[1000,1000](1000,500,0)君(1500,500,0)の',
        romanizationText: 'ki mi no',
      );

      final line = result!.lines.single;
      expect(line.romanWords, hasLength(3));
      expect(line.romanWords![0].start, const Duration(seconds: 1));
      expect(line.romanWords![0].length, const Duration(milliseconds: 333));
      expect(line.romanWords![1].start, const Duration(milliseconds: 1333));
      expect(line.romanWords![2].start, const Duration(milliseconds: 1667));
      expect(
        line.romanWords![2].start + line.romanWords![2].length,
        const Duration(seconds: 2),
      );
    });
  });

  group('LyricEntry.applyOffset', () {
    test('同步平移 romanWords', () {
      final result = ParsedLyricResult(
        lines: [
          LyricEntry(
            start: const Duration(seconds: 1),
            nextTime: const Duration(seconds: 2),
            content: '君',
            romanization: 'kimi',
            romanWords: [
              WordEntry(
                start: const Duration(seconds: 1),
                length: const Duration(milliseconds: 400),
                content: 'ki',
                nextTime: const Duration(milliseconds: 1400),
              ),
              WordEntry(
                start: const Duration(milliseconds: 1400),
                length: const Duration(milliseconds: 600),
                content: 'mi',
                nextTime: const Duration(seconds: 2),
              ),
            ],
          ),
        ],
      );

      final shifted = result.applyOffset(const Duration(milliseconds: 500));
      final line = shifted.lines.single;
      expect(line.start, const Duration(milliseconds: 1500));
      expect(line.romanWords, isNotNull);
      expect(
        line.romanWords![0].start,
        const Duration(milliseconds: 1500),
      );
      expect(line.romanWords![0].length, const Duration(milliseconds: 400));
      expect(
        line.romanWords![1].start,
        const Duration(milliseconds: 1900),
      );
      expect(line.romanWords![1].length, const Duration(milliseconds: 600));
    });

    test('没有 romanWords 时保持 null', () {
      final result = ParsedLyricResult(
        lines: [
          LyricEntry(
            start: const Duration(seconds: 1),
            nextTime: const Duration(seconds: 2),
            content: '君',
            romanization: 'kimi',
          ),
        ],
      );

      final shifted = result.applyOffset(const Duration(milliseconds: 500));
      expect(shifted.lines.single.romanWords, isNull);
    });
  });
}
