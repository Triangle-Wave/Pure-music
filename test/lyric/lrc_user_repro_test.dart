import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';

void main() {
  test('keeps aligned romaji and translation on the Japanese source line', () {
    const source = '''
[00:34.71]<00:35.22>a na ta ga fu re ru hi ka ri ma su ne tsu yu bi sa ki ni o do ra sa re<00:40.87>
[00:34.71]<00:34.71>あ<00:34.86>な<00:35.11>た<00:35.31>が<00:35.48>触<00:35.64>（<00:35.64>ふ<00:35.64>）<00:35.64>れ<00:36.01>る <00:36.29>光<00:37.03>（<00:37.03>ひ<00:37.03>か<00:37.03>り<00:37.03>） <00:37.03>増<00:37.31>（<00:37.31>ま<00:37.31>）<00:37.31>す<00:37.38>熱<00:37.90>（<00:37.90>ね<00:37.90>つ<00:37.90>） <00:37.90>指<00:38.32>先<00:39.29>（<00:39.29>ゆ<00:39.29>び<00:39.29>さ<00:39.30>き<00:39.32>）<00:39.34>に<00:39.69>踊<00:40.33>（<00:40.33>お<00:40.33>ど<00:40.33>）<00:40.33>ら<00:40.64>さ<00:40.91>れ<00:41.35>
[00:34.71]<00:35.22>【你所触碰到的 光芒 升温的热度 于指尖舞蹈】<00:40.87>
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<SyncLyricLine>().singleWhere(
      (line) => line.words.isNotEmpty,
    );

    expect(
      line.romanLyric,
      'a na ta ga fu re ru hi ka ri ma su ne tsu yu bi sa ki ni o do ra sa re',
    );
    expect(line.translation, '【你所触碰到的 光芒 升温的热度 于指尖舞蹈】');
  });
}
