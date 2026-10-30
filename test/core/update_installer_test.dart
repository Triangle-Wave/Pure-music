import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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

  group('installerLogShowsStart', () {
    final startedAt = DateTime(2026, 10, 29, 12);

    test('treats growth after the baseline as started', () {
      expect(
        installerLogShowsStart(
          startedAt: startedAt,
          modified: startedAt.subtract(const Duration(minutes: 5)),
          baselineLength: 120,
          currentLength: 160,
        ),
        isTrue,
      );
    });

    test('accepts a fresh write when the length is unchanged', () {
      expect(
        installerLogShowsStart(
          startedAt: startedAt,
          modified: startedAt.add(const Duration(milliseconds: 200)),
          baselineLength: 120,
          currentLength: 120,
        ),
        isTrue,
      );
    });

    test('ignores a log whose last write predates the start', () {
      expect(
        installerLogShowsStart(
          startedAt: startedAt,
          modified: startedAt.subtract(const Duration(seconds: 1)),
          baselineLength: 120,
          currentLength: 120,
        ),
        isFalse,
      );
      expect(
        installerLogShowsStart(
          startedAt: startedAt,
          modified: null,
          baselineLength: 120,
          currentLength: 120,
        ),
        isFalse,
      );
    });

    test('skips the length check when the baseline is unknown', () {
      expect(
        installerLogShowsStart(
          startedAt: startedAt,
          modified: startedAt.subtract(const Duration(minutes: 5)),
          baselineLength: null,
          currentLength: 999,
        ),
        isFalse,
      );
    });
  });

  group('startInstallerUpdate', () {
    const installerPath =
        r'E:\My Applications\Pure Music\user_data\updates'
        r'\pure_music_2.3.13_release_installer.exe';
    const executablePath = r'E:\My Applications\Pure Music\pure_music.exe';

    late Directory logDirectory;
    late String logPath;

    setUp(() async {
      logDirectory = await Directory.systemTemp.createTemp(
        'pure_music_install_',
      );
      logPath = p.join(logDirectory.path, 'installer_update.log');
    });

    tearDown(() async {
      if (await logDirectory.exists()) {
        await logDirectory.delete(recursive: true);
      }
    });

    test('starts the installer directly and exits the app', () async {
      String? launchedExecutable;
      List<String>? launchedArguments;
      String? launchedWorkingDirectory;
      var launchCalls = 0;
      final phases = <String>[];
      var exitCalls = 0;

      final outcome = await UpdateInstaller.startInstallerUpdate(
        installerPath: installerPath,
        executablePath: executablePath,
        logPath: logPath,
        onPhase: phases.add,
        launchProcess:
            (executable, arguments, {required workingDirectory}) async {
              launchCalls += 1;
              launchedExecutable = executable;
              launchedArguments = arguments;
              launchedWorkingDirectory = workingDirectory;
              return 4242;
            },
        exitApp: () async {
          exitCalls += 1;
        },
      );

      expect(outcome, UpdateInstallOutcome.installerStarted);
      expect(launchCalls, 1);
      expect(launchedExecutable, installerPath);
      expect(launchedArguments, const ['/CLOSEAPPLICATIONS']);
      expect(launchedWorkingDirectory, p.dirname(installerPath));
      expect(phases, contains('正在启动安装程序'));
      expect(exitCalls, 1);

      final logContent = await File(logPath).readAsString();
      expect(logContent, contains('进入安装'));
      expect(logContent, contains(installerPath));
      expect(logContent, contains('/CLOSEAPPLICATIONS'));
      expect(logContent, contains('pid=4242'));
      expect(logContent, contains('安装程序已启动'));
      expect(logContent, isNot(contains('powershell')));
    });

    test('reports a launch failure and keeps the app running', () async {
      var exitCalls = 0;

      await expectLater(
        UpdateInstaller.startInstallerUpdate(
          installerPath: installerPath,
          executablePath: executablePath,
          logPath: logPath,
          onPhase: (_) {},
          launchProcess:
              (executable, arguments, {required workingDirectory}) async {
                throw const ProcessException(
                  'pure_music_2.3.13_release_installer.exe',
                  ['/CLOSEAPPLICATIONS'],
                  '拒绝访问',
                  5,
                );
              },
          exitApp: () async {
            exitCalls += 1;
          },
        ),
        throwsA(
          isA<UpdateInstallException>()
              .having(
                (error) => error.message,
                'message',
                contains('启动安装程序失败'),
              )
              .having(
                (error) => error.message,
                'message',
                contains(installerPath),
              ),
        ),
      );
      expect(exitCalls, 0);
    });

    test('treats a non-positive pid as a launch failure', () async {
      var exitCalls = 0;

      await expectLater(
        UpdateInstaller.startInstallerUpdate(
          installerPath: installerPath,
          executablePath: executablePath,
          logPath: logPath,
          onPhase: (_) {},
          launchProcess:
              (executable, arguments, {required workingDirectory}) async =>
                  0,
          exitApp: () async {
            exitCalls += 1;
          },
        ),
        throwsA(
          isA<UpdateInstallException>().having(
            (error) => error.message,
            'message',
            contains('进程未创建'),
          ),
        ),
      );
      expect(exitCalls, 0);
    });
  });
}
