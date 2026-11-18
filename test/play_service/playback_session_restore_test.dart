import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/playback_service.dart';

Audio _audio(String path) => Audio(
      'title',
      'artist',
      'album',
      null,
      1,
      60,
      320,
      44100,
      path,
      1,
      1,
      'test',
    );

void main() {
  group('playlistFromSessionPaths', () {
    late Audio a;
    late Audio b;
    late Map<String, Audio> pathToAudio;

    setUp(() {
      a = _audio(r'C:\Music\a.mp3');
      b = _audio(r'C:\Music\b.mp3');
      pathToAudio = {a.path: a, b.path: b};
    });

    test('keeps only matched paths in the saved order', () {
      final result = PlaybackService.playlistFromSessionPaths(
        [b.path, r'C:\Music\missing.mp3', a.path],
        pathToAudio,
        a.path,
      );

      expect(result.map((e) => e.path), [b.path, a.path]);
    });

    test('falls back to the last audio when no saved path matches', () {
      final result = PlaybackService.playlistFromSessionPaths(
        [r'C:\Music\missing.mp3'],
        pathToAudio,
        b.path,
      );

      expect(result.map((e) => e.path), [b.path]);
    });

    test('returns an empty list when nothing matches including last audio',
        () {
      final result = PlaybackService.playlistFromSessionPaths(
        [r'C:\Music\missing.mp3'],
        pathToAudio,
        r'C:\Music\also_missing.mp3',
      );

      expect(result, isEmpty);
    });
  });

  group('shouldRestoreSession', () {
    test('restores when nothing is playing', () {
      expect(
        PlaybackService.shouldRestoreSession(
          nowPlaying: null,
          playlistNotEmpty: false,
        ),
        isTrue,
      );
    });

    test('skips restore when an audio is already playing', () {
      expect(
        PlaybackService.shouldRestoreSession(
          nowPlaying: _audio(r'C:\Music\a.mp3'),
          playlistNotEmpty: false,
        ),
        isFalse,
      );
    });

    test('skips restore when the playlist is already populated', () {
      expect(
        PlaybackService.shouldRestoreSession(
          nowPlaying: null,
          playlistNotEmpty: true,
        ),
        isFalse,
      );
    });
  });

  group('waitForAudioCollectionReady', () {
    setUp(() {
      // 持久 Completer 不可重置。用例按状态依赖排序：不触发 signal 的两个
      // 用例在前（超时断言必须在信号完成前），首个 signal 用例紧随其后以
      // 真实覆盖「挂起→signal→唤醒→复查→true」链路，复查空库用例收尾。
      AudioLibrary.instance.dispose();
    });

    test('returns true immediately when the collection is populated', () async {
      AudioLibrary.instance.audioCollection = [_audio(r'C:\Music\a.mp3')];

      final ready = await PlaybackService.waitForAudioCollectionReady(
        timeout: const Duration(milliseconds: 20),
      );

      expect(ready, isTrue);
    });

    test('returns false on timeout when the collection stays empty', () async {
      AudioLibrary.instance.audioCollection = [];

      final ready = await PlaybackService.waitForAudioCollectionReady(
        timeout: const Duration(milliseconds: 30),
      );

      expect(ready, isFalse);
    });

    test('returns true when the signal arrives and the collection is filled',
        () async {
      AudioLibrary.instance.audioCollection = [];

      final waiting = PlaybackService.waitForAudioCollectionReady(
        timeout: const Duration(seconds: 1),
      );
      AudioLibrary.instance.audioCollection = [_audio(r'C:\Music\a.mp3')];
      AudioLibrary.signalLibraryReadyForTesting();

      expect(await waiting, isTrue);
    });

    test('rechecks the collection after the signal and returns false when still empty',
        () async {
      AudioLibrary.instance.audioCollection = [];

      final waiting = PlaybackService.waitForAudioCollectionReady(
        timeout: const Duration(seconds: 1),
      );
      AudioLibrary.signalLibraryReadyForTesting();

      // 持久信号此时已完成；等待方复查 audioCollection 仍为空时返回 false。
      expect(await waiting, isFalse);
    });
  });
}
