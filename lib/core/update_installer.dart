import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/core/app_http.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/update_checker.dart';
import 'package:pure_music/core/update_route.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/window_lifecycle.dart';

enum UpdateInstallOutcome { installerStarted, portableStarted }

class UpdateInstallException implements Exception {
  UpdateInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef UpdateProgressCallback = void Function(int received, int total);

typedef UpdatePhaseCallback = void Function(String phase);

void ensureUpdateHasChecksum({
  required UpdateInfo info,
  required UpdateChannel channel,
  required bool portableBuild,
}) {
  if (!info.hasChecksum(channel: channel, portableBuild: portableBuild)) {
    throw UpdateInstallException('缺少更新校验信息，已停止安装');
  }
}

bool isSafePortableEntryPath(String root, String relative) {
  final unified = relative.trim().replaceAll('\\', '/');
  if (unified.isEmpty || p.isAbsolute(unified)) return false;
  final normalized = p.posix.normalize(unified);
  if (normalized == '.' ||
      normalized == '..' ||
      normalized.startsWith('../')) {
    return false;
  }
  final dest = p.normalize(p.join(root, normalized.split('/').join(p.separator)));
  return p.isWithin(p.normalize(root), dest);
}

Future<void> verifyExtractedPortablePackage(String appDir) async {
  final manifestFile = File(
    p.join(appDir, '.update', 'package_manifest.json'),
  );
  if (!await manifestFile.exists()) {
    throw UpdateInstallException('便携版更新包缺少校验清单');
  }
  final decoded = jsonDecode(await manifestFile.readAsString());
  if (decoded is! Map || decoded['files'] is! List) {
    throw UpdateInstallException('便携版更新包校验清单无效');
  }
  final files = decoded['files'] as List;
  var checked = 0;
  for (final entry in files) {
    if (entry is! Map) continue;
    final relative = entry['path'];
    final digest = entry['sha256'];
    if (relative is! String || digest is! String) continue;
    if (!isSafePortableEntryPath(appDir, relative)) {
      throw UpdateInstallException('便携版更新包校验清单无效');
    }
    final file = File(
      p.join(appDir, relative.replaceAll('/', p.separator)),
    );
    if (!await file.exists()) {
      throw UpdateInstallException('便携版更新包不完整');
    }
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(digest)) {
      throw UpdateInstallException('便携版更新包校验清单无效');
    }
    final actual = (await sha256.bind(file.openRead()).first).toString();
    if (actual.toLowerCase() != digest.toLowerCase()) {
      throw UpdateInstallException('便携版更新包校验失败');
    }
    checked += 1;
  }
  if (checked == 0) {
    throw UpdateInstallException('便携版更新包校验清单无效');
  }
}

const updateDownloadDirectoryName = 'updates';
const updateDownloadStateFileName = 'download.json';

enum UpdateResumeAction { append, overwrite, alreadyComplete, restart }

class ContentRange {
  const ContentRange(this.start, this.total);

  final int start;
  final int? total;
}

ContentRange? parseContentRange(String? header) {
  if (header == null || header.isEmpty) return null;
  final match = RegExp(
    r'bytes\s+(\d+)-\d+/(\d+|\*)',
  ).firstMatch(header.trim());
  if (match == null) return null;
  final start = int.tryParse(match.group(1)!);
  if (start == null) return null;
  final totalRaw = match.group(2)!;
  if (totalRaw == '*') return ContentRange(start, null);
  final total = int.tryParse(totalRaw);
  if (total == null) return null;
  return ContentRange(start, total);
}

/// 200 表示服务器给了整包，必须覆盖。只有明确的 206 才能接到已有字节后面。
UpdateResumeAction decideUpdateResumeAction({
  required int statusCode,
  required int existingBytes,
  required int? contentRangeStart,
  required int? expectedSize,
}) {
  if (statusCode == HttpStatus.requestedRangeNotSatisfiable) {
    if (expectedSize != null &&
        existingBytes == expectedSize &&
        existingBytes > 0) {
      return UpdateResumeAction.alreadyComplete;
    }
    return UpdateResumeAction.restart;
  }
  if (statusCode == HttpStatus.partialContent) {
    if (contentRangeStart == null || contentRangeStart != existingBytes) {
      return UpdateResumeAction.restart;
    }
    return existingBytes > 0
        ? UpdateResumeAction.append
        : UpdateResumeAction.overwrite;
  }
  if (statusCode == HttpStatus.ok) return UpdateResumeAction.overwrite;
  return UpdateResumeAction.restart;
}

