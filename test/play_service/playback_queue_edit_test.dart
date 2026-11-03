import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/playback_service.dart';

Audio _audio(String name) =>
    Audio(name, '', '', null, 0, 1, null, null, name, 0, 0, null);

List<String> _paths(Iterable<Audio> audios) =>
    audios.map((audio) => audio.path).toList();

void main() {
  group('replaceCurrentForPlayback', () {
    test('目标曲目不在队列时替换当前位置且长度不变', () {
      final a = _audio('a.mp3');
      final b = _audio('b.mp3');
      final c = _audio('c.mp3');
      final target = _audio('target.mp3');

      final result = PlaybackService.replaceCurrentForPlayback(
        queue: [a, b, c],
        index: 1,
        target: target,
      );

      expect(_paths(result.queue), ['a.mp3', 'target.mp3', 'c.mp3']);
      expect(result.index, 1);
      expect(result.queue[result.index], same(target));
    });

    test('目标曲目位于当前位置后方时删除原位置且索引不变', () {
      final a = _audio('a.mp3');
      final b = _audio('b.mp3');
      final c = _audio('c.mp3');
      final d = _audio('d.mp3');

      final result = PlaybackService.replaceCurrentForPlayback(
        queue: [a, b, c, d],
        index: 1,
        target: d,
      );

      expect(_paths(result.queue), ['a.mp3', 'd.mp3', 'c.mp3']);
      expect(result.index, 1);
      expect(result.queue[result.index], same(d));
    });

    test('目标曲目位于当前位置前方时删除原位置且索引减一', () {
      final a = _audio('a.mp3');
      final b = _audio('b.mp3');
      final c = _audio('c.mp3');
      final d = _audio('d.mp3');

      final result = PlaybackService.replaceCurrentForPlayback(
        queue: [a, b, c, d],
        index: 2,
        target: a,
      );

      expect(_paths(result.queue), ['b.mp3', 'a.mp3', 'd.mp3']);
      expect(result.index, 1);
      expect(result.queue[result.index], same(a));
    });

    test('目标曲目就是当前曲目时队列不变', () {
      final a = _audio('a.mp3');
      final b = _audio('b.mp3');
      final c = _audio('c.mp3');

      final result = PlaybackService.replaceCurrentForPlayback(
        queue: [a, b, c],
        index: 1,
        target: b,
      );

      expect(_paths(result.queue), ['a.mp3', 'b.mp3', 'c.mp3']);
      expect(result.index, 1);
    });

    test('空队列产生单曲队列', () {
      final target = _audio('target.mp3');

      final result = PlaybackService.replaceCurrentForPlayback(
        queue: <Audio>[],
        index: 0,
        target: target,
      );

      expect(_paths(result.queue), ['target.mp3']);
      expect(result.index, 0);
      expect(result.queue.single, same(target));
    });

    test('单曲队列中目标就是当前曲目时保留该项', () {
      final a = _audio('a.mp3');

      final result = PlaybackService.replaceCurrentForPlayback(
        queue: [a],
        index: 0,
        target: a,
      );

      expect(_paths(result.queue), ['a.mp3']);
      expect(result.index, 0);
    });

    test('越界索引按末尾位置替换', () {
      final a = _audio('a.mp3');
      final b = _audio('b.mp3');
      final target = _audio('target.mp3');

      final result = PlaybackService.replaceCurrentForPlayback(
        queue: [a, b],
        index: 99,
        target: target,
      );

      expect(_paths(result.queue), ['a.mp3', 'target.mp3']);
      expect(result.index, 1);
    });

    test('负索引按起始位置替换', () {
      final a = _audio('a.mp3');
      final b = _audio('b.mp3');
      final target = _audio('target.mp3');

      final result = PlaybackService.replaceCurrentForPlayback(
        queue: [a, b],
        index: -3,
        target: target,
      );

      expect(_paths(result.queue), ['target.mp3', 'b.mp3']);
      expect(result.index, 0);
    });

    test('返回的队列为不可变快照', () {
      final a = _audio('a.mp3');
      final target = _audio('target.mp3');

      final result = PlaybackService.replaceCurrentForPlayback(
        queue: [a],
        index: 0,
        target: target,
      );

      expect(() => result.queue.add(a), throwsUnsupportedError);
    });
  });

  group('replaceBackupForPlayback', () {
    test('把被替换曲目在备份中的位置换成目标曲目', () {
      final a = _audio('a.mp3');
      final b = _audio('b.mp3');
      final c = _audio('c.mp3');
      final target = _audio('target.mp3');

      final result = PlaybackService.replaceBackupForPlayback(
        backup: [a, b, c],
        replaced: b,
        target: target,
      );

      expect(_paths(result), ['a.mp3', 'target.mp3', 'c.mp3']);
      expect(result[1], same(target));
    });

    test('目标曲目已在备份中时删除重复项', () {
      final a = _audio('a.mp3');
      final b = _audio('b.mp3');
      final c = _audio('c.mp3');
      final d = _audio('d.mp3');

      final result = PlaybackService.replaceBackupForPlayback(
        backup: [a, b, c, d],
        replaced: b,
        target: d,
      );

      expect(_paths(result), ['a.mp3', 'd.mp3', 'c.mp3']);
      expect(result[1], same(d));
    });

    test('目标曲目在备份中位于被替换曲目之前时同步前移', () {
      final a = _audio('a.mp3');
      final b = _audio('b.mp3');
      final c = _audio('c.mp3');
      final d = _audio('d.mp3');

      final result = PlaybackService.replaceBackupForPlayback(
        backup: [a, b, c, d],
        replaced: c,
        target: a,
      );

      expect(_paths(result), ['b.mp3', 'a.mp3', 'd.mp3']);
      expect(result[1], same(a));
    });

    test('备份里找不到被替换曲目时保持不变', () {
      final a = _audio('a.mp3');
      final b = _audio('b.mp3');
      final target = _audio('target.mp3');

      final result = PlaybackService.replaceBackupForPlayback(
        backup: [a, b],
        replaced: _audio('missing.mp3'),
        target: target,
      );

      expect(_paths(result), ['a.mp3', 'b.mp3']);
    });

    test('空备份得到单曲备份', () {
      final target = _audio('target.mp3');

      final result = PlaybackService.replaceBackupForPlayback(
        backup: <Audio>[],
        replaced: _audio('missing.mp3'),
        target: target,
      );

      expect(_paths(result), ['target.mp3']);
      expect(result.single, same(target));
    });

    test('目标曲目就是被替换曲目时备份不变', () {
      final a = _audio('a.mp3');
      final b = _audio('b.mp3');

      final result = PlaybackService.replaceBackupForPlayback(
        backup: [a, b],
        replaced: b,
        target: b,
      );

      expect(_paths(result), ['a.mp3', 'b.mp3']);
      expect(result[1], same(b));
    });
  });
}
