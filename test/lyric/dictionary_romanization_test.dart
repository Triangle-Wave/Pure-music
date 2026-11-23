import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/japanese_romanizer.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/romanizer_bridge.dart';

SyncLyricLine _line(int index, String text, {String? romanLyric}) {
  final start = Duration(seconds: index);
  const length = Duration(seconds: 1);
  return SyncLyricLine(
    start,
    length,
    [SyncLyricWord(start, length, text)],
    null,
    romanLyric,
  );
}

Lyric _lyric(List<String> texts) {
  return Lyric([
    for (var i = 0; i < texts.length; i++) _line(i, texts[i]),
  ]);
}

void main() {
  tearDown(debugResetRomanizer);

  test('日语歌用词典填充整首罗马音', () async {
    final lyric = _lyric(['きみのなまえ', 'そら']);
    var calls = 0;
    debugOverrideRomanizer(
      romanize: (texts, includeKanjiOnly) async {
        calls++;
        return [for (final _ in texts) 'kimi'];
      },
    );

    await applyDictionaryRomanization(lyric);

    expect(calls, 1);
    for (final line in lyric.lines.cast<SyncLyricLine>()) {
      expect(line.romanLyric, 'kimi');
      expect(line.romanWords, isNotNull);
      expect(line.autoRomanized, isTrue);
    }

    // 已生成的行不再重复提交。
    await applyDictionaryRomanization(lyric);
    expect(calls, 1);
  });

  test('中文歌不调用词典且不产生罗马音', () async {
    final lyric = _lyric(['晴天', '稻香']);
    var calls = 0;
    debugOverrideRomanizer(
      romanize: (texts, includeKanjiOnly) async {
        calls++;
        return const <String>[];
      },
    );

    await applyDictionaryRomanization(lyric);

    expect(calls, 0);
    for (final line in lyric.lines.cast<SyncLyricLine>()) {
      expect(line.romanLyric, isNull);
      expect(line.autoRomanized, isFalse);
    }
  });

  test('词典失败时回退假名转写', () async {
    final lyric = _lyric(['あいう']);
    debugOverrideRomanizer(
      romanize: (texts, includeKanjiOnly) async {
        throw StateError('dictionary unavailable');
      },
    );

    await applyDictionaryRomanization(lyric);

    final line = lyric.lines.single as SyncLyricLine;
    expect(line.romanLyric, 'aiu');
    expect(line.autoRomanized, isTrue);
  });

  test('日语歌中的纯汉字行也交给词典', () async {
    final lyric = _lyric(['きみのなまえ', '東京']);
    List<String>? received;
    var receivedIncludeKanjiOnly = false;
    debugOverrideRomanizer(
      romanize: (texts, includeKanjiOnly) async {
        received = List<String>.from(texts);
        receivedIncludeKanjiOnly = includeKanjiOnly;
        return const ['kimi no namae', 'toukyou'];
      },
    );

    await applyDictionaryRomanization(lyric);

    expect(receivedIncludeKanjiOnly, isTrue);
    expect(received, ['きみのなまえ', '東京']);
    final lines = lyric.lines.cast<SyncLyricLine>().toList();
    expect(lines[0].romanLyric, 'kimi no namae');
    expect(lines[1].romanLyric, 'toukyou');
  });

  test('元数据行与已有罗马音的行不改写', () async {
    final metadata = _line(0, 'きみのなまえ')..isMetadata = true;
    final lyric = Lyric([
      metadata,
      _line(1, 'そらのいろ', romanLyric: '手写罗马音'),
      _line(2, 'とおいゆめ'),
    ]);
    var calls = 0;
    debugOverrideRomanizer(
      romanize: (texts, includeKanjiOnly) async {
        calls++;
        expect(texts, ['とおいゆめ']);
        return const ['tooi yume'];
      },
    );

    await applyDictionaryRomanization(lyric);

    expect(calls, 1);
    expect(metadata.romanLyric, isNull);
    final lines = lyric.lines.cast<SyncLyricLine>().toList();
    expect(lines[1].romanLyric, '手写罗马音');
    expect(lines[2].romanLyric, 'tooi yume');
  });

  test('来源切换后新歌词重新生成罗马音', () async {
    var calls = 0;
    debugOverrideRomanizer(
      romanize: (texts, includeKanjiOnly) async {
        calls++;
        return [for (final _ in texts) 'kimi'];
      },
    );

    final first = _lyric(['きみ']);
    await applyLyricRomanization(first, enabled: true);
    expect((first.lines.single as SyncLyricLine).romanLyric, 'kimi');

    // 模拟 useSpecificLyric 等入口传入另一份歌词对象。
    final second = _lyric(['そら']);
    await applyLyricRomanization(second, enabled: true);
    expect((second.lines.single as SyncLyricLine).romanLyric, 'kimi');
    expect(calls, 2);
  });

  test('自动罗马音开关关闭时不调用词典', () async {
    var calls = 0;
    debugOverrideRomanizer(
      romanize: (texts, includeKanjiOnly) async {
        calls++;
        return const <String>[];
      },
    );

    final lyric = _lyric(['きみ']);
    await applyLyricRomanization(lyric, enabled: false);

    expect(calls, 0);
    expect((lyric.lines.single as SyncLyricLine).romanLyric, isNull);
  });
}