int updateDownloadTotal({
  required UpdateResumeAction action,
  required int existingBytes,
  required int? contentRangeTotal,
  required int? contentLength,
  required int? expectedSize,
}) {
  if (expectedSize != null && expectedSize > 0) return expectedSize;
  if (contentRangeTotal != null && contentRangeTotal > 0) {
    return contentRangeTotal;
  }
  if (contentLength != null && contentLength > 0) {
    if (action == UpdateResumeAction.append) {
      return existingBytes + contentLength;
    }
    return contentLength;
  }
  return existingBytes > 0 ? existingBytes : 0;
}

class UpdateDownloadRecord {
  const UpdateDownloadRecord({
    required this.tagName,
    required this.portable,
    required this.url,
    required this.fileName,
    this.sha256,
    this.expectedSize,
    this.verified = false,
    this.channelName,
    this.updateInfo,
  });

  final String tagName;
  final bool portable;
  final String url;
  final String fileName;
  final String? sha256;
  final int? expectedSize;
  final bool verified;
  final String? channelName;
  final Map<String, dynamic>? updateInfo;

  Map<String, Object?> toJson() => {
    'tagName': tagName,
    'portable': portable,
    'url': url,
    'fileName': fileName,
    if (sha256 != null) 'sha256': sha256,
    if (expectedSize != null) 'expectedSize': expectedSize,
    if (verified) 'verified': true,
    if (channelName != null) 'channel': channelName,
    if (updateInfo != null) 'updateInfo': updateInfo,
  };

  UpdateDownloadRecord withNotice({
    required bool verified,
    required String channelName,
    required Map<String, dynamic> updateInfo,
  }) {
    return UpdateDownloadRecord(
      tagName: tagName,
      portable: portable,
      url: url,
      fileName: fileName,
      sha256: sha256,
      expectedSize: expectedSize,
      verified: verified,
      channelName: channelName,
      updateInfo: updateInfo,
    );
  }

  static UpdateDownloadRecord? tryParse(Object? value) {
    if (value is! Map) return null;
    final tagName = _recordString(value['tagName']);
    final url = _recordString(value['url']);
    final fileName = _recordString(value['fileName']);
    final portable = value['portable'];
    if (tagName == null ||
        url == null ||
        fileName == null ||
        portable is! bool ||
        !_isUpdatePayloadName(fileName)) {
      return null;
    }
    final sha256 = _recordString(value['sha256'])?.toLowerCase();
    if (sha256 != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      return null;
    }
    final expectedSize = value['expectedSize'];
    if (expectedSize != null && expectedSize is! int) return null;
    final updateInfoRaw = value['updateInfo'];
    Map<String, dynamic>? updateInfo;
    if (updateInfoRaw is Map) {
      updateInfo = Map<String, dynamic>.from(updateInfoRaw);
    }
    return UpdateDownloadRecord(
      tagName: tagName,
      portable: portable,
      url: url,
      fileName: fileName,
      sha256: sha256,
      expectedSize: expectedSize,
      verified: value['verified'] == true,
      channelName: _recordString(value['channel']),
      updateInfo: updateInfo,
    );
  }

  bool matches({
    required String tagName,
    required bool portable,
    required String url,
    required String fileName,
    required String? sha256,
    required int? expectedSize,
  }) {
    if (this.tagName != tagName ||
        this.portable != portable ||
        this.fileName != fileName) {
      return false;
    }
    // 不同线路的残余字节不能续接：代理、Gitee 与直连的主机必须一致。
    final savedHost = _recordUrlHost(this.url);
    final nextHost = _recordUrlHost(url);
    if (savedHost.isEmpty || nextHost.isEmpty || savedHost != nextHost) {
      return false;
    }
    if (expectedSize != null &&
        this.expectedSize != null &&
        this.expectedSize != expectedSize) {
      return false;
    }
    final nextSha = sha256?.trim().toLowerCase();
    final savedSha = this.sha256?.trim().toLowerCase();
    if (nextSha != null &&
        savedSha != null &&
        nextSha.isNotEmpty &&
        savedSha.isNotEmpty) {
      return nextSha == savedSha;
    }
    return this.url == url;
  }
}

bool shouldRemoveCachedUpdate(String cachedTag, String currentVersion) {
  return UpdateChecker.compareSemVer(cachedTag, currentVersion) <= 0;
}

bool _isUpdatePayloadName(String fileName) {
  if (fileName.isEmpty ||
      fileName == '.' ||
      fileName == '..' ||
      fileName == updateDownloadStateFileName) {
    return false;
  }
  return fileName == p.basename(fileName) &&
      !fileName.contains('/') &&
      !fileName.contains('\\');
}

