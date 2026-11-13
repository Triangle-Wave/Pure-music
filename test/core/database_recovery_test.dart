import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';

void main() {
  group('损坏码判定', () {
    test('SQLITE_CORRUPT 与 SQLITE_NOTADB 判定为损坏', () {
      expect(AppDb.isCorruptionCode(11), isTrue);
      expect(AppDb.isCorruptionCode(26), isTrue);
    });

    test('扩展结果码按低 8 位判定', () {
      expect(AppDb.isCorruptionCode(11 | (3 << 8)), isTrue);
      expect(AppDb.isCorruptionCode(26 | (1 << 8)), isTrue);
      expect(AppDb.isCorruptionCode(11 | (7 << 8) | (2 << 16)), isTrue);
    });

    test('其余错误码不触发隔离', () {
      for (final code in const [0, 1, 5, 8, 9, 14, 19, 101]) {
        expect(AppDb.isCorruptionCode(code), isFalse, reason: 'code=$code');
      }
    });
  });

  group('损坏文件隔离', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('pure_music_db_recovery_');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('主库与 WAL/SHM 一并改名并返回主库新路径', () {
      final dbPath = '${root.path}${Platform.pathSeparator}app.sqlite';
      File(dbPath).writeAsStringSync('corrupt-main');
      File('$dbPath-wal').writeAsStringSync('corrupt-wal');
      File('$dbPath-shm').writeAsStringSync('corrupt-shm');

      final quarantined = AppDb.quarantineDatabase(File(dbPath));

      expect(quarantined, isA<String>());
      final target = quarantined!;
      expect(target, contains('.corrupt-'));
      expect(File(dbPath).existsSync(), isFalse);
      expect(File(target).readAsStringSync(), 'corrupt-main');

      final stamp = target.substring('${dbPath}.corrupt-'.length);
      expect(File('$dbPath-wal').existsSync(), isFalse);
      expect(File('$dbPath-shm').existsSync(), isFalse);
      expect(
        File('$dbPath.corrupt-$stamp-wal').readAsStringSync(),
        'corrupt-wal',
      );
      expect(
        File('$dbPath.corrupt-$stamp-shm').readAsStringSync(),
        'corrupt-shm',
      );
    });

    test('只有主库时只隔离主库', () {
      final dbPath = '${root.path}${Platform.pathSeparator}app.sqlite';
      File(dbPath).writeAsStringSync('corrupt-main');

      final quarantined = AppDb.quarantineDatabase(File(dbPath));

      expect(quarantined, isA<String>());
      expect(File(dbPath).existsSync(), isFalse);
      expect(File(quarantined!).readAsStringSync(), 'corrupt-main');
    });

    test('主库不存在时返回 null', () {
      final dbPath = '${root.path}${Platform.pathSeparator}app.sqlite';
      File('$dbPath-wal').writeAsStringSync('corrupt-wal');

      expect(AppDb.quarantineDatabase(File(dbPath)), isNull);
    });
  });
}
