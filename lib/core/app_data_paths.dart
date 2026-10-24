import 'package:path/path.dart' as path;

/// 便携版构建标记，由构建脚本通过 `--dart-define=PORTABLE_BUILD=...` 注入。
const bool portableBuild = bool.fromEnvironment(
  'PORTABLE_BUILD',
  defaultValue: true,
);

/// 用户指定数据根的环境变量名，值必须是绝对路径。
const String appDataDirEnvironmentKey = 'PURE_MUSIC_DATA_DIR';

const String _appDataDirName = 'pure_music';
const String _userDataDirectoryName = 'user_data';
const String _portableDataDirectoryName = 'data';

bool _isNativeExecutable(String executablePath) {
  final exeBase = path.basename(executablePath).toLowerCase();
  return exeBase != 'dart.exe' && exeBase != 'flutter_tester.exe';
}

/// 读取 `PURE_MUSIC_DATA_DIR`，只接受绝对路径；空值与相对路径返回 null。
String? customAppDataPath(Map<String, String> environment) {
  final raw = environment[appDataDirEnvironmentKey];
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (!path.windows.isAbsolute(trimmed)) return null;
  return path.windows.normalize(trimmed);
}

/// 用户目录下的数据根回退链：LOCALAPPDATA → USERPROFILE\AppData\Local → APPDATA。
List<String> userAppDataPathCandidates(Map<String, String> environment) {
  final candidates = <String>[];
  final localAppData = environment['LOCALAPPDATA'];
  if (localAppData != null && localAppData.trim().isNotEmpty) {
    candidates.add(path.join(localAppData, _appDataDirName));
  }
  final userProfile = environment['USERPROFILE'];
  if (userProfile != null && userProfile.trim().isNotEmpty) {
    candidates.add(
      path.join(userProfile, 'AppData', 'Local', _appDataDirName),
    );
  }
  final appData = environment['APPDATA'];
  if (appData != null && appData.trim().isNotEmpty) {
    candidates.add(path.join(appData, _appDataDirName));
  }
  return candidates;
}

/// 不含环境变量覆盖的数据根：便携版 `<exe>\data`，安装版 `<exe>\user_data`，
/// 开发进程回退用户目录。
String resolveDefaultAppDataPath({
  required bool usePortableData,
  required String executablePath,
  required Map<String, String> environment,
}) {
  final isNativeExecutable = _isNativeExecutable(executablePath);
  if (usePortableData && isNativeExecutable) {
    return path.join(path.dirname(executablePath), _portableDataDirectoryName);
  }
  if (isNativeExecutable) {
    return path.join(path.dirname(executablePath), _userDataDirectoryName);
  }
  final userCandidates = userAppDataPathCandidates(environment);
  if (userCandidates.isNotEmpty) return userCandidates.first;
  throw StateError('Unable to determine app data directory');
}

/// 生效的数据根：`PURE_MUSIC_DATA_DIR` 优先，其余按默认规则。
String resolveAppDataPath({
  required bool usePortableData,
  required String executablePath,
  required Map<String, String> environment,
}) {
  return customAppDataPath(environment) ??
      resolveDefaultAppDataPath(
        usePortableData: usePortableData,
        executablePath: executablePath,
        environment: environment,
      );
}

/// 数据根候选：环境变量（若有）→ 默认根 → 用户目录回退链，按大小写不敏感去重。
List<String> appDataPathCandidates({
  required bool usePortableData,
  required String executablePath,
  required Map<String, String> environment,
}) {
  final candidates = <String>[];
  void add(String candidate) {
    final normalized = path.normalize(candidate).toLowerCase();
    if (candidates.any(
      (item) => path.normalize(item).toLowerCase() == normalized,
    )) {
      return;
    }
    candidates.add(candidate);
  }

  final custom = customAppDataPath(environment);
  if (custom != null) add(custom);
  add(
    resolveDefaultAppDataPath(
      usePortableData: usePortableData,
      executablePath: executablePath,
      environment: environment,
    ),
  );
  for (final root in userAppDataPathCandidates(environment)) {
    add(root);
  }
  return candidates;
}

/// 日志目录候选。安装版优先 `<root>\logs`，便携版优先 `<exe>\logs`，
/// 之后依次回退用户目录与程序目录，最后由调用方兜底系统临时目录。
List<String> appDataLogDirectoryCandidates({
  required bool usePortableData,
  required String executablePath,
  required Map<String, String> environment,
}) {
  final directories = <String>[];
  void add(String? directory) {
    if (directory == null) return;
    final normalized = path.normalize(directory).toLowerCase();
    if (directories.any(
      (item) => path.normalize(item).toLowerCase() == normalized,
    )) {
      return;
    }
    directories.add(directory);
  }

  final isNativeExecutable = _isNativeExecutable(executablePath);
  final executableLogs = path.join(path.dirname(executablePath), 'logs');
  final custom = customAppDataPath(environment);
  if (custom != null) add(path.join(custom, 'logs'));
  if (usePortableData && isNativeExecutable) add(executableLogs);
  if (!usePortableData && isNativeExecutable) {
    add(
      path.join(
        path.dirname(executablePath),
        _userDataDirectoryName,
        'logs',
      ),
    );
  }
  for (final root in userAppDataPathCandidates(environment)) {
    add(path.join(root, 'logs'));
  }
  if (!usePortableData && isNativeExecutable) add(executableLogs);
  return directories;
}
