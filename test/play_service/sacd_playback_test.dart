import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/sacd_gapless_guard.dart';
import 'package:pure_music/play_service/sacd_stream_request.dart';

Audio _sacdAudio(String track, {int endMs = 90333}) {
  return Audio(
    'Track $track',
    'UNKNOWN',
    'album',
    null,
    int.parse(track),
    90,
    null,
    null,
    'D:\\Music\\SACD\\album.iso::track=$track::start=0::end=$endMs::sacd=2ch',
    1,
    1,
    'sacd',
  );
}

Audio _plainAudio(String path) {
  return Audio(
    'Song',
    'Artist',
    'Album',
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
  group('SACD 无缝预建的二次校验', () {
    final target = _sacdAudio('01');
    final other = _sacdAudio('02');

    bool check({
      bool closed = false,
      int revision = 7,
      int currentRevision = 7,
      int fromIndex = 3,
      int? currentIndex = 3,
      bool pendingStillActive = true,
      Audio? currentTarget,
    }) {
      return isGaplessTargetStillCurrent(
        closed: closed,
        playlistRevision: revision,
        currentPlaylistRevision: currentRevision,
        fromIndex: fromIndex,
        currentIndex: currentIndex,
        pendingStillActive: pendingStillActive,
        currentTarget: currentTarget ?? target,
        target: target,
      );
    }

    test('列表、索引、轨道与在途对象都未变化时继续预建', () {
      expect(check(), isTrue);
    });

    test('播放列表版本变化时放弃预建', () {
      expect(check(currentRevision: 8), isFalse);
    });

    test('当前索引变化时放弃预建', () {
      expect(check(currentIndex: 4), isFalse);
      expect(check(currentIndex: null), isFalse);
    });

    test('在途对象被替换时放弃预建', () {
      expect(check(pendingStillActive: false), isFalse);
    });

    test('目标轨道对象变化时放弃预建', () {
      expect(check(currentTarget: other), isFalse);
    });

    test('目标换成同一 SACD 轨的其他实例时继续预建', () {
      expect(check(currentTarget: _sacdAudio('01')), isTrue);
    });

    test('播放器已关闭时放弃预建', () {
      expect(check(closed: true), isFalse);
    });

    test('普通曲目作为目标时同样按对象身份判断', () {
      final plain = _plainAudio(r'D:\Music\song.flac');
      expect(
        isGaplessTargetStillCurrent(
          closed: false,
          playlistRevision: 1,
          currentPlaylistRevision: 1,
          fromIndex: 0,
          currentIndex: 0,
          pendingStillActive: true,
          currentTarget: plain,
          target: plain,
        ),
        isTrue,
      );
    });

    test('普通曲目换成路径相同的新实例时放弃预建', () {
      final plain = _plainAudio(r'D:\Music\song.flac');
      expect(
        isGaplessTargetStillCurrent(
          closed: false,
          playlistRevision: 1,
          currentPlaylistRevision: 1,
          fromIndex: 0,
          currentIndex: 0,
          pendingStillActive: true,
          currentTarget: _plainAudio(r'D:\Music\song.flac'),
          target: plain,
        ),
        isFalse,
      );
    });
  });

  group('外部流解析不触碰磁盘', () {
    test('ISO 不存在时仍返回建流参数', () {
      const path =
          r'Z:\definitely-missing\album.iso'
          '::track=01::start=0::end=1000::sacd=2ch';
      final request = buildSacdStreamRequest(
        path: path,
        preferPcm: true,
        sampleRate: 44100,
        bitDepth: 24,
      );
      expect(request, isNotNull);
      expect(request!.isoPath, r'Z:\definitely-missing\album.iso');
      expect(request.trackNumber, 1);
    });
  });
}
