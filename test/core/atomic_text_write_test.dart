import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/settings.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pure_music_atomic_write_');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('serializes concurrent writes and keeps the last content', () async {
    final target = File('${root.path}${Platform.pathSeparator}settings.json');

    final first = writeTextFileAtomically(target.path, 'first');
    final second = writeTextFileAtomically(target.path, 'second');
    await Future.wait([first, second]);

    expect(await target.readAsString(), 'second');
  });

  test(
    'merges a burst of writes into one snapshot without temp files',
    () async {
      final target = File('${root.path}${Platform.pathSeparator}pending.json');
      final pending = <Future<void>>[];
      for (var i = 0; i < 8; i++) {
        pending.add(writeTextFileAtomically(target.path, '{"value":$i}'));
      }
      await Future.wait(pending);

      expect(await target.readAsString(), '{"value":7}');
      final leftovers = root
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('.tmp.'))
          .toList();
      expect(leftovers, isEmpty);
    },
  );

  test(
    'a failed write does not block a later write to the same path',
    () async {
      final parent = File('${root.path}${Platform.pathSeparator}settings');
      await parent.writeAsString('not a directory');
      final targetPath = '${parent.path}${Platform.pathSeparator}settings.json';

      await expectLater(
        writeTextFileAtomically(targetPath, 'failed'),
        throwsA(anything),
      );

      await parent.delete();
      await Directory(parent.path).create();
      await writeTextFileAtomically(targetPath, 'recovered');

      expect(await File(targetPath).readAsString(), 'recovered');
    },
  );
}
