import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/search_text_normalizer.dart';
import 'package:pure_music/core/zh_converter.dart';

void main() {
  group('ZhConverter.toSimple', () {
    test('converts common traditional characters', () {
      expect(ZhConverter.toSimple('再見'), '再见');
      expect(ZhConverter.toSimple('鄧紫棋'), '邓紫棋');
      expect(ZhConverter.toSimple('龍'), '龙');
      expect(ZhConverter.toSimple('樂'), '乐');
      expect(ZhConverter.toSimple('臺灣'), '台湾');
    });

    test('is idempotent for simplified input', () {
      const simplified = '再见邓紫棋龙乐';
      expect(ZhConverter.toSimple(simplified), simplified);
      expect(
        ZhConverter.toSimple(ZhConverter.toSimple('再見鄧紫棋龍樂')),
        '再见邓紫棋龙乐',
      );
    });

    test('keeps non-Chinese and unchanged characters', () {
      expect(ZhConverter.toSimple('Abc 123!'), 'Abc 123!');
      expect(ZhConverter.toSimple(''), '');
    });
  });

  group('ZhConverter.toTraditional', () {
    test('round-trips common characters back to simplified', () {
      for (final text in ['再见', '邓紫棋', '龙', '乐']) {
        expect(ZhConverter.toSimple(ZhConverter.toTraditional(text)), text);
      }
    });

    test('maps common simplified characters to a traditional form', () {
      expect(ZhConverter.toTraditional('龙'), '龍');
      expect(ZhConverter.toTraditional('乐'), '樂');
    });

    test('one-to-many characters use the first OpenCC candidate', () {
      expect(ZhConverter.toTraditional('台'), '檯');
      expect(ZhConverter.toTraditional('里'), '裏');
      expect(ZhConverter.toTraditional('干'), '乾');
      expect(ZhConverter.toTraditional('面'), '麪');
    });
  });

  group('normalizeSearchText', () {
    test('trims, removes whitespace, lowercases and simplifies', () {
      expect(normalizeSearchText('  再  見  '), '再见');
      expect(normalizeSearchText('Deng Zi Qi'), 'dengziqi');
      expect(normalizeSearchText('鄧紫棋'), '邓紫棋');
    });

    test('is idempotent', () {
      const query = '再见邓紫棋';
      expect(normalizeSearchText(normalizeSearchText(query)), query);
    });
  });
}
