import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/japanese_romanizer.dart';
import 'package:pure_music/lyric/lyric.dart';

void main() {
  group('JapaneseRomanizer.romanizeText', () {
    test('平假名按 Hepburn 转写', () {
      expect(JapaneseRomanizer.romanizeText('ありがとう'), 'arigatou');
      expect(JapaneseRomanizer.romanizeText('こんにちは'), 'konnichiha');
    });

    test('拗音、促音与长音', () {
      expect(JapaneseRomanizer.romanizeText('しゃしん'), 'shashin');
      expect(JapaneseRomanizer.romanizeText('きょう'), 'kyou');
      expect(JapaneseRomanizer.romanizeText('がっこう'), 'gakkou');
      expect(JapaneseRomanizer.romanizeText('まっちゃ'), 'matcha');
      expect(JapaneseRomanizer.romanizeText('メール'), 'meeru');
    });

    test('片假名与平假名一致', () {
      expect(JapaneseRomanizer.romanizeText('サヨナラ'), 'sayonara');
      expect(JapaneseRomanizer.romanizeText('カタカナ'), 'katakana');
    });

    test('汉字没有读音时跳过', () {
      expect(JapaneseRomanizer.romanizeText('君'), '');
      expect(JapaneseRomanizer.romanizeText('東京'), '');
      // 纯文本转换会跳过汉字，含汉字的行在生成入口处已被过滤。
      expect(JapaneseRomanizer.romanizeText('夜に駆ける'), 'nikeru');
    });

    test('拉丁字母与数字原样保留', () {
      expect(JapaneseRomanizer.romanizeText('hello'), 'hello');
      expect(JapaneseRomanizer.romanizeText('123'), '123');
    });
  });

  group('JapaneseRomanizer.isJapaneseLine', () {
    test('纯假名行视为日文', () {
      expect(JapaneseRomanizer.isJapaneseLine('ありがとう'), isTrue);
      expect(JapaneseRomanizer.isJapaneseLine('サヨナラ'), isTrue);
      expect(JapaneseRomanizer.isJapaneseLine('ずっと'), isTrue);
    });

    test('含汉字的行不生成，避免残缺读音', () {
      expect(JapaneseRomanizer.isJapaneseLine('夜に駆ける'), isFalse);
      expect(JapaneseRomanizer.isJapaneseLine('残酷な天使のテーゼ'), isFalse);
      expect(JapaneseRomanizer.isJapaneseLine('そうさ 僕らは'), isFalse);
    });

    test('中文、英文、韩文不生成', () {
      expect(JapaneseRomanizer.isJapaneseLine('我们的歌'), isFalse);
      expect(JapaneseRomanizer.isJapaneseLine('hello world'), isFalse);
      expect(JapaneseRomanizer.isJapaneseLine('사랑해'), isFalse);
    });

    test('零星假名的中文行不生成', () {
      expect(JapaneseRomanizer.isJapaneseLine('爱の歌'), isFalse);
    });
  });

  group('JapaneseRomanizer.buildRomanLine', () {
    test('按主词继承起始时间与时长', () {
      final words = [
        SyncLyricWord(
          Duration.zero,
          const Duration(milliseconds: 200),
          'きみ',
        ),
        SyncLyricWord(
          const Duration(milliseconds: 200),
          const Duration(milliseconds: 200),
          'の',
        ),
        SyncLyricWord(
          const Duration(milliseconds: 400),
          const Duration(milliseconds: 300),
          'こえ',
        ),
      ];

      final built = JapaneseRomanizer.buildRomanLine(
        words: words,
        lineStart: Duration.zero,
        lineLength: const Duration(milliseconds: 900),
      );

      expect(built, isNotNull);
      expect(built!.text, 'kimi no koe');
      expect(built.words, hasLength(3));
      expect(built.words[0].content, 'kimi');
      expect(built.words[0].start, Duration.zero);
      expect(built.words[0].length, const Duration(milliseconds: 200));
      expect(built.words[1].content, 'no');
      expect(built.words[1].start, const Duration(milliseconds: 200));
      expect(built.words[2].content, 'koe');
      expect(built.words[2].start, const Duration(milliseconds: 400));
      expect(built.words[2].length, const Duration(milliseconds: 300));
    });

    test('逐字主词各自生成 token', () {
      final words = [
        SyncLyricWord(
          const Duration(milliseconds: 100),
          const Duration(milliseconds: 100),
          'け',
        ),
        SyncLyricWord(
          const Duration(milliseconds: 200),
          const Duration(milliseconds: 100),
          'る',
        ),
      ];

      final built = JapaneseRomanizer.buildRomanLine(
        words: words,
        lineStart: const Duration(milliseconds: 100),
        lineLength: const Duration(milliseconds: 200),
      );

      expect(built, isNotNull);
      expect(built!.text, 'ke ru');
      expect(built.words, hasLength(2));
    });

    test('零时长主词回退到行时长', () {
      final built = JapaneseRomanizer.buildRomanLine(
        words: [
          SyncLyricWord(Duration.zero, Duration.zero, 'ありがとう'),
        ],
        lineStart: Duration.zero,
        lineLength: const Duration(seconds: 2),
      );

      expect(built, isNotNull);
      expect(built!.words.single.length, const Duration(seconds: 2));
    });

    test('非日文行返回 null', () {
      final built = JapaneseRomanizer.buildRomanLine(
        words: [
          SyncLyricWord(
            Duration.zero,
            const Duration(seconds: 1),
            '我们的歌',
          ),
        ],
        lineStart: Duration.zero,
        lineLength: const Duration(seconds: 1),
      );

      expect(built, isNull);
    });
  });

  group('自动罗马音应用', () {
    test('只补全缺少罗马音的日文行', () {
      final lyric = Lyric([
        _line('ありがとう'),
        _line('我们的歌'),
        _line('hello world'),
        _line('사랑해'),
        _line('ありがとう', roman: 'arigatou'),
      ]);

      applyAutoRomanization(lyric);

      final japanese = lyric.lines[0] as SyncLyricLine;
      expect(japanese.romanLyric, 'arigatou');
      expect(japanese.romanWords, isNotNull);
      expect(japanese.autoRomanized, isTrue);

      expect((lyric.lines[1] as SyncLyricLine).romanLyric, isNull);
      expect((lyric.lines[2] as SyncLyricLine).romanLyric, isNull);
      expect((lyric.lines[3] as SyncLyricLine).romanLyric, isNull);

      final authored = lyric.lines[4] as SyncLyricLine;
      expect(authored.romanLyric, 'arigatou');
      expect(authored.autoRomanized, isFalse);
    });

    test('重复应用不覆盖已生成的罗马音', () {
      final lyric = Lyric([_line('ありがとう')]);

      applyAutoRomanization(lyric);
      final first = (lyric.lines.first as SyncLyricLine).romanLyric;
      applyAutoRomanization(lyric);

      expect((lyric.lines.first as SyncLyricLine).romanLyric, first);
    });

    test('回退只清除生成内容，保留自带罗马音', () {
      final lyric = Lyric([
        _line('ありがとう'),
        _line('ありがとう', roman: 'arigatou'),
      ]);

      applyAutoRomanization(lyric);
      revertAutoRomanization(lyric);

      final generated = lyric.lines[0] as SyncLyricLine;
      expect(generated.romanLyric, isNull);
      expect(generated.romanWords, isNull);
      expect(generated.autoRomanized, isFalse);

      final authored = lyric.lines[1] as SyncLyricLine;
      expect(authored.romanLyric, 'arigatou');
    });
  });
}

SyncLyricLine _line(String content, {String? roman}) {
  return SyncLyricLine(
    Duration.zero,
    const Duration(seconds: 2),
    [SyncLyricWord(Duration.zero, const Duration(seconds: 2), content)],
    null,
    roman,
  );
}
