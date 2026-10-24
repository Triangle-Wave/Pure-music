import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/ttml.dart';

void main() {
  test('transliteration span 时间写入 romanWords', () {
    final lyric = Ttml.fromTtmlText('''
<tt xmlns="http://www.w3.org/ns/ttml">
  <head>
    <transliteration>
      <text for="L1">
        <span begin="00:01.000" end="00:01.500">ki</span>
        <span begin="00:01.500" end="00:02.000">mi</span>
      </text>
    </transliteration>
  </head>
  <body>
    <div>
      <p begin="00:01.000" end="00:03.000" key="L1">
        <span begin="00:01.000" end="00:02.000">君</span>
      </p>
    </div>
  </body>
</tt>
''');

    expect(lyric, isNotNull);
    final line = lyric!.lines.single as SyncLyricLine;
    expect(line.romanLyric, 'kimi');
    expect(line.romanWords, isNotNull);
    expect(line.romanWords, hasLength(2));
    expect(line.romanWords![0].content, 'ki');
    expect(line.romanWords![0].start, const Duration(seconds: 1));
    expect(line.romanWords![0].length, const Duration(milliseconds: 500));
    expect(line.romanWords![1].content, 'mi');
    expect(line.romanWords![1].start, const Duration(milliseconds: 1500));
    expect(line.romanWords![1].length, const Duration(milliseconds: 500));
  });

  test('x-roman 内部 span 时间写入 romanWords', () {
    final lyric = Ttml.fromTtmlText('''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
  <body>
    <div>
      <p begin="00:01.000" end="00:03.000">
        <span begin="00:01.000" end="00:02.000">君</span>
        <span ttm:role="x-roman">
          <span begin="00:01.000" end="00:01.500">ki</span>
          <span begin="00:01.500" end="00:02.000">mi</span>
        </span>
      </p>
    </div>
  </body>
</tt>
''');

    expect(lyric, isNotNull);
    final line = lyric!.lines.single as SyncLyricLine;
    expect(line.romanLyric, 'kimi');
    expect(line.romanWords, isNotNull);
    expect(line.romanWords, hasLength(2));
    expect(line.romanWords![0].start, const Duration(seconds: 1));
    expect(line.romanWords![0].length, const Duration(milliseconds: 500));
    expect(line.romanWords![1].start, const Duration(milliseconds: 1500));
  });

  test('x-roman 无时间时回退为 null', () {
    final lyric = Ttml.fromTtmlText('''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
  <body>
    <div>
      <p begin="00:01.000" end="00:03.000">
        <span begin="00:01.000" end="00:02.000">君</span>
        <span ttm:role="x-roman">kimi</span>
      </p>
    </div>
  </body>
</tt>
''');

    expect(lyric, isNotNull);
    final line = lyric!.lines.single as SyncLyricLine;
    expect(line.romanLyric, 'kimi');
    expect(line.romanWords, isNull);
  });
}
