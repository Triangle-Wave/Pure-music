import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/update_checker.dart';
import 'package:pure_music/core/update_installer.dart';

enum UpdateMonitorPhase {
  idle,
  downloading,
  verifying,
  preparing,
  installing,
  ready,
  failed,
}

/// 更新下载不跟窗口走。窗口收起后，进度留在标题栏。
class UpdateDownloadMonitor extends ChangeNotifier {
  UpdateDownloadMonitor._();

  static final UpdateDownloadMonitor instance = UpdateDownloadMonitor._();

  UpdateMonitorPhase _phase = UpdateMonitorPhase.idle;
  UpdateInfo? _info;
  UpdateChannel? _channel;
  int _received = 0;
  int _total = 0;
  String? _errorMessage;
  String? _savePath;
  CancelToken? _token;
  var _generation = 0;
  var _dialogCount = 0;
  var _cancelRequested = false;

  UpdateMonitorPhase get phase => _phase;
  UpdateInfo? get info => _info;
  UpdateChannel? get channel => _channel;
  int get received => _received;
  int get total => _total;
  String? get errorMessage => _errorMessage;
  bool get dialogOpen => _dialogCount > 0;
  bool get visible => _phase != UpdateMonitorPhase.idle;
  bool get canCancel => _phase == UpdateMonitorPhase.downloading;

  bool get foreground => _dialogCount > 0;

  String get titleLabel {
    switch (_phase) {
      case UpdateMonitorPhase.idle:
        return '';
      case UpdateMonitorPhase.downloading:
        if (_total > 0) {
          final percent = ((_received / _total) * 100).clamp(0, 100).round();
          return '正在下载更新 $percent%';
        }
        return '正在下载更新';
      case UpdateMonitorPhase.verifying:
        return '正在校验更新';
      case UpdateMonitorPhase.preparing:
      case UpdateMonitorPhase.installing:
        return '正在安装更新';
      case UpdateMonitorPhase.ready:
        return '更新已下载，点击安装';
      case UpdateMonitorPhase.failed:
        return '更新下载失败';
    }
  }

  void noteDialogOpened() {
    _dialogCount += 1;
  }

  void noteDialogClosed() {
    if (_dialogCount > 0) _dialogCount -= 1;
  }

  Future<void> restoreReadyNotice() async {
    if (_phase != UpdateMonitorPhase.idle) return;
    final notice = await readVerifiedUpdateNotice();
    if (notice == null || _phase != UpdateMonitorPhase.idle) return;
    _info = notice.info;
    _channel = notice.channel;
    _savePath = notice.path;
    _phase = UpdateMonitorPhase.ready;
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> startDownload(UpdateInfo info, UpdateChannel channel) async {
    if (_phase == UpdateMonitorPhase.downloading ||
        _phase == UpdateMonitorPhase.verifying ||
        _phase == UpdateMonitorPhase.preparing ||
        _phase == UpdateMonitorPhase.installing) {
      return;
    }
    final generation = ++_generation;
    final token = CancelToken();
    _token?.cancel();
    _token = token;
    _cancelRequested = false;
    _info = info;
    _channel = channel;
    _savePath = null;
    _received = 0;
    _total = info.downloadSize(portableBuild: portableBuild) ?? 0;
    _errorMessage = null;
    _phase = UpdateMonitorPhase.downloading;
    notifyListeners();

    try {
      final savePath = await UpdateInstaller.downloadVerified(
        info: info,
        channel: channel,
        cancelToken: token,
        onProgress: (received, total) {
          if (generation != _generation) return;
          _received = received;
          if (total > 0) _total = total;
          // 切换下载线路会重新进入下载阶段，进度要跟着回到下载状态。
          if (_phase != UpdateMonitorPhase.preparing &&
              _phase != UpdateMonitorPhase.installing) {
            _phase = UpdateMonitorPhase.downloading;
          }
          notifyListeners();
        },
        onPhase: (phase) {
          if (generation != _generation) return;
          if (phase == '正在校验') _phase = UpdateMonitorPhase.verifying;
          notifyListeners();
        },
      );
      if (generation != _generation) return;
      if (_cancelRequested || token.isCancelled) {
        _clearToIdle(notify: true);
        return;
      }
      _savePath = savePath;
      await rememberVerifiedUpdatePackage(
        savePath: savePath,
        info: info,
        channel: channel,
      );
      if (generation != _generation) return;
      _phase = UpdateMonitorPhase.ready;
      _errorMessage = null;
      notifyListeners();
      if (foreground && !_cancelRequested) {
        await install();
      }
    } on DioException catch (error) {
      if (generation != _generation) return;
      if (error.type == DioExceptionType.cancel ||
          _cancelRequested ||
          token.isCancelled) {
        _clearToIdle(notify: true);
        return;
      }
      _fail(error.message ?? '更新失败');
    } on UpdateInstallException catch (error) {
      if (generation != _generation) return;
      if (_cancelRequested || token.isCancelled) {
        _clearToIdle(notify: true);
        return;
      }
      _fail(error.message);
    } catch (_) {
      if (generation != _generation) return;
      if (_cancelRequested || token.isCancelled) {
        _clearToIdle(notify: true);
        return;
      }
      _fail('更新失败');
    }
  }

  Future<void> install() async {
    final savePath = _savePath;
    if (savePath == null || _phase != UpdateMonitorPhase.ready) return;
    final generation = _generation;
    _phase = UpdateMonitorPhase.installing;
    _errorMessage = null;
    notifyListeners();
    try {
      await UpdateInstaller.installDownloaded(
        savePath: savePath,
        onPhase: (phase) {
          if (generation != _generation) return;
          _phase = phase == '正在解压更新'
              ? UpdateMonitorPhase.preparing
              : UpdateMonitorPhase.installing;
          notifyListeners();
        },
      );
    } on UpdateInstallException catch (error) {
      if (generation != _generation) return;
      _fail(error.message);
    } catch (_) {
      if (generation != _generation) return;
      _fail('更新失败');
    }
  }

  void cancel() {
    if (_phase != UpdateMonitorPhase.downloading &&
        _phase != UpdateMonitorPhase.verifying) {
      return;
    }
    _cancelRequested = true;
    final token = _token;
    if (token != null && !token.isCancelled) {
      token.cancel();
      return;
    }
    _clearToIdle(notify: true);
  }

  void _fail(String message) {
    _phase = UpdateMonitorPhase.failed;
    _errorMessage = message;
    _token = null;
    notifyListeners();
  }

  void _clearToIdle({required bool notify}) {
    _generation += 1;
    _phase = UpdateMonitorPhase.idle;
    _info = null;
    _channel = null;
    _received = 0;
    _total = 0;
    _errorMessage = null;
    _savePath = null;
    _token = null;
    _cancelRequested = false;
    if (notify) notifyListeners();
  }

  @visibleForTesting
  void preview({
    required UpdateMonitorPhase phase,
    UpdateInfo? info,
    UpdateChannel? channel,
    int received = 0,
    int total = 0,
    String? errorMessage,
    String? savePath,
  }) {
    _phase = phase;
    _info = info;
    _channel = channel;
    _received = received;
    _total = total;
    _errorMessage = errorMessage;
    _savePath = savePath;
    notifyListeners();
  }

  @visibleForTesting
  void reset() {
    _token?.cancel();
    _clearToIdle(notify: false);
    _dialogCount = 0;
    notifyListeners();
  }
}
