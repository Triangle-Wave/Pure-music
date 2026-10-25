import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/online_lyric/api/lyric_request_scheduler.dart';

void main() {
  test('small lyric work stays on the current isolate', () {
    expect(shouldRunLyricWorkInline(0), isTrue);
    expect(shouldRunLyricWorkInline(256 * 1024), isTrue);
    expect(shouldRunLyricWorkInline(256 * 1024 + 1), isFalse);
  });

  test('new interactive request supersedes queued work', () async {
    final scheduler = LyricRequestScheduler();
    addTearDown(scheduler.close);
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final firstToken = scheduler.beginInteractive();
    var queuedRuns = 0;

    final first = scheduler.runInteractive((token) async {
      firstStarted.complete();
      await releaseFirst.future;
      return token.isCancelled ? null : 'old';
    });
    await firstStarted.future;

    final queued = scheduler.runInteractive((_) async {
      queuedRuns++;
      return 'queued';
    });
    final latestToken = scheduler.beginInteractive();
    final latest = scheduler.runInteractive((token) async {
      return token == latestToken ? 'latest' : null;
    });

    releaseFirst.complete();

    expect(await first, isNull);
    expect(await queued, isNull);
    expect(await latest, 'latest');
    expect(queuedRuns, 0);
    expect(firstToken.isCancelled, isTrue);
  });

  test('background lane keeps one running task and a bounded queue', () async {
    final scheduler = LyricRequestScheduler(backgroundQueueLimit: 2);
    addTearDown(scheduler.close);
    final release = Completer<void>();
    var running = 0;
    var peak = 0;
    var executed = 0;

    Future<String?> task() => scheduler.runBackground((_) async {
      running++;
      peak = running > peak ? running : peak;
      executed++;
      await release.future;
      running--;
      return 'done';
    });

    final futures = [task(), task(), task(), task()];
    release.complete();

    final results = await Future.wait(futures);

    expect(peak, 1);
    expect(executed, 3);
    expect(results.whereType<String>(), hasLength(3));
    expect(results.where((result) => result == null), hasLength(1));
  });
}
