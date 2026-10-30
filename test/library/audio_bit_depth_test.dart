import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';

Audio _fromBitDepth(Object? bitDepth) => Audio.fromMap({
  'title': 'Track',
  'artist': 'Artist',
  'album': 'Album',
  'album_artist': null,
  'track': 1,
  'disc': null,
  'duration': 100,
  'bitrate': 320,
  'sample_rate': 44100,
  'bit_depth': bitDepth,
  'path': r'D:\Music\Album\track.flac',
  'modified': 1,
  'created': 1,
  'by': 'flac',
  'play_count': 0,
});

void main() {
  group('Audio 位深序列化', () {
    test('fromMap 解析整数位深', () {
      expect(_fromBitDepth(24).bitDepth, 24);
    });

    test('fromMap 解析字符串位深', () {
      expect(_fromBitDepth('24').bitDepth, 24);
    });

    test('fromMap 解析 num 位深', () {
      expect(_fromBitDepth(24.0).bitDepth, 24);
    });

    test('fromMap 的 null 位深保持 null', () {
      expect(_fromBitDepth(null).bitDepth, isNull);
    });

    test('fromMap 的非法位深转为 null', () {
      expect(_fromBitDepth('deep').bitDepth, isNull);
    });

    test('toMap 写入 bit_depth 并可往返', () {
      final audio = _fromBitDepth(24);
      expect(audio.toMap()['bit_depth'], 24);
      expect(Audio.fromMap(audio.toMap()).bitDepth, 24);
      expect(Audio.fromMap(_fromBitDepth(null).toMap()).bitDepth, isNull);
    });
  });
}
