import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';

void main() {
  group('CUE 段范围规范化', () {
    test('普通曲目保持 0/0', () {
      expect(
        BassPlayer.normalizePlaybackSegment(0, 0),
        (startMs: 0, endMs: 0),
      );
    });

    test('负起点夹到 0', () {
      expect(
        BassPlayer.normalizePlaybackSegment(-500, 1500),
        (startMs: 0, endMs: 1500),
      );
    });

    test('终点不晚于起点时视为到文件尾', () {
      expect(
        BassPlayer.normalizePlaybackSegment(1000, 1000),
        (startMs: 1000, endMs: 0),
      );
      expect(
        BassPlayer.normalizePlaybackSegment(2000, 1000),
        (startMs: 2000, endMs: 0),
      );
    });
  });

  group('CUE 段时长', () {
    test('按毫秒差换算秒', () {
      expect(
        BassPlayer.segmentDurationSeconds(startMs: 1000, endMs: 201000),
        200.0,
      );
    });

    test('终点为 0 表示到文件尾，不产生段时长', () {
      expect(
        BassPlayer.segmentDurationSeconds(startMs: 1000, endMs: 0),
        0.0,
      );
    });

    test('负起点按 0 计算', () {
      expect(
        BassPlayer.segmentDurationSeconds(startMs: -1000, endMs: 5000),
        5.0,
      );
    });
  });

  group('CUE 段内 seek', () {
    test('相对位置加上段起点', () {
      expect(
        BassPlayer.segmentAbsoluteSeconds(
          position: 30.0,
          startMs: 10000,
          endMs: 200000,
        ),
        40.0,
      );
    });

    test('夹在段起止之间', () {
      expect(
        BassPlayer.segmentAbsoluteSeconds(
          position: -5.0,
          startMs: 10000,
          endMs: 200000,
        ),
        10.0,
      );
      expect(
        BassPlayer.segmentAbsoluteSeconds(
          position: 500.0,
          startMs: 10000,
          endMs: 200000,
        ),
        200.0,
      );
    });

    test('没有段尾时只加起点', () {
      expect(
        BassPlayer.segmentAbsoluteSeconds(
          position: 500.0,
          startMs: 10000,
          endMs: 0,
        ),
        510.0,
      );
    });
  });

  group('Audio 段字段', () {
    test('合成路径暴露真实源文件和段范围', () {
      final audio = Audio(
        'Track 02',
        'Artist',
        'Album',
        null,
        2,
        200,
        1000,
        44100,
        r'D:\Music\Album\disc.flac::track=02::start=1000::end=201000',
        1,
        1,
        null,
      );

      expect(audio.isCueTrack, isTrue);
      expect(audio.filePath, r'D:\Music\Album\disc.flac');
      expect(audio.segmentStartMs, 1000);
      expect(audio.segmentEndMs, 201000);
    });

    test('普通文件路径不产生段', () {
      final audio = Audio(
        'Song',
        'Artist',
        'Album',
        null,
        1,
        180,
        320,
        44100,
        r'D:\Music\song.flac',
        1,
        1,
        null,
      );

      expect(audio.isCueTrack, isFalse);
      expect(audio.filePath, r'D:\Music\song.flac');
      expect(audio.segmentStartMs, 0);
      expect(audio.segmentEndMs, 0);
    });

    test('SACD 合成路径暴露 ISO 与段范围', () {
      final audio = Audio(
        'Track 01',
        'UNKNOWN',
        'album',
        null,
        1,
        90,
        null,
        null,
        r'D:\Music\SACD\album.iso::track=01::start=0::end=90333::sacd=2ch',
        1,
        1,
        'sacd',
      );

      expect(audio.isVirtualTrack, isTrue);
      expect(audio.isCueTrack, isFalse);
      expect(audio.isSacdTrack, isTrue);
      expect(audio.filePath, r'D:\Music\SACD\album.iso');
      expect(audio.segmentStartMs, 0);
      expect(audio.segmentEndMs, 90333);
    });
  });
}
