import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';

void main() {
  test('enhanced LRC preserves text before the first word timestamp', () {
    final lyric = Lrc.fromLrcTextAuto(
      '[00:00.000]打<00:00.330>歌<00:00.660>妹<00:00.990>（DJ）'
      '<00:01.320>-<00:01.980>林',
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<SyncLyricLine>().singleWhere(
      (line) => line.words.isNotEmpty,
    );

    expect(line.words.map((word) => word.content).join(), '打歌妹（DJ）-林');
    expect(line.words.first.start, Duration.zero);
    expect(line.words.first.length, const Duration(milliseconds: 330));
  });

  test('enhanced LRC keeps an explicit single-word end timestamp', () {
    final lyric = Lrc.fromLrcTextAuto(
      '[00:31.519] <00:31.519>Check<00:31.830>\n'
      '[00:31.519]听好了\n'
      '[00:32.163] <00:32.163>You <00:32.316>can<00:32.508>',
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<SyncLyricLine>().firstWhere(
      (line) => line.content.trim() == 'Check',
    );

    expect(line.words, hasLength(1));
    expect(line.words.single.length, const Duration(milliseconds: 311));
  });

  test('enhanced LRC keeps a delayed first word as the original line', () {
    final lyric = Lrc.fromLrcTextAuto(
      '[01:09.916]Constantly<01:11.488>\n'
      '[01:09.916]重复不断\n'
      '[01:11.488]Boy <01:11.686>you <01:11.878>play '
      '<01:12.370>through <01:12.609>my <01:12.842>mind '
      '<01:15.537>\n'
      '[01:11.488]男孩 你像一首交响曲一样萦绕在我的脑海里',
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<SyncLyricLine>().singleWhere(
      (line) =>
          line.start == const Duration(milliseconds: 69916) &&
          line.words.isNotEmpty,
    );

    expect(line.content, 'Constantly');
    expect(line.translation, '重复不断');
    expect(line.romanLyric, isNull);
  });

  test('enhanced LRC learns roles when supplemental lines are also timed', () {
    final lyric = Lrc.fromLrcTextAuto(
      '[00:10.000]Hello<00:10.500>\n'
      '[00:10.000]你好\n'
      '[00:20.000]World<00:20.500>\n'
      '[00:20.000]再<00:20.200>见<00:20.500>\n'
      '[00:30.000]歌詞<00:30.500>\n'
      '[00:30.000]翻<00:30.150>译<00:30.300>文本<00:30.500>\n'
      '[00:30.000]ka<00:30.150>na<00:30.500>',
      LyricFormat.local,
      separator: '┃',
    )!;
    final lines = lyric.lines
        .whereType<SyncLyricLine>()
        .where((line) => line.words.isNotEmpty)
        .toList();

    expect(lines, hasLength(3));
    expect(lines[1].content, 'World');
    expect(lines[1].translation, '再见');
    expect(lines[1].romanLyric, isNull);
    expect(lines[2].content, '歌詞');
    expect(lines[2].translation, '翻译文本');
    expect(lines[2].romanLyric, 'kana');
  });

  test('enhanced LRC uses the first meaningful word for the opening interlude', () {
    final lyric = Lrc.fromLrcTextAuto(
      '[00:00.000] <00:00.000> <00:21.320>ぜ<00:21.550>ん<00:21.720>ぶ<00:22.200>\n'
      '[00:23.930] <00:23.930>こ<00:24.150>の<00:24.280>気<00:24.470>ま<00:24.800>ず<00:25.000>',
      LyricFormat.local,
      separator: '┃',
      keepMetadata: false,
    )!;

    final intro = lyric.lines.whereType<SyncLyricLine>().first;
    expect(intro.words, isEmpty);
    expect(intro.start, Duration.zero);
    expect(intro.length, const Duration(milliseconds: 21320));

    final firstLyric = lyric.lines.whereType<SyncLyricLine>().firstWhere(
      (line) => line.words.isNotEmpty,
    );
    expect(firstLyric.words.first.content, 'ぜ');
    expect(firstLyric.words.first.start, const Duration(milliseconds: 21320));
  });

  test('enhanced LRC does not duplicate the intro around kept metadata', () {
    final lyric = Lrc.fromLrcTextAuto(
      '[00:00.000]<00:00.000>作<00:00.510>词<00:01.020>：<00:01.520>GunkeyP<00:02.030>\n'
      '[00:06.100]<00:06.100>作<00:06.600>曲<00:07.110>：<00:07.620>GunkeyP<00:08.130>\n'
      '[00:12.190]<00:12.190>编<00:12.700>曲<00:13.210>：<00:13.720>GunkeyP<00:14.230>\n'
      '[00:21.850]<00:21.850>不<00:22.190>经<00:22.670>意<00:22.910>被<00:23.250>钟<00:23.560>提<00:23.900>醒<00:24.720>未<00:25.060>读<00:25.380>的<00:25.660>讯<00:26.030>息<00:26.530>',
      LyricFormat.local,
      separator: '┃',
      keepMetadata: true,
    )!;

    final lines = lyric.lines.whereType<SyncLyricLine>().toList();
    final blankLines = lines.where((line) => line.words.isEmpty).toList();

    expect(lines.first.words.single.content, contains('作词'));
    expect(blankLines, isEmpty);
    expect(lines.map((line) => line.start).toList(), [
      Duration.zero,
      const Duration(milliseconds: 6100),
      const Duration(milliseconds: 12190),
      const Duration(milliseconds: 21850),
    ]);
  });

  test(
    'enhanced LRC keeps adjacent original and translation groups separate',
    () {
      final lyric = Lrc.fromLrcTextAuto(
        '[01:04.190] <01:04.190>oh<01:04.220>\n'
        '[01:04.190]我清楚我不能征服你\n'
        '[01:04.220] <01:04.220>know <01:04.524>that <01:04.828>i '
        '<01:05.132>can\'t <01:05.436>get <01:05.740>over '
        '<01:06.044>you<01:06.350>\n'
        '[01:04.220]因为我眼中只有你',
        LyricFormat.local,
        separator: '┃',
      )!;
      final lines = lyric.lines
          .whereType<SyncLyricLine>()
          .where((line) => line.words.isNotEmpty)
          .toList();

      expect(lines, hasLength(2));
      expect(lines[0].content.trim(), 'oh');
      expect(lines[0].translation, '我清楚我不能征服你');
      expect(lines[0].bg, isNull);
      expect(lines[1].content.trim(), "know that i can't get over you");
      expect(lines[1].translation, '因为我眼中只有你');
      expect(lines[1].bg, isNull);
    },
  );

  test('enhanced LRC still groups a slightly offset translation', () {
    final lyric = Lrc.fromLrcTextAuto(
      '[00:10.000] <00:10.000>hello<00:10.500>\n'
      '[00:10.020]你好',
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<SyncLyricLine>().singleWhere(
      (line) => line.words.isNotEmpty,
    );

    expect(line.content, 'hello');
    expect(line.translation, '你好');
  });

  test('enhanced LRC still groups an aligned timed translation', () {
    final lyric = Lrc.fromLrcTextAuto(
      '[00:10.000] <00:10.000>hello <00:10.500>world<00:11.000>\n'
      '[00:10.020] <00:10.020>你<00:10.500>好<00:11.020>',
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<SyncLyricLine>().singleWhere(
      (line) => line.words.isNotEmpty,
    );

    expect(line.content, 'hello world');
    expect(line.translation, '你好');
  });
}
