import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/badge_raster_cache.dart';
import 'package:pure_music/component/hi_res_badge.dart';
import 'package:pure_music/library/audio_library.dart';

Audio _audio({
  String path = r'D:\Music\Album\track.flac',
  int? sampleRate,
  int? bitDepth,
  String? by,
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
  bitDepth: bitDepth,
);

void main() {
  group('isHiResAudio', () {
    test('44.1k 16bit 不是 Hi-Res', () {
      expect(isHiResAudio(_audio(sampleRate: 44100, bitDepth: 16)), isFalse);
    });

    test('44.1k 24bit 是 Hi-Res', () {
      expect(isHiResAudio(_audio(sampleRate: 44100, bitDepth: 24)), isTrue);
    });

    test('44.1k 无位深不是 Hi-Res', () {
      expect(isHiResAudio(_audio(sampleRate: 44100)), isFalse);
    });

    test('48k 16bit 是 Hi-Res', () {
      expect(isHiResAudio(_audio(sampleRate: 48000, bitDepth: 16)), isTrue);
    });

    test('96k 24bit 是 Hi-Res', () {
      expect(isHiResAudio(_audio(sampleRate: 96000, bitDepth: 24)), isTrue);
    });

    test('无采样率不是 Hi-Res', () {
      expect(isHiResAudio(_audio(bitDepth: 24)), isFalse);
    });

    test('DSD 2822400 同时为 Hi-Res 与 DSD', () {
      final audio = _audio(sampleRate: 2822400, bitDepth: 1);
      expect(isHiResAudio(audio), isTrue);
      expect(isDsdAudio(audio), isTrue);
    });

    test('SACD 虚拟轨无采样率时仍为 Hi-Res', () {
      const path =
          r'D:\Music\SACD\album.iso::track=01::start=0::end=2000::sacd=2ch';
      final audio = _audio(path: path);
      expect(audio.isSacdTrack, isTrue);
      expect(audio.sampleRate, isNull);
      expect(isHiResAudio(audio), isTrue);
    });

    test('44.1k 23bit 不是 Hi-Res', () {
      expect(isHiResAudio(_audio(sampleRate: 44100, bitDepth: 23)), isFalse);
    });
  });

  group('badgeRasterPixelSize', () {
    test('方形徽标按显示尺寸乘 dpr 向上取整', () {
      expect(
        badgeRasterPixelSize(logicalSize: 20, devicePixelRatio: 1.0),
        equals(const BadgeRasterSize(width: 20, height: 20)),
      );
      expect(
        badgeRasterPixelSize(logicalSize: 20, devicePixelRatio: 1.5),
        equals(const BadgeRasterSize(width: 30, height: 30)),
      );
      expect(
        badgeRasterPixelSize(logicalSize: 20, devicePixelRatio: 1.25),
        equals(const BadgeRasterSize(width: 25, height: 25)),
      );
    });

    test('长方形徽标按 SVG 宽高比计算宽度并向上取整', () {
      const dsdRatio = 500 / 253.76521;
      final size = badgeRasterPixelSize(
        logicalSize: 20,
        devicePixelRatio: 1.0,
        widthRatio: dsdRatio,
      );
      expect(size.height, 20);
      expect(size.width, (20 * dsdRatio).ceil());
    });
  });

  group('badgeRasterCacheKey', () {
    test('相同 asset 与像素尺寸得到相同 key', () {
      expect(
        badgeRasterCacheKey('assets/images/a.svg', 20, 20),
        badgeRasterCacheKey('assets/images/a.svg', 20, 20),
      );
    });

    test('asset 或尺寸不同得到不同 key', () {
      expect(
        badgeRasterCacheKey('assets/images/a.svg', 20, 20),
        isNot(badgeRasterCacheKey('assets/images/b.svg', 20, 20)),
      );
      expect(
        badgeRasterCacheKey('assets/images/a.svg', 20, 20),
        isNot(badgeRasterCacheKey('assets/images/a.svg', 40, 40)),
      );
      expect(
        badgeRasterCacheKey('assets/images/a.svg', 20, 20),
        isNot(badgeRasterCacheKey('assets/images/a.svg', 20, 40)),
      );
    });
  });
}
