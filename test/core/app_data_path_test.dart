import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:pure_music/core/settings.dart';

void main() {
  const localAppData = r'C:\Users\listener\AppData\Local';
  const roamingAppData = r'C:\Users\listener\AppData\Roaming';
  const userProfile = r'C:\Users\listener';

  test('portable builds keep data next to the executable', () {
    final result = resolveAppDataPath(
      usePortableData: true,
      executablePath: r'D:\Apps\Pure Music\pure_music.exe',
      environment: const {'LOCALAPPDATA': localAppData},
    );

    expect(result, r'D:\Apps\Pure Music\data');
  });

  test('installed builds default to user_data next to the executable', () {
    final result = resolveAppDataPath(
      usePortableData: false,
      executablePath: r'C:\Program Files\Pure Music\pure_music.exe',
      environment: const {
        'LOCALAPPDATA': localAppData,
        'APPDATA': roamingAppData,
      },
    );

    expect(result, r'C:\Program Files\Pure Music\user_data');
  });

  test('installed builds keep user_data without user environment', () {
    final result = resolveDefaultAppDataPath(
      usePortableData: false,
      executablePath: r'C:\Program Files\Pure Music\pure_music.exe',
      environment: const {},
    );

    expect(result, r'C:\Program Files\Pure Music\user_data');
  });

  test('development processes do not write into the SDK directory', () {
    final result = resolveAppDataPath(
      usePortableData: true,
      executablePath: r'C:\flutter\bin\cache\dart.exe',
      environment: const {'LOCALAPPDATA': localAppData},
    );

    expect(result, r'C:\Users\listener\AppData\Local\pure_music');
  });

  test('portable data has a user-writable fallback candidate', () {
    final result = appDataPathCandidates(
      usePortableData: true,
      executablePath: r'C:\Program Files\Pure Music\pure_music.exe',
      environment: const {'LOCALAPPDATA': localAppData},
    );

    expect(result, [
      r'C:\Program Files\Pure Music\data',
      r'C:\Users\listener\AppData\Local\pure_music',
    ]);
  });

  test('installed data has user directory fallback candidates', () {
    final result = appDataPathCandidates(
      usePortableData: false,
      executablePath: r'C:\Program Files\Pure Music\pure_music.exe',
      environment: const {
        'LOCALAPPDATA': localAppData,
        'USERPROFILE': userProfile,
        'APPDATA': roamingAppData,
      },
    );

    expect(result, [
      r'C:\Program Files\Pure Music\user_data',
      r'C:\Users\listener\AppData\Local\pure_music',
      r'C:\Users\listener\AppData\Roaming\pure_music',
    ]);
  });

  test('absolute environment path takes priority', () {
    final result = resolveAppDataPath(
      usePortableData: false,
      executablePath: r'C:\Program Files\Pure Music\pure_music.exe',
      environment: const {
        appDataDirEnvironmentKey: r'E:\Music Data',
        'LOCALAPPDATA': localAppData,
      },
    );

    expect(result, r'E:\Music Data');
  });

  test('relative environment path is ignored', () {
    final result = resolveAppDataPath(
      usePortableData: false,
      executablePath: r'C:\Program Files\Pure Music\pure_music.exe',
      environment: const {
        appDataDirEnvironmentKey: r'..\data',
        'LOCALAPPDATA': localAppData,
      },
    );

    expect(result, r'C:\Program Files\Pure Music\user_data');
  });

  test('installed log directories prefer the data root', () {
    final result = appDataLogDirectoryCandidates(
      usePortableData: false,
      executablePath: r'C:\Program Files\Pure Music\pure_music.exe',
      environment: const {
        'LOCALAPPDATA': localAppData,
        'USERPROFILE': userProfile,
        'APPDATA': roamingAppData,
      },
    );

    expect(result, [
      r'C:\Program Files\Pure Music\user_data\logs',
      r'C:\Users\listener\AppData\Local\pure_music\logs',
      r'C:\Users\listener\AppData\Roaming\pure_music\logs',
      r'C:\Program Files\Pure Music\logs',
    ]);
  });

  test('portable log directories stay next to the executable', () {
    final result = appDataLogDirectoryCandidates(
      usePortableData: true,
      executablePath: r'D:\Apps\Pure Music\pure_music.exe',
      environment: const {'LOCALAPPDATA': localAppData},
    );

    expect(result, [
      r'D:\Apps\Pure Music\logs',
      r'C:\Users\listener\AppData\Local\pure_music\logs',
    ]);
  });

  test('log directories honour the environment override', () {
    final result = appDataLogDirectoryCandidates(
      usePortableData: false,
      executablePath: r'C:\Program Files\Pure Music\pure_music.exe',
      environment: const {
        appDataDirEnvironmentKey: r'E:\Music Data',
        'LOCALAPPDATA': localAppData,
      },
    );

    expect(result.first, r'E:\Music Data\logs');
    expect(result, contains(r'C:\Program Files\Pure Music\user_data\logs'));
  });

  test('writable environment directory is used as data root', () async {
    final root = await Directory.systemTemp.createTemp('pure_music_env_');
    try {
      final dataDir = Directory(path.join(root.path, 'custom data'));
      final warnings = <String>[];
      final resolved = await resolveAppDataDirectory(
        usePortableData: false,
        executablePath: path.join(root.path, 'app', 'pure_music.exe'),
        environment: {appDataDirEnvironmentKey: dataDir.path},
        onWarn: (message, error) => warnings.add(message),
      );

      expect(resolved.path.toLowerCase(), dataDir.path.toLowerCase());
      expect(await dataDir.exists(), isTrue);
      expect(warnings, isEmpty);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('unwritable environment directory falls back with a warning', () async {
    final root = await Directory.systemTemp.createTemp(
      'pure_music_env_fallback_',
    );
    try {
      final appDir = Directory(path.join(root.path, 'app'));
      await appDir.create(recursive: true);
      final blocker = File(path.join(root.path, 'blocked'));
      await blocker.writeAsString('occupied');
      final warnings = <String>[];
      final resolved = await resolveAppDataDirectory(
        usePortableData: false,
        executablePath: path.join(appDir.path, 'pure_music.exe'),
        environment: {appDataDirEnvironmentKey: blocker.path},
        onWarn: (message, error) => warnings.add(message),
      );

      expect(
        resolved.path.toLowerCase(),
        path.join(appDir.path, 'user_data').toLowerCase(),
      );
      expect(warnings, hasLength(1));
      expect(warnings.single, contains(appDataDirEnvironmentKey));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('relative environment directory warns and falls back', () async {
    final root = await Directory.systemTemp.createTemp(
      'pure_music_env_relative_',
    );
    try {
      final appDir = Directory(path.join(root.path, 'app'));
      await appDir.create(recursive: true);
      final warnings = <String>[];
      final resolved = await resolveAppDataDirectory(
        usePortableData: false,
        executablePath: path.join(appDir.path, 'pure_music.exe'),
        environment: const {appDataDirEnvironmentKey: r'relative\data'},
        onWarn: (message, error) => warnings.add(message),
      );

      expect(
        resolved.path.toLowerCase(),
        path.join(appDir.path, 'user_data').toLowerCase(),
      );
      expect(warnings, hasLength(1));
      expect(warnings.single, contains(appDataDirEnvironmentKey));
    } finally {
      await root.delete(recursive: true);
    }
  });
}
