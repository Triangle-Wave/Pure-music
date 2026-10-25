import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/cover_disk_cache.dart';

void main() {
  late Directory root;
  late CoverDiskCache cache;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cover_disk_cache_test_');
    cache = CoverDiskCache(
      rootDirectory: () async => root,
      pruneInterval: const Duration(days: 1),
    );
  });

  tearDown(() async {
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // 测试目录清理失败不影响断言结果。
    }
  });

  test('本地缩略图按源路径、修改时间与尺寸区分', () async {
    const source = r'C:\Music\Album\cover.jpg';
    final file = await cache.writeLocalThumbnail(
      sourcePath: source,
      width: 200,
      height: 200,
      modified: 100,
      bytes: png,
    );

    expect(file, isNotNull);
    expect(await file!.exists(), isTrue);
    expect(
      await cache.readLocalThumbnail(
        sourcePath: source,
        width: 200,
        height: 200,
        modified: 100,
      ),
      isNotNull,
    );
    expect(
      await cache.readLocalThumbnail(
        sourcePath: source,
        width: 200,
        height: 200,
        modified: 101,
      ),
      isNull,
    );
  });

  test('在线封面写盘后命中，TTL 过期后删除', () async {
    var clock = DateTime.now();
    final timed = CoverDiskCache(
      rootDirectory: () async => root,
      clock: () => clock,
      pruneInterval: const Duration(days: 1),
    );
    const url = 'https://img.example.com/cover.jpg';
    expect(await timed.storeNetworkImage(url, png), isNotNull);
    expect(
      await timed.findNetworkImage(url, ttl: const Duration(days: 7)),
      isNotNull,
    );

    clock = clock.add(const Duration(days: 8));
    expect(
      await timed.findNetworkImage(url, ttl: const Duration(days: 7)),
      isNull,
    );
  });

  test('损坏的在线封面文件被删除', () async {
    const url = 'https://img.example.com/broken.jpg';
    final file = await cache.storeNetworkImage(url, png);
    expect(file, isNotNull);
    final stored = file!;
    await stored.writeAsString('not an image');

    expect(
      await cache.findNetworkImage(url, ttl: const Duration(days: 7)),
      isNull,
    );
    expect(await stored.exists(), isFalse);
  });

  test('大小上限触发淘汰并清空文件', () async {
    await cache.writeLocalThumbnail(
      sourcePath: r'C:\Music\A\cover.jpg',
      width: 96,
      height: 96,
      modified: 1,
      bytes: png,
    );
    await cache.storeNetworkImage('https://img.example.com/a.jpg', png);

    await cache.prune(maxBytes: 0);

    final directory = Directory('${root.path}/cache/covers');
    final remaining = await directory.list().toList();
    expect(remaining.whereType<File>(), isEmpty);
  });
}
