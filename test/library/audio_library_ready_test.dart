import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';

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
  setUp(() {
    // 持久 Completer 一旦完成无法重置。用例按状态依赖排序：
    // 先「挂起断言」与「挂起→signal→唤醒」两个真实覆盖挂起态的用例，
    // 再「曲库非空快捷路径」，最后「重复 signal」（已完成态下验证幂等）。
    // 每个用例都清空曲库，避免上一个用例的 audioCollection 干扰就绪判定。
    AudioLibrary.instance.dispose();
  });

  test('libraryReady stays pending while the collection is empty', () async {
    AudioLibrary.instance.audioCollection = [];

    await expectLater(
      AudioLibrary.libraryReady.timeout(const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('libraryReady completes after signalLibraryReadyForTesting', () async {
    AudioLibrary.instance.audioCollection = [];
    final ready = AudioLibrary.libraryReady;

    AudioLibrary.signalLibraryReadyForTesting();

    await expectLater(ready, completes);
  });

  test('libraryReady completes immediately when collection is populated',
      () async {
    AudioLibrary.instance.audioCollection = [_audio(r'C:\Music\a.mp3')];

    await expectLater(AudioLibrary.libraryReady, completes);
  });

  test('signalLibraryReadyForTesting is safe to call repeatedly', () async {
    AudioLibrary.instance.audioCollection = [];
    // 持久 Completer 此时已完成；重复 signal 走 isCompleted 保护分支。
    final ready = AudioLibrary.libraryReady;

    AudioLibrary.signalLibraryReadyForTesting();
    AudioLibrary.signalLibraryReadyForTesting();

    await expectLater(ready, completes);
  });
}
