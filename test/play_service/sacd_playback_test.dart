import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/sacd_gapless_guard.dart';
import 'package:pure_music/play_service/sacd_source_cache.dart';

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
  group('SACD 提取去重', () {
    test('同一轨并发提取共享同一个 Future 且只执行一次', () async {
      final cache = SacdSourceCache();
      var calls = 0;
      final gate = Completer<void>();

      Future<String> load() async {
        calls++;
        await gate.future;
        return r'D:\cache\track01.dsf';
      }

      final first = cache.extract('sacd:d:/music/sacd/album.iso#2ch#01', load);
      final second = cache.extract(
        'sacd:d:/music/sacd/album.iso#2ch#01',
        load,
      );
      gate.complete();

      expect(identical(first, second), isTrue);
      expect(await first, r'D:\cache\track01.dsf');
      expect(calls, 1);
      expect(cache.inFlightCount, 0);
    });

    test('不同轨各自执行提取', () async {
      final cache = SacdSourceCache();
      final calls = <String>[];

      Future<String> load(String key) async {
        calls.add(key);
        return '$key.dsf';
      }

      final first = cache.extract('track01', () => load('track01'));
      final second = cache.extract('track02', () => load('track02'));

      expect(await first, 'track01.dsf');
      expect(await second, 'track02.dsf');
      expect(calls, <String>['track01', 'track02']);
      expect(cache.inFlightCount, 0);
    });

    test('提取失败后移除在途记录，下一次调用重新提取', () async {
      final cache = SacdSourceCache();
      var calls = 0;

      Future<String> load() async {
        calls++;
        if (calls == 1) throw StateError('extract failed');
        return r'D:\cache\track01.dsf';
      }

      await expectLater(
        cache.extract('track01', load),
        throwsA(isA<StateError>()),
      );
      expect(cache.inFlightCount, 0);
      expect(await cache.extract('track01', load), r'D:\cache\track01.dsf');
      expect(calls, 2);
    });

    test('提取完成后再次调用重新进入提取流程', () async {
      final cache = SacdSourceCache();
      var calls = 0;

      Future<String> load() async {
        calls++;
        return r'D:\cache\track01.dsf';
      }

      await cache.extract('track01', load);
      await cache.extract('track01', load);

      expect(calls, 2);
      expect(cache.inFlightCount, 0);
    });
  });

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
}
