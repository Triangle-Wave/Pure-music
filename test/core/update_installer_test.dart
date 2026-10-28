import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/update_checker.dart';
import 'package:pure_music/core/update_installer.dart';

void main() {
  test('refuses install when release has no checksum', () {
    final info = UpdateInfo.fromJson({'tag_name': 'v2.3.0'});
    expect(
      () => ensureUpdateHasChecksum(
        info: info,
        channel: UpdateChannel.github,
        portableBuild: false,
      ),
      throwsA(
        isA<UpdateInstallException>().having(
          (error) => error.message,
          'message',
          contains('校验'),
        ),
      ),
    );
  });

  test('allows install metadata when sha256 is present', () {
    final info = UpdateInfo.fromJson({
      'tag_name': 'v2.3.0',
      'installer_sha256': 'a' * 64,
    });
    ensureUpdateHasChecksum(
      info: info,
      channel: UpdateChannel.github,
      portableBuild: false,
    );
  });

  test('rejects path traversal in portable package entries', () {
    expect(isSafePortableEntryPath(r'C:\pkg', '../evil.exe'), isFalse);
    expect(isSafePortableEntryPath(r'C:\pkg', 'data/app.so'), isTrue);
  });

  test('verifies extracted portable files against the manifest', () async {
    final root = await Directory.systemTemp.createTemp('pure_music_pkg_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final payload = File('${root.path}/pure_music.exe');
    await payload.writeAsString('portable-bytes');
    final digest = (await sha256.bind(payload.openRead()).first).toString();
    final updateDir = Directory('${root.path}/.update');
    await updateDir.create();
    await File('${updateDir.path}/package_manifest.json').writeAsString(
      '{"version":"2.3.0","files":[{"path":"pure_music.exe","sha256":"$digest"}]}',
    );
    await verifyExtractedPortablePackage(root.path);
  });

  test('resumes only when the server returns the next byte range', () {
    expect(
      decideUpdateResumeAction(
        statusCode: HttpStatus.partialContent,
        existingBytes: 10,
        contentRangeStart: 10,
        expectedSize: 40,
      ),
      UpdateResumeAction.append,
    );
    expect(
      decideUpdateResumeAction(
        statusCode: HttpStatus.ok,
        existingBytes: 10,
        contentRangeStart: null,
        expectedSize: 40,
      ),
      UpdateResumeAction.overwrite,
    );
    expect(
      decideUpdateResumeAction(
        statusCode: HttpStatus.partialContent,
        existingBytes: 10,
        contentRangeStart: null,
        expectedSize: 40,
      ),
      UpdateResumeAction.restart,
    );
    expect(
      decideUpdateResumeAction(
        statusCode: HttpStatus.requestedRangeNotSatisfiable,
        existingBytes: 40,
        contentRangeStart: null,
        expectedSize: 40,
      ),
      UpdateResumeAction.alreadyComplete,
    );
  });

  test('parses content range and prefers the known package size', () {
    final range = parseContentRange('bytes 8-19/40');
    expect(range?.start, 8);
    expect(range?.total, 40);
    expect(
      updateDownloadTotal(
        action: UpdateResumeAction.append,
        existingBytes: 8,
        contentRangeTotal: 40,
        contentLength: 32,
        expectedSize: 40,
      ),
      40,
    );
  });

  test('reuses a partial file only within the same source host', () {
    final record = UpdateDownloadRecord(
      tagName: 'v2.4.0',
      portable: false,
      url: 'https://github.com/example/app.exe',
      fileName: 'app.exe',
      sha256: 'ab' * 32,
      expectedSize: 100,
    );
    // 同一主机（同一线路）可以续传。
    expect(
      record.matches(
        tagName: 'v2.4.0',
        portable: false,
        url: 'https://github.com/example/other/app.exe',
        fileName: 'app.exe',
        sha256: 'AB' * 32,
        expectedSize: 100,
      ),
      isTrue,
    );
    // 切换线路（GitHub → Gitee）即使 sha 相同，也不得续接上一线路的字节。
    expect(
      record.matches(
        tagName: 'v2.4.0',
        portable: false,
        url: 'https://gitee.com/example/app.exe',
        fileName: 'app.exe',
        sha256: 'AB' * 32,
        expectedSize: 100,
      ),
      isFalse,
    );
    // 切换代理线路同样丢弃部分文件。
    expect(
      record.matches(
        tagName: 'v2.4.0',
        portable: false,
        url: 'https://ghfast.top/https://github.com/example/app.exe',
        fileName: 'app.exe',
        sha256: 'AB' * 32,
        expectedSize: 100,
      ),
      isFalse,
    );
    expect(
      record.matches(
        tagName: 'v2.4.1',
        portable: false,
        url: 'https://github.com/example/app.exe',
        fileName: 'app.exe',
        sha256: 'ab' * 32,
        expectedSize: 100,
      ),
      isFalse,
    );
  });

  test('keeps a newer partial and removes an already installed package', () async {
    final dir = await Directory.systemTemp.createTemp('pure_music_updates_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    Future<void> writeRecord(String tag) async {
      await File('${dir.path}/app.exe').writeAsString('partial');
      await File('${dir.path}/download.json').writeAsString(
        jsonEncode({
          'tagName': tag,
          'portable': false,
          'url': 'https://github.com/example/app.exe',
          'fileName': 'app.exe',
          'sha256': 'cd' * 32,
          'expectedSize': 7,
        }),
      );
    }

    await writeRecord('v3.0.0');
    await cleanupCachedUpdateDownload(directory: dir, currentVersion: '2.0.0');
    expect(await File('${dir.path}/app.exe').exists(), isTrue);
    expect(await File('${dir.path}/download.json').exists(), isTrue);

    await writeRecord('v2.0.0');
    await cleanupCachedUpdateDownload(directory: dir, currentVersion: '2.0.0');
    expect(await File('${dir.path}/app.exe').exists(), isFalse);
    expect(await File('${dir.path}/download.json').exists(), isFalse);
  });

  test('remembers a verified package until that version is installed', () async {
    final dir = await Directory.systemTemp.createTemp('pure_music_notice_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await File('${dir.path}/app.exe').writeAsString('1234567');
    final info = UpdateInfo.fromJson({
      'tag_name': 'v3.1.0',
      'installer_url': 'https://github.com/example/app.exe',
      'installer_sha256': 'ab' * 32,
      'installer_size': 7,
    });
    await File('${dir.path}/download.json').writeAsString(
      jsonEncode(
        UpdateDownloadRecord(
          tagName: 'v3.1.0',
          portable: false,
          url: 'https://github.com/example/app.exe',
          fileName: 'app.exe',
          sha256: 'ab' * 32,
          expectedSize: 7,
        ).toJson(),
      ),
    );

    await rememberVerifiedUpdatePackage(
      savePath: '${dir.path}${Platform.pathSeparator}app.exe',
      info: info,
      channel: UpdateChannel.github,
    );
    final ready = await readVerifiedUpdateNotice(
      directory: dir,
      currentVersion: '3.0.0',
    );
    expect(ready?.info.tagName, 'v3.1.0');
    expect(ready?.channel, UpdateChannel.github);

    final installed = await readVerifiedUpdateNotice(
      directory: dir,
      currentVersion: '3.1.0',
    );
    expect(installed, isNull);
  });

  test('accepts a locally packed portable directory', () async {
    final dir = Directory('output/pure_music_2.3.0_release_portable');
    if (!dir.existsSync()) {
      markTestSkipped('no local packed portable directory');
      return;
    }
    await verifyExtractedPortablePackage(dir.path);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
