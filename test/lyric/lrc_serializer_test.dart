import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/japanese_romanizer.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lrc_serializer.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_tag_word_format.dart';

void main() {
  group('serializeLyricToLrc', () {
    test('line lyrics always use standard LRC', () {
      final lyric = Lyric([
        LrcLine(
          const Duration(milliseconds: 1234),
          '逐行歌词',
          requiredIsBlank: false,
        ),
      ]);

      final text = serializeLyricToLrc(
        lyric,
        wordFormat: LyricTagWordFormat.enhanced,
      );

      expect(text, '[00:01.234]逐行歌词');
    });

    test('sync lyrics can use word-by-word LRC', () {
      final lyric = _syncLyric();

      final text = serializeLyricToLrc(
        lyric,
        wordFormat: LyricTagWordFormat.wordByWord,
      );

      expect(
        text,
        '[00:01.100]怕[00:01.456]你\n'
        '[00:01.100]害怕你\n'
        '[00:01.100]pa ni',
      );
    });

    test('sync lyrics can use enhanced LRC', () {
      final lyric = _syncLyric();

      final text = serializeLyricToLrc(
        lyric,
        wordFormat: LyricTagWordFormat.enhanced,
      );

      expect(
        text,
        '[00:01.000]<00:01.100>怕<00:01.456>你\n'
        '[00:01.000]害怕你\n'
        '[00:01.000]pa ni',
      );
    });

    test('provider payload is converted while valid LRC metadata is kept', () {
      final source = _syncLyric(
        rawText: '[ar:Artist]\n[ti:Title]\n<tt>provider payload</tt>',
      );

      final text = serializeLyricToLrc(
        source,
        wordFormat: LyricTagWordFormat.enhanced,
      );

      expect(text, isNot(contains('<tt>')));
      expect(text, startsWith('[ar:Artist]\n[ti:Title]\n'));
      expect(text, contains('[00:01.000]<00:01.100>怕'));
    });

    test('locally generated romanization stays out of the written LRC', () {
      final lyric = Lyric([
        SyncLyricLine(
          const Duration(seconds: 1),
          const Duration(seconds: 2),
          [
            SyncLyricWord(
              const Duration(seconds: 1),
              const Duration(seconds: 2),
              'ありがとう',
            ),
          ],
        ),
      ]);

      applyAutoRomanization(lyric);
      expect((lyric.lines.first as SyncLyricLine).romanLyric, 'arigatou');

      final text = serializeLyricToLrc(
        lyric,
        wordFormat: LyricTagWordFormat.standard,
      );

      expect(text, contains('ありがとう'));
      expect(text, isNot(contains('arigatou')));
    });

    test('keepMetadata decides whether metadata rows are written', () {
      final lyric = Lyric([
        LrcLine(
          const Duration(seconds: 1),
          '作词：Someone',
          requiredIsBlank: false,
        )..isMetadata = true,
        LrcLine(
          const Duration(seconds: 5),
          '歌词一行',
          requiredIsBlank: false,
        ),
      ]);

      final kept = serializeLyricToLrc(
        lyric,
        wordFormat: LyricTagWordFormat.standard,
        keepMetadata: true,
      );
      expect(kept, contains('[00:01.000]作词：Someone'));
      expect(kept, contains('[00:05.000]歌词一行'));

      final dropped = serializeLyricToLrc(
        lyric,
        wordFormat: LyricTagWordFormat.standard,
        keepMetadata: false,
      );
      expect(dropped, isNot(contains('作词：Someone')));
      expect(dropped, contains('[00:05.000]歌词一行'));
    });

    for (final format in LyricTagWordFormat.values) {
      test('${format.name} keeps grouping through an LRC round trip', () {
        final text = serializeLyricToLrc(_syncLyric(), wordFormat: format);

        final parsed = Lrc.fromLrcTextAuto(
          text,
          LyricFormat.local,
          separator: '┃',
        );
        final contentLines = parsed!.lines.where((line) {
          if (line is LrcLine) {
            return !line.isMetadata && line.content.trim().isNotEmpty;
          }
          return line is SyncLyricLine && line.content.trim().isNotEmpty;
        }).toList();

        expect(contentLines, hasLength(1));
        final contentLine = contentLines.single;
        expect(
          contentLine is LrcLine
              ? contentLine.content
              : (contentLine as SyncLyricLine).content,
          '怕你',
        );
        expect(contentLine.translation, '害怕你');
        expect(contentLine.romanLyric, 'pa ni');
      });
    }
  });
}

Lyric _syncLyric({String? rawText}) {
  return Lyric(
    [
      SyncLyricLine(
        const Duration(seconds: 1),
        const Duration(seconds: 1),
        [
          SyncLyricWord(
            const Duration(milliseconds: 1100),
            const Duration(milliseconds: 356),
            '怕',
          ),
          SyncLyricWord(
            const Duration(milliseconds: 1456),
            const Duration(milliseconds: 544),
            '你',
          ),
        ],
        '害怕你',
        'pa ni',
      ),
    ],
    LyricFormat.web,
    rawText,
  );
}
