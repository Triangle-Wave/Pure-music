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

String _languageFrame(List<Map<String, dynamic>> content) {
  final language = base64Encode(utf8.encode(jsonEncode({'content': content})));
  return '[language:$language]\n';
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

  test('type 缺失时按内容识别罗马音与翻译，跳过空行', () {
    final lyric = Krc.fromKrcText(
      '${_languageFrame([
        {
          'lyricContent': [
            ['bu ru', 'su ka i'],
            ['ki', 'mi', 'no'],
          ],
        },
        {
          'lyricContent': [
            [''],
            ['你的'],
          ],
        },
      ])}'
      '[0,1000]<0,500,0>Blue <500,500,0>sky\n'
      '[1000,1000]<0,500,0>君<500,500,0>の',
    );

    final lines = lyric.lines.cast<SyncLyricLine>();
    expect(lines, hasLength(2));
    expect(lines[0].romanLyric, 'burusukai');
    expect(lines[0].romanWords, isNotNull);
    expect(lines[0].translation, isNull);
    expect(lines[1].romanLyric, 'kimino');
    expect(lines[1].romanWords, hasLength(3));
    expect(lines[1].translation, '你的');
  });

  test('type 缺失且条目顺序颠倒时仍按内容识别', () {
    final lyric = Krc.fromKrcText(
      '${_languageFrame([
        {
          'lyricContent': [
            ['你的'],
          ],
        },
        {
          'lyricContent': [
            ['ki', 'mi'],
          ],
        },
      ])}'
      '[1000,1000]<0,500,0>君<500,500,0>の',
    );

    final line = lyric.lines.single as SyncLyricLine;
    expect(line.translation, '你的');
    expect(line.romanLyric, 'kimi');
    expect(line.romanWords, hasLength(2));
  });

  test('有 type 时按 0 注音 1 翻译，不受条目顺序影响', () {
    final lyric = Krc.fromKrcText(
      '${_languageFrame([
        {
          'type': 1,
          'lyricContent': [
            ['你的'],
          ],
        },
        {
          'type': 0,
          'lyricContent': [
            ['ki', 'mi'],
          ],
        },
      ])}'
      '[1000,1000]<0,500,0>君<500,500,0>の',
    );

    final line = lyric.lines.single as SyncLyricLine;
    expect(line.translation, '你的');
    expect(line.romanLyric, 'kimi');
  });

  test('language 行按主歌词序号对齐，空行不影响后续关联', () {
    final lyric = Krc.fromKrcText(
      '${_languageFrame([
        {
          'type': 0,
          'lyricContent': [
            ['ki', 'mi'],
            <String>[],
            ['sa', 'n'],
          ],
        },
        {
          'type': 1,
          'lyricContent': [
            ['你的'],
            [''],
            ['三'],
          ],
        },
      ])}'
      '[1000,1000]<0,500,0>君<500,500,0>の\n'
      '[2000,1000]\n'
      '[3000,1000]<0,500,0>三<500,500,0>度',
    );

    final lines = lyric.lines.cast<SyncLyricLine>();
    expect(lines, hasLength(3));
    expect(lines[0].romanLyric, 'kimi');
    expect(lines[0].translation, '你的');
    expect(lines[1].words, isEmpty);
    expect(lines[1].romanLyric, isNull);
    expect(lines[2].romanLyric, 'san');
    expect(lines[2].translation, '三');
  });
}
