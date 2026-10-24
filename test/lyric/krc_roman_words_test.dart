import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/krc.dart';
import 'package:pure_music/lyric/lyric.dart';

String _krcWithRoma(List<List<String>> romaLines) {
  final language = base64Encode(
    utf8.encode(
      jsonEncode({
        'content': [
          {'type': 0, 'lyricContent': romaLines},
        ],
      }),
    ),
  );
  return '[language:$language]\n'
      '[1000,1000]<0,500,0>君<500,500,0>の';
}

void main() {
  test('roma 数组与主词数量一致时继承逐词时间', () {
    final lyric = Krc.fromKrcText(
      _krcWithRoma([
        ['ki', 'mi'],
      ]),
    );

    final line = lyric.lines.single as SyncLyricLine;
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

  test('roma 数量与主词不等时按字符权重分配行内时间', () {
    final lyric = Krc.fromKrcText(
      _krcWithRoma([
        ['ki', 'mi', 'no'],
      ]),
    );

    final line = lyric.lines.single as SyncLyricLine;
    expect(line.romanWords, isNotNull);
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
}
