import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/hi_res_badge.dart';
import 'package:pure_music/library/audio_library.dart';

Audio _audio({
  String path = r'D:\Music\Album\track.flac',
  String? by,
  int? sampleRate = 44100,
}) => Audio(
  'Track',
  'Artist',
  'Album',
  null,
  1,
  100,
  320,
  sampleRate,
  path,
  1,
  1,
  by,
);

void main() {
  group('isDsdAudio', () {
    test('.dsf 路径为 DSD', () {
      expect(isDsdAudio(_audio(path: r'D:\Music\Album\track.dsf')), isTrue);
    });

    test('.dff 路径为 DSD', () {
      expect(isDsdAudio(_audio(path: r'D:\Music\Album\track.dff')), isTrue);
    });

    test('大写扩展名同样为 DSD', () {
      expect(isDsdAudio(_audio(path: r'D:\Music\Album\TRACK.DSF')), isTrue);
    });

    test('CUE 分轨路径按 :: 前的源文件后缀判定', () {
      const path = r'D:\Music\Album\disc.dsf::track=02::start=1000::end=2000';
      expect(isDsdAudio(_audio(path: path)), isTrue);
    });

    test('SACD 虚拟轨为 DSD', () {
      const path =
          r'D:\Music\Album\album.iso::track=01::start=0::end=2000::sacd=2ch';
      expect(isDsdAudio(_audio(path: path, sampleRate: 44100)), isTrue);
    });

    test('标签来源 by=DFF 为 DSD', () {
      expect(isDsdAudio(_audio(by: 'DFF')), isTrue);
    });

    test('标签来源 by 大小写不敏感', () {
      expect(isDsdAudio(_audio(by: 'dsf')), isTrue);
      expect(isDsdAudio(_audio(by: 'SACD')), isTrue);
    });

    test('采样率 2822400 为 DSD', () {
      expect(isDsdAudio(_audio(sampleRate: 2822400)), isTrue);
    });

    test('44.1k FLAC 不是 DSD', () {
      expect(
        isDsdAudio(_audio(path: r'D:\Music\Album\track.flac', by: 'flac')),
        isFalse,
      );
    });

    test('96k PCM 不是 DSD', () {
      expect(
        isDsdAudio(
          _audio(
            path: r'D:\Music\Album\track.flac',
            by: 'flac',
            sampleRate: 96000,
          ),
        ),
        isFalse,
      );
    });

    test('扩展名仅在路径结尾生效', () {
      expect(
        isDsdAudio(_audio(path: r'D:\Music\Album\track.dsf.flac')),
        isFalse,
      );
    });

    test('352.8k PCM 不是 DSD', () {
      expect(
        isDsdAudio(
          _audio(
            path: r'D:\Music\Album\track.flac',
            by: 'flac',
            sampleRate: 352800,
          ),
        ),
        isFalse,
      );
    });
  });
}
