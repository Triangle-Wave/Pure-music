import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/playback_source.dart';

Audio _audio(String path) {
  return Audio(
    'title',
    'artist',
    'album',
    null,
    1,
    180,
    320,
    44100,
    path,
    1,
    1,
    null,
  );
}

void main() {
  group('resolvePlaybackSource', () {
    test('普通文件交给源路径且不带段边界', () {
      final source = resolvePlaybackSource(_audio(r'D:\Music\song.flac'));
      expect(source.path, r'D:\Music\song.flac');
      expect(source.startMs, 0);
      expect(source.endMs, 0);
    });

    test('CUE 虚拟轨交给源文件并按毫秒截断', () {
      final source = resolvePlaybackSource(
        _audio(r'D:\Music\album.cue::track=02::start=1000::end=200000'),
      );
      expect(source.path, r'D:\Music\album.cue');
      expect(source.startMs, 1000);
      expect(source.endMs, 200000);
    });

    test('SACD 轨交给虚拟路径且段边界归零', () {
      const virtualPath =
          r'D:\Music\SACD\album.iso'
          '::track=01::start=0::end=200000::sacd=2ch';
      final source = resolvePlaybackSource(_audio(virtualPath));
      expect(source.path, virtualPath);
      expect(source.startMs, 0);
      expect(source.endMs, 0);
    });
  });
}
