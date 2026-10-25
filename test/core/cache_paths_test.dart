import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/core/cache_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataRoot;

  setUp(() async {
    dataRoot = await Directory.systemTemp.createTemp('cache_paths_test_');
    debugConfigureCachePaths(
      dataRoot: () async => dataRoot,
      cacheDirectory: () => '',
    );
  });

  tearDown(() async {
    debugConfigureCachePaths();
    try {
      if (await dataRoot.exists()) await dataRoot.delete(recursive: true);
    } catch (_) {
      // 测试目录清理失败不影响断言结果。
    }
  });

  test('未设置缓存目录时使用数据根下的 cache', () async {
    final root = await getCacheRoot();

    expect(p.equals(root.path, p.join(dataRoot.path, 'cache')), isTrue);
    await ensureCacheDirectories();
    for (final name in cacheSubdirectoryNames) {
      expect(await Directory(p.join(root.path, name)).exists(), isTrue);
    }
  });

  test('设置绝对路径后使用自定义缓存根', () async {
    final custom = await Directory(
      p.join(dataRoot.path, 'other_drive'),
    ).create(recursive: true);
    debugConfigureCachePaths(
      dataRoot: () async => dataRoot,
      cacheDirectory: () => custom.path,
    );

    final root = await getCacheRoot();

    expect(p.equals(root.path, custom.path), isTrue);
    final covers = await getCoverCacheDirectory();
    expect(p.equals(covers.path, p.join(custom.path, 'covers')), isTrue);
  });

  test('相对路径回退默认位置', () async {
    debugConfigureCachePaths(
      dataRoot: () async => dataRoot,
      cacheDirectory: () => 'relative/cache',
    );

    final root = await getCacheRoot();

    expect(p.equals(root.path, p.join(dataRoot.path, 'cache')), isTrue);
  });

  test('不可写路径回退默认位置', () async {
    final blocker = File(p.join(dataRoot.path, 'blocked'));
    await blocker.writeAsString('not a directory');
    debugConfigureCachePaths(
      dataRoot: () async => dataRoot,
      cacheDirectory: () => blocker.path,
    );

    final root = await getCacheRoot();

    expect(p.equals(root.path, p.join(dataRoot.path, 'cache')), isTrue);
  });

  test('清理缓存只删除缓存文件，保留设置', () async {
    final root = await getCacheRoot();
    final covers = Directory(p.join(root.path, 'covers'));
    await covers.create(recursive: true);
    final cover = File(p.join(covers.path, 'cover.png'));
    await cover.writeAsBytes(const [1, 2, 3]);
    final settings = File(p.join(dataRoot.path, 'settings', 'settings.json'));
    await settings.parent.create(recursive: true);
    await settings.writeAsString('{}');

    final report = await clearCache();

    expect(report.files, 1);
    expect(report.bytes, 3);
    expect(await cover.exists(), isFalse);
    expect(await settings.exists(), isTrue);
  });
}