String? _recordString(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

String _recordUrlHost(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri?.host.toLowerCase() ?? '';
}

String? updatePayloadPath(Directory directory, String fileName) {
  if (!_isUpdatePayloadName(fileName)) return null;
  final path = p.normalize(p.join(directory.path, fileName));
  if (!p.isWithin(p.normalize(directory.path), path)) return null;
  return path;
}

Future<void> cleanupCachedUpdateDownload({
  Directory? directory,
  String? currentVersion,
}) async {
  final dir =
      directory ??
      Directory(
        p.join((await getAppDataDir()).path, updateDownloadDirectoryName),
      );
  if (!await dir.exists()) return;
  final stateFile = File(p.join(dir.path, updateDownloadStateFileName));
  final record = await _readUpdateDownloadRecord(stateFile);
  if (record == null) {
    if (await stateFile.exists()) await _deleteUpdateFile(stateFile.path);
    return;
  }
  final version = currentVersion ?? AppSettings.version;
  if (!shouldRemoveCachedUpdate(record.tagName, version)) return;

  final again = await _readUpdateDownloadRecord(stateFile);
  if (again == null ||
      again.tagName != record.tagName ||
      again.fileName != record.fileName) {
    return;
  }
  final payload = updatePayloadPath(dir, again.fileName);
  if (payload != null) await _deleteUpdateFile(payload);
  if (payload != null && await File(payload).exists()) return;
  await _deleteUpdateFile(stateFile.path);
}

class VerifiedUpdateNotice {
  const VerifiedUpdateNotice({
    required this.info,
    required this.channel,
    required this.path,
  });

  final UpdateInfo info;
  final UpdateChannel channel;
  final String path;
}

Future<void> rememberVerifiedUpdatePackage({
  required String savePath,
  required UpdateInfo info,
  required UpdateChannel channel,
}) async {
  final stateFile = File(
    p.join(p.dirname(savePath), updateDownloadStateFileName),
  );
  final existing = await _readUpdateDownloadRecord(stateFile);
  if (existing == null) return;
  final next = existing.withNotice(
    verified: true,
    channelName: channel.name,
    updateInfo: info.toJson(),
  );
  await writeTextFileAtomically(stateFile.path, jsonEncode(next.toJson()));
}

Future<VerifiedUpdateNotice?> readVerifiedUpdateNotice({
  Directory? directory,
  String? currentVersion,
}) async {
  final dir =
      directory ??
      Directory(
        p.join((await getAppDataDir()).path, updateDownloadDirectoryName),
      );
  if (!await dir.exists()) return null;
  final record = await _readUpdateDownloadRecord(
    File(p.join(dir.path, updateDownloadStateFileName)),
  );
  final saved = record?.updateInfo;
  if (record == null || !record.verified || saved == null) return null;
  final version = currentVersion ?? AppSettings.version;
  if (shouldRemoveCachedUpdate(record.tagName, version)) return null;
  final payload = updatePayloadPath(dir, record.fileName);
  if (payload == null) return null;
  final file = File(payload);
  if (!await file.exists()) return null;
  if (record.expectedSize != null &&
      await file.length() != record.expectedSize) {
    return null;
  }
  final info = UpdateInfo.fromJson(saved);
  if (info.tagName.isEmpty) return null;
  return VerifiedUpdateNotice(
    info: info,
    // 历史下载记录统一按 GitHub 渠道处理。
    channel: UpdateChannel.supported,
    path: payload,
  );
}

Future<UpdateDownloadRecord?> _readUpdateDownloadRecord(File file) async {
  if (!await file.exists()) return null;
  try {
    return UpdateDownloadRecord.tryParse(jsonDecode(await file.readAsString()));
  } catch (_) {
    return null;
  }
}

Future<void> _deleteUpdateFile(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

class UpdateInstaller {
  UpdateInstaller._();

  static const _portableSupportDirectory = '.update';
  static const _installerHelperDirectory = 'tool';
  static const _installerHelperFileName = 'apply_installer_update.ps1';
  static const _installerUpdateLogFileName = 'installer_update.log';

  static Future<UpdateInstallOutcome> run({
    required UpdateInfo info,
    required UpdateChannel channel,
    required CancelToken cancelToken,
    required UpdateProgressCallback onProgress,
    required UpdatePhaseCallback onPhase,
  }) async {
    final savePath = await downloadVerified(
      info: info,
      channel: channel,
      cancelToken: cancelToken,
      onProgress: onProgress,
      onPhase: onPhase,
    );
    return installDownloaded(savePath: savePath, onPhase: onPhase);
  }

  /// 下载并按 version.json 的 SHA256 校验更新包。
  ///
  /// [channel] 仅保留调用方语义；实际下载线路由设置决定。
  static Future<String> downloadVerified({
    required UpdateInfo info,
    required UpdateChannel channel,
    required CancelToken cancelToken,
    required UpdateProgressCallback onProgress,
    required UpdatePhaseCallback onPhase,
  }) async {
    final candidates = updateDownloadCandidates(
      route: AppPreference.instance.updateDownloadRoute,
      directUrl: info.downloadUrl(
        channel: UpdateChannel.github,
        portableBuild: portableBuild,
      ),
      giteeUrl: info.downloadUrl(
        channel: UpdateChannel.gitee,
        portableBuild: portableBuild,
      ),
    );
    log.update.debug(
      'legacy',
      '[UpdateInstaller] 下载线路 '
      '${AppPreference.instance.updateDownloadRoute.name}',
      fields: {
        'channel': channel.name,
        'candidates': candidates.length,
      },
    );
    if (candidates.isEmpty) {
      throw UpdateInstallException('缺少下载地址');
    }
    ensureUpdateHasChecksum(
      info: info,
      channel: UpdateChannel.github,
      portableBuild: portableBuild,
    );

    // 校验值只取官方清单的 sha256（或官方源上的独立校验文件），与安装包
    // 下载线路无关；代理只传输安装包，不能改写这里的期望值。
    final expectedSha = await _resolveExpectedSha256ForDownload(
      info: info,
      portableBuild: portableBuild,
      cancelToken: cancelToken,
    );
    final expectedSize = info.downloadSize(portableBuild: portableBuild);

    try {
      final savePath = await runUpdateDownloadAttempts<String>(
        candidates: candidates,
        attempt: (candidate) => _downloadCandidate(
          candidate: candidate,
          tagName: info.tagName,
          expectedSha: expectedSha,
          expectedSize: expectedSize,
          cancelToken: cancelToken,
          onProgress: onProgress,
          onPhase: onPhase,
        ),
        onFailure: (failure) {
          log.update.warn(
            'legacy',
            '[UpdateInstaller] 下载线路失败：${failure.candidate.label} '
            '${failure.detail}',
            fields: {
              'source': failure.candidate.source.name,
              'host': failure.candidate.host,
              'reason': failure.reason.name,
              if (failure.statusCode != null) 'status': failure.statusCode,
            },
          );
        },
      );
      return savePath;
    } on UpdateDownloadAggregateException catch (error) {
      throw UpdateInstallException(error.message);
    }
  }

  /// 单条线路：下载、长度检查、SHA256 校验；任一步失败都只让该线路失败。
  static Future<String> _downloadCandidate({
    required UpdateDownloadCandidate candidate,
    required String tagName,
    required String expectedSha,
    required int? expectedSize,
    required CancelToken cancelToken,
    required UpdateProgressCallback onProgress,
    required UpdatePhaseCallback onPhase,
  }) async {
    try {
      if (!isAllowedUpdateDownloadUrlForRoute(candidate.url)) {
        throw const UpdateDownloadAttemptException(
          UpdateDownloadFailureReason.invalidUrl,
        );
      }
      final savePath = await _prepareResumeSave(
        tagName: tagName,
        url: candidate.url,
        sha256: expectedSha,
        expectedSize: expectedSize,
      );

      onPhase('正在下载');
      await _downloadResumable(
        url: candidate.url,
        savePath: savePath,
        expectedSize: expectedSize,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );

      final downloaded = File(savePath);
      final downloadedLength = await downloaded.exists()
          ? await downloaded.length()
          : 0;
      if (downloadedLength == 0) {
        await _discardDownloadedUpdate(savePath);
        throw const UpdateDownloadAttemptException(
          UpdateDownloadFailureReason.empty,
        );
      }
      if (expectedSize != null && downloadedLength > expectedSize) {
        await _discardDownloadedUpdate(savePath);
        throw const UpdateDownloadAttemptException(
          UpdateDownloadFailureReason.unknown,
        );
      }
      if (expectedSize != null && downloadedLength < expectedSize) {
        throw const UpdateDownloadAttemptException(
          UpdateDownloadFailureReason.incomplete,
        );
      }

      onPhase('正在校验');
      final ok = await _verifySha256(savePath, expectedSha);
      if (!ok) {
        await _discardDownloadedUpdate(savePath);
        log.update.warn(
          'legacy',
          '[UpdateInstaller] 线路 SHA256 校验不通过，标记为不可信：'
          '${candidate.label}',
          fields: {
            'source': candidate.source.name,
            'host': candidate.host,
            'sha256': expectedSha,
          },
        );
        throw const UpdateDownloadAttemptException(
          UpdateDownloadFailureReason.checksum,
        );
      }
      log.update.info(
        'legacy',
        '[UpdateInstaller] 线路 SHA256 校验通过：${candidate.label}',
        fields: {
          'source': candidate.source.name,
          'host': candidate.host,
        },
      );
      return savePath;
    } on UpdateDownloadAttemptException {
      rethrow;
    } on DioException catch (error) {
      throw UpdateDownloadAttemptException(
        _failureReasonForDio(error),
        statusCode: error.response?.statusCode,
        cause: error,
      );
    } on UpdateInstallException catch (error) {
      throw UpdateDownloadAttemptException(
        _failureReasonForInstallMessage(error.message),
        cause: error,
      );
    } on FileSystemException catch (error) {
      log.update.warn(
        'legacy',
        '[UpdateInstaller] 写入更新文件失败：${error.message}',
        fields: {
          'host': candidate.host,
          'path': error.path ?? '',
        },
        error: error,
      );
      throw UpdateDownloadAttemptException(
        UpdateDownloadFailureReason.disk,
        cause: error,
      );
    } catch (error) {
      log.update.warn(
        'legacy',
        '[UpdateInstaller] 下载线路异常：${error.runtimeType}',
        fields: {'host': candidate.host},
        error: error,
      );
      throw UpdateDownloadAttemptException(
        UpdateDownloadFailureReason.unknown,
        cause: error,
      );
    }
  }

  static UpdateDownloadFailureReason _failureReasonForDio(
    DioException error,
  ) {
    final type = error.type;
    if (type == DioExceptionType.connectionTimeout ||
        type == DioExceptionType.receiveTimeout ||
        type == DioExceptionType.sendTimeout) {
      return UpdateDownloadFailureReason.timeout;
    }
    if (type == DioExceptionType.cancel) {
      return UpdateDownloadFailureReason.cancelled;
    }
    if (type == DioExceptionType.badResponse) {
      final status = error.response?.statusCode;
      if (status == HttpStatus.notFound || status == HttpStatus.gone) {
        return UpdateDownloadFailureReason.notFound;
      }
      if (status != null && status >= 500) {
        return UpdateDownloadFailureReason.server;
      }
      return UpdateDownloadFailureReason.unknown;
    }
    return UpdateDownloadFailureReason.connection;
  }

  static UpdateDownloadFailureReason _failureReasonForInstallMessage(
    String message,
  ) {
    if (message.contains('校验')) return UpdateDownloadFailureReason.checksum;
    if (message.contains('路径非法') || message.contains('缺少下载地址')) {
      return UpdateDownloadFailureReason.invalidUrl;
    }
    if (message.contains('为空')) return UpdateDownloadFailureReason.empty;
    if (message.contains('未完成')) {
      return UpdateDownloadFailureReason.incomplete;
    }
    return UpdateDownloadFailureReason.unknown;
  }

  static Future<UpdateInstallOutcome> installDownloaded({
    required String savePath,
    required UpdatePhaseCallback onPhase,
  }) async {
    if (portableBuild) {
      return _startPortableUpdate(archivePath: savePath, onPhase: onPhase);
    }
    return _startInstallerUpdate(installerPath: savePath, onPhase: onPhase);
  }

  /// 安装版更新：助手等当前进程退出后再启动安装程序，保留交互式安装向导。
  /// 安装完成后由安装程序的 Run 段启动新版，这里不额外重启。
  static Future<UpdateInstallOutcome> _startInstallerUpdate({
    required String installerPath,
    required UpdatePhaseCallback onPhase,
  }) async {
    final appDir = p.dirname(Platform.resolvedExecutable);
    final helperSource = File(
      p.join(appDir, _installerHelperDirectory, _installerHelperFileName),
    );
    if (!await helperSource.exists()) {
      throw UpdateInstallException('更新组件缺失，请手动运行已下载的安装包');
    }

    Directory updateDirectory;
    try {
      updateDirectory = await _updateSupportDirectory();
    } catch (error, stackTrace) {
      log.update.warn(
        'legacy',
        '创建更新目录失败：$error',
        error: error,
        stackTrace: stackTrace,
      );
      throw UpdateInstallException('准备安装程序失败');
    }
    final logPath = p.join(updateDirectory.path, _installerUpdateLogFileName);

    onPhase('正在启动安装程序');
    final helperPath = p.join(
      updateDirectory.path,
      'pure_music_apply_installer_${DateTime.now().microsecondsSinceEpoch}.ps1',
    );
    try {
      await helperSource.copy(helperPath);
    } catch (error, stackTrace) {
      log.update.warn(
        'legacy',
        '复制安装助手失败：$error',
        error: error,
        stackTrace: stackTrace,
      );
      throw UpdateInstallException('准备安装程序失败');
    }

    Process process;
    try {
      process = await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          helperPath,
          '-InstallerPath',
          installerPath,
          '-TargetProcessId',
          '$pid',
          '-AppExe',
          Platform.resolvedExecutable,
          '-LogPath',
          logPath,
        ],
        workingDirectory: updateDirectory.path,
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      await _deleteQuietly(helperPath);
      throw UpdateInstallException('启动安装程序失败');
    }
    if (process.pid <= 0) {
      await _deleteQuietly(helperPath);
      throw UpdateInstallException('启动安装程序失败');
    }
    await WindowLifecycleService.instance.exitApp();
    return UpdateInstallOutcome.installerStarted;
  }

  static Future<UpdateInstallOutcome> _startPortableUpdate({
    required String archivePath,
    required UpdatePhaseCallback onPhase,
  }) async {
    final executablePath = Platform.resolvedExecutable;
    if (!Platform.isWindows ||
        p.basename(executablePath).toLowerCase() != 'pure_music.exe') {
      throw UpdateInstallException('当前运行环境不支持便携版应用内更新');
    }

    final previousAppDir = p.dirname(executablePath);
    final newAppDir = await _createPortableUpdateDirectory(previousAppDir);
    var helperStarted = false;
    String? helperPath;
    try {
      onPhase('正在解压更新');
      await extractFileToDisk(archivePath, newAppDir.path);
      onPhase('正在校验');
      await verifyExtractedPortablePackage(newAppDir.path);

      final newExecutable = File(p.join(newAppDir.path, 'pure_music.exe'));
      final migrationScript = File(
        p.join(
          newAppDir.path,
          _portableSupportDirectory,
          'upgrade_from_previous.ps1',
        ),
      );
      final applyScript = File(
        p.join(
          newAppDir.path,
          _portableSupportDirectory,
          'apply_portable_update.ps1',
        ),
      );
      if (!await newExecutable.exists() ||
          !await migrationScript.exists() ||
          !await applyScript.exists()) {
        throw UpdateInstallException('便携版更新包不完整');
      }

      final updateDirectory = await _updateSupportDirectory();
      helperPath = p.join(
        updateDirectory.path,
        'pure_music_apply_update_${DateTime.now().microsecondsSinceEpoch}.ps1',
      );
      await applyScript.copy(helperPath);

      onPhase('正在切换版本');
      final process = await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          helperPath,
          '-PreviousPath',
          previousAppDir,
          '-NewPath',
          newAppDir.path,
          '-ProcessId',
          '$pid',
        ],
        workingDirectory: updateDirectory.path,
        mode: ProcessStartMode.detached,
      );
      if (process.pid <= 0) {
        throw UpdateInstallException('启动便携版更新程序失败');
      }
      helperStarted = true;
      await _discardDownloadedUpdate(archivePath);
      await WindowLifecycleService.instance.exitApp();
      return UpdateInstallOutcome.portableStarted;
    } catch (error, stackTrace) {
      if (!helperStarted) {
        await _deleteDirectoryQuietly(newAppDir.path);
        if (helperPath != null) await _deleteQuietly(helperPath);
      }
      if (error is UpdateInstallException) {
        log.update.warn(
          'legacy',
          '便携版更新准备失败：${error.message}',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
      log.update.warn(
        'legacy',
        '便携版更新准备失败',
        error: error,
        stackTrace: stackTrace,
      );
      throw UpdateInstallException('准备便携版更新失败');
    }
  }

  /// 更新助手脚本所在目录：`<数据根>\updates`，与更新包下载目录一致。
  static Future<Directory> _updateSupportDirectory() async {
    final root = await getAppDataDir();
    return Directory(
      p.join(root.path, updateDownloadDirectoryName),
    ).create(recursive: true);
  }

  static Future<Directory> _createPortableUpdateDirectory(
    String previousAppDir,
  ) async {
    final parent = Directory(p.dirname(previousAppDir));
    await parent.create(recursive: true);
    for (var attempt = 0; attempt < 5; attempt++) {
      final candidate = Directory(
        p.join(
          parent.path,
          '.pure_music_update_${DateTime.now().microsecondsSinceEpoch}_$attempt',
        ),
      );
      if (await candidate.exists()) continue;
      await candidate.create(recursive: true);
      return candidate;
    }
    throw UpdateInstallException('无法创建便携版更新目录');
  }

  static Future<String> _resolveExpectedSha256({
    required UpdateInfo info,
    required UpdateChannel channel,
    required bool portableBuild,
    required CancelToken cancelToken,
  }) async {
    ensureUpdateHasChecksum(
      info: info,
      channel: channel,
      portableBuild: portableBuild,
    );

    final direct = info.sha256(portableBuild: portableBuild)?.trim();
    if (direct != null && direct.isNotEmpty) {
      if (!_isSha256(direct)) {
        throw UpdateInstallException('更新校验值无效');
      }
      return direct.toLowerCase();
    }

    final checksumUrl = info.checksumUrl(
      channel: channel,
      portableBuild: portableBuild,
    );
    if (checksumUrl == null || checksumUrl.isEmpty) {
      throw UpdateInstallException('缺少更新校验信息，已停止安装');
    }
    if (!isAllowedUpdateDownloadUrl(checksumUrl, channel)) {
      throw UpdateInstallException('校验地址不可信');
    }

    try {
      final response = await AppHttp.instance.dio.get<String>(
        checksumUrl,
        cancelToken: cancelToken,
        options: Options(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          responseType: ResponseType.plain,
        ),
      );
      final match = RegExp(
        r'\b([0-9a-fA-F]{64})\b',
      ).firstMatch(response.data ?? '');
      final hash = match?.group(1);
      if (hash == null) {
        throw UpdateInstallException('更新校验值无效');
      }
      return hash.toLowerCase();
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        throw UpdateInstallException('无法获取更新校验值');
      }
      rethrow;
    } on UpdateInstallException {
      rethrow;
    } catch (_) {
      throw UpdateInstallException('获取更新校验值失败');
    }
  }

  /// 校验值的获取与下载线路无关；网络与读取异常统一转为可展示的安装错误。
  static Future<String> _resolveExpectedSha256ForDownload({
    required UpdateInfo info,
    required bool portableBuild,
    required CancelToken cancelToken,
  }) async {
    try {
      final sha = await _resolveExpectedSha256(
        info: info,
        channel: UpdateChannel.github,
        portableBuild: portableBuild,
        cancelToken: cancelToken,
      );
      return sha;
    } on UpdateInstallException {
      rethrow;
    } on DioException catch (error) {
      log.update.warn(
        'legacy',
        '[UpdateInstaller] 获取更新校验值失败：${error.type.name}',
        fields: {'status': error.response?.statusCode ?? 0},
        error: error,
      );
      throw UpdateInstallException('获取更新校验值失败');
    } catch (error) {
      log.update.warn(
        'legacy',
        '[UpdateInstaller] 读取更新校验值异常：${error.runtimeType}',
        error: error,
      );
      throw UpdateInstallException('获取更新校验值失败');
    }
  }

  static bool _isSha256(String value) =>
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);

  static Future<bool> _verifySha256(String path, String expected) async {
    final file = File(path);
    if (!await file.exists()) return false;
    final digest = await sha256.bind(file.openRead()).first;
    final actual = digest.toString().toLowerCase();
    final target = expected.trim().toLowerCase();
    log.update.info('legacy', '[UpdateInstaller] sha256 match=${actual == target}');
    return actual == target;
  }

  static Future<String> _prepareResumeSave({
    required String tagName,
    required String url,
    required String sha256,
    required int? expectedSize,
  }) async {
    final dir = Directory(
      p.join((await getAppDataDir()).path, updateDownloadDirectoryName),
    );
    await dir.create(recursive: true);
    final fileName = _fileNameFromUrl(url);
    final savePath = updatePayloadPath(dir, fileName);
    if (savePath == null) throw UpdateInstallException('下载路径非法');

    final stateFile = File(p.join(dir.path, updateDownloadStateFileName));
    final existing = await _readUpdateDownloadRecord(stateFile);
    final record = UpdateDownloadRecord(
      tagName: tagName,
      portable: portableBuild,
      url: url,
      fileName: fileName,
      sha256: sha256.toLowerCase(),
      expectedSize: expectedSize,
    );
    final file = File(savePath);
    final reusable =
        existing != null &&
        existing.matches(
          tagName: tagName,
          portable: portableBuild,
          url: url,
          fileName: fileName,
          sha256: sha256,
          expectedSize: expectedSize,
        );
    if (!reusable) {
      if (existing != null) {
        final oldPath = updatePayloadPath(dir, existing.fileName);
        if (oldPath != null) await _deleteQuietly(oldPath);
      }
      if (await file.exists()) await _deleteQuietly(savePath);
    } else if (await file.exists()) {
      final length = await file.length();
      if (expectedSize != null && length > expectedSize) {
        await _deleteQuietly(savePath);
      }
    }
    await writeTextFileAtomically(stateFile.path, jsonEncode(record.toJson()));
    return savePath;
  }

  static Future<void> _downloadResumable({
    required String url,
    required String savePath,
    required int? expectedSize,
    required CancelToken cancelToken,
    required UpdateProgressCallback onProgress,
  }) async {
    final file = File(savePath);
    var startAt = await file.exists() ? await file.length() : 0;
    if (expectedSize != null && startAt > expectedSize) {
      await _deleteQuietly(savePath);
      startAt = 0;
    }
    if (expectedSize != null && startAt == expectedSize && startAt > 0) {
      onProgress(startAt, expectedSize);
      return;
    }
    if (startAt > 0) {
      log.update.info('legacy', '[UpdateInstaller] resume bytes=$startAt');
      onProgress(startAt, expectedSize ?? 0);
    }

    var useRange = startAt > 0;
    for (var attempt = 0; attempt < 2; attempt++) {
      final restart = await _transferUpdate(
        url: url,
        savePath: savePath,
        existingBytes: useRange ? startAt : 0,
        expectedSize: expectedSize,
        useRange: useRange,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
      if (!restart) return;
      await _deleteQuietly(savePath);
      startAt = 0;
      useRange = false;
    }
    throw UpdateInstallException('下载失败');
  }

  static Future<bool> _transferUpdate({
    required String url,
    required String savePath,
    required int existingBytes,
    required int? expectedSize,
    required bool useRange,
    required CancelToken cancelToken,
    required UpdateProgressCallback onProgress,
  }) async {
    final response = await AppHttp.instance.dio.get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        maxRedirects: 5,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(minutes: 5),
        headers: {
          'User-Agent': 'Pure-Music-Updater',
          if (useRange && existingBytes > 0) 'Range': 'bytes=$existingBytes-',
        },
        validateStatus: (code) =>
            code == HttpStatus.ok ||
            code == HttpStatus.partialContent ||
            code == HttpStatus.requestedRangeNotSatisfiable,
      ),
    );
    final stream = response.data?.stream;
    final status = response.statusCode ?? 0;
    final range = parseContentRange(
      response.headers.value(HttpHeaders.contentRangeHeader),
    );
    final action = decideUpdateResumeAction(
      statusCode: status,
      existingBytes: existingBytes,
      contentRangeStart: range?.start,
      expectedSize: expectedSize,
    );
    if (action == UpdateResumeAction.alreadyComplete) {
      if (stream != null) await stream.drain<void>();
      onProgress(existingBytes, expectedSize ?? existingBytes);
      return false;
    }
    if (action == UpdateResumeAction.restart) {
      if (stream != null) await stream.drain<void>();
      return true;
    }
    final contentType =
        response.headers.value(Headers.contentTypeHeader)?.toLowerCase() ?? '';
    if (contentType.startsWith('text/')) {
      if (stream != null) await stream.drain<void>();
      throw UpdateInstallException('下载失败');
    }

    final contentLength = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    final total = updateDownloadTotal(
      action: action,
      existingBytes: action == UpdateResumeAction.append ? existingBytes : 0,
      contentRangeTotal: range?.total,
      contentLength: contentLength,
      expectedSize: expectedSize,
    );
    if (stream == null) throw UpdateInstallException('下载失败');
    final base = action == UpdateResumeAction.append ? existingBytes : 0;
    var received = base;
    final handle = await File(savePath).open(
      mode: action == UpdateResumeAction.append
          ? FileMode.append
          : FileMode.write,
    );
    try {
      await for (final chunk in stream) {
        await handle.writeFrom(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
    } finally {
      await handle.close();
    }
    return false;
  }

  static Future<void> _discardDownloadedUpdate(String savePath) async {
    await _deleteQuietly(savePath);
    try {
      if (await File(savePath).exists()) return;
    } on FileSystemException {
      // 无法确认删除结果时保留下载记录，避免下次续传错位。
      return;
    }
    await _deleteQuietly(
      p.join(p.dirname(savePath), updateDownloadStateFileName),
    );
  }

  static String _fileNameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    final segment = uri?.pathSegments.isNotEmpty == true
        ? uri!.pathSegments.last
        : '';
    final name = p.basename(segment);
    if (name.isEmpty || name == '.' || name == '..') {
      return 'pure_music_update.bin';
    }
    return name;
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static Future<void> _deleteDirectoryQuietly(String path) async {
    try {
      final directory = Directory(path);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {}
  }
}
