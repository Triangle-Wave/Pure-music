import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/cover_disk_cache.dart';

void main() {
  // 普通 test 也需要 binding，保证 PaintingBinding 与图片解码可用。
  TestWidgetsFlutterBinding.ensureInitialized();
  final cache = CoverImageCache.instance;

  setUp(() {
    cache.clear();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  testWidgets('recreated provider reuses a decoded cover after unmount', (
    tester,
  ) async {
    const path = r'C:\music\album\track.flac';
    final provider = cache.stableImageForTesting(
      path: path,
      width: 48,
      height: 48,
      bytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Image(image: provider, width: 48, height: 48),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    final restored = cache.getCached(path: path, width: 48, height: 48);

    expect(restored, isNotNull);
    expect(
      await restored!.obtainKey(ImageConfiguration.empty),
      await provider.obtainKey(ImageConfiguration.empty),
    );
  });

  test('stable key metadata does not grow with album count', () {
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    cache.stableImageForTesting(
      path: 'track-seed.flac',
      width: 48,
      height: 48,
      bytes: bytes,
    );
    final configurationCount = cache.stableImageConfigurationCountForTesting;
    for (var index = 0; index < 2000; index++) {
      cache.stableImageForTesting(
        path: 'track-$index.flac',
        width: 48,
        height: 48,
        bytes: bytes,
      );
    }

    expect(cache.stableImageConfigurationCountForTesting, configurationCount);
  });

  test('decoded bytes cache hits the same path and mtime', () async {
    const path = r'C:\music\album\track.flac';
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    cache.putDecodedBytes(
      path: path,
      width: 160,
      height: 160,
      bytes: bytes,
      modified: 123,
    );

    final hit = await cache.loadBytes(
      path: path,
      width: 160,
      height: 160,
      modified: 123,
    );

    expect(hit, same(bytes));
  });

  test('decoded bytes cache key includes mtime', () async {
    const path = r'C:\music\album\track.flac';
    final first = Uint8List.fromList([1]);
    final second = Uint8List.fromList([2]);
    cache.putDecodedBytes(
      path: path,
      width: 160,
      height: 160,
      bytes: first,
      modified: 1,
    );
    cache.putDecodedBytes(
      path: path,
      width: 160,
      height: 160,
      bytes: second,
      modified: 2,
    );

    expect(
      await cache.loadBytes(path: path, width: 160, height: 160, modified: 1),
      same(first),
    );
    expect(
      await cache.loadBytes(path: path, width: 160, height: 160, modified: 2),
      same(second),
    );
  });

  test('decoded bytes cache keeps at most 20 covers', () {
    for (var i = 0; i < 21; i++) {
      cache.putDecodedBytes(
        path: 'track-$i.flac',
        width: 160,
        height: 160,
        bytes: Uint8List.fromList([i]),
        modified: 1,
      );
    }
    expect(cache.decodedBytesCountForTesting, 20);
  });

  test(
    'trimMemory drops bytes that finish loading afterwards',
    () async {
      final directory = await Directory.systemTemp.createTemp('cover-trim-');
      addTearDown(() async {
        CoverDiskCache.instance.invalidateRoot();
        try {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        } catch (_) {
          // 临时目录清理失败不影响断言结果。
        }
      });
      CoverDiskCache.instance.configure(rootPath: directory.path);
      final imagePath = p.join(directory.path, 'cover.png');
      await File(imagePath).writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );

      final loading = cache.loadBytes(
        path: imagePath,
        width: 160,
        height: 160,
      );
      // 清理发生在加载完成前，迟到的结果不允许写回。
      cache.trimMemory(keepPath: r'C:\music\current.flac');
      final bytes = await loading;

      expect(bytes, isNotNull);
      expect(cache.decodedBytesCountForTesting, 0);
    },
    // 文件读取与图片解码走真实事件循环，超时兜底避免缺陷时长时间挂起。
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
