import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/online_lyric/lyric_candidate_service.dart';

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
}
