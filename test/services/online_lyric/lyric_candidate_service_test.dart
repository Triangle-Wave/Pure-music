import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/services/online_lyric/lyric_candidate_service.dart';
import 'package:pure_music/services/online_lyric/models/lyric_candidate.dart';

Audio _audio() {
  return Audio(
    'Song',
    'Artist',
    'Album',
    null,
    1,
    200,
    null,
    null,
    r'C:\Music\test.mp3',
    0,
    0,
    null,
  );
}

LyricCandidate _candidate({
  String? text,
  String? translationText,
  String? romanizationText,
}) {
  return LyricCandidate(
    id: 'qq:1',
    source: 'qq',
    sourceId: '1',
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    durationSec: 200,
    score: 90,
    format: 'lrc',
    wordByWord: false,
    text: text ?? '[00:00.000]first line\n[00:03.200]second line',
    translationText: translationText,
    romanizationText: romanizationText,
    preview: const ['first line', 'second line'],
    fetchedAtMs: 1,
  );
}

void main() {
  test('LRC 候选文本可离线重建歌词', () {
    final lyric = parseLyricCandidateText(
      '[00:00.00]first line\n[00:03.20]second line\n[00:06.40]third line',
      'lrc',
    );

    expect(lyric, isNotNull);
    expect(lyric!.lines.length, greaterThanOrEqualTo(3));
  });

  test('格式标识不可靠时仍按 LRC 兜底解析', () {
    final lyric = parseLyricCandidateText(
      '[00:01.00]line one\n[00:02.00]line two',
      'qrc',
    );

    expect(lyric, isNotNull);
    expect(lyric!.isNotEmpty, isTrue);
  });

  test('空文本返回 null', () {
    expect(parseLyricCandidateText('', 'lrc'), isNull);
    expect(parseLyricCandidateText('   ', 'lrc'), isNull);
  });

  test('候选提取每行翻译与罗马音并跳过本地转写', () {
    final lyric = Lrc(
      [
        LrcLine(Duration.zero, 'line one', requiredIsBlank: false)
          ..translation = '译文一'
          ..romanLyric = 'romaji one',
        LrcLine(const Duration(seconds: 3), 'line two', requiredIsBlank: false)
          ..romanLyric = 'local romanization'
          ..autoRomanized = true,
      ],
      LyricFormat.local,
      '[00:00.000]line one',
    );

    final supplemental = lyricCandidateSupplementalText(lyric);

    expect(supplemental.translationText, '[00:00.000]译文一');
    expect(supplemental.romanizationText, '[00:00.000]romaji one');
  });

  test('候选重建后按时间戳补回翻译与罗马音', () async {
    final lyric = await loadLyricFromCandidate(
      _candidate(
        translationText: '[00:00.000]第一行翻译\n[00:03.200]第二行翻译',
        romanizationText: '[00:00.120]romaji one\n[00:03.320]romaji two',
      ),
      _audio(),
      loader: (_) async => null,
    );

    expect(lyric, isNotNull);
    final first = lyric!.lines.firstWhere(
      (line) => line.start == Duration.zero,
    );
    final second = lyric.lines.firstWhere(
      (line) => line.start == const Duration(milliseconds: 3200),
    );

    expect(first.translation, '第一行翻译');
    expect(first.romanLyric, 'romaji one');
    expect(second.translation, '第二行翻译');
    expect(second.romanLyric, 'romaji two');
    expect(second.romanWords, isNotNull);
    expect(
      second.romanWords!.map((word) => word.content).join(' '),
      'romaji two',
    );
  });

  test('已有翻译与罗马音不被候选补充文本覆盖', () {
    final lyric = Lrc(
      [
        LrcLine(Duration.zero, 'line one', requiredIsBlank: false)
          ..translation = '原有翻译'
          ..romanLyric = '原有罗马音',
      ],
      LyricFormat.local,
    );

    applyLyricCandidateSupplemental(
      lyric,
      translationText: '[00:00.000]候选翻译',
      romanizationText: '[00:00.000]candidate romaji',
    );

    final line = lyric.lines.first;
    expect(line.translation, '原有翻译');
    expect(line.romanLyric, '原有罗马音');
  });

  test('已有翻译不被候选补充文本覆盖', () async {
    final lyric = await loadLyricFromCandidate(
      _candidate(
        text:
            '[00:00.000]first line\n'
            '[00:00.000]原有翻译\n'
            '[00:03.200]second line',
        translationText: '[00:00.000]候选翻译\n[00:03.200]第二行翻译',
        romanizationText: '[00:03.200]romaji two',
      ),
      _audio(),
      loader: (_) async => null,
    );

    expect(lyric, isNotNull);
    final first = lyric!.lines.firstWhere(
      (line) => line.start == Duration.zero,
    );
    final second = lyric.lines.firstWhere(
      (line) => line.start == const Duration(milliseconds: 3200),
    );

    expect(first.translation, '原有翻译');
    expect(second.translation, '第二行翻译');
    expect(second.romanLyric, 'romaji two');
  });
}
