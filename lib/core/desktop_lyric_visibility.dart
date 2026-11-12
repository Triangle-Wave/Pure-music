import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:pure_music/core/desktop_lyric_visibility_logic.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/window_render_gate.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:window_manager/window_manager.dart';

typedef _GetForegroundWindowNative = IntPtr Function();
typedef _GetForegroundWindowDart = int Function();

_GetForegroundWindowDart? _getForegroundWindow;

void _ensureForegroundWindowFn() {
  if (_getForegroundWindow != null || !Platform.isWindows) return;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    _getForegroundWindow = user32
        .lookupFunction<_GetForegroundWindowNative, _GetForegroundWindowDart>(
          'GetForegroundWindow',
        );
  } catch (error, trace) {
    _getForegroundWindow = null;
    log.desktopLyric.warn(
      'legacy',
      '[desktop lyric] GetForegroundWindow lookup failed: $error',
      stackTrace: trace,
    );
  }
}

int _foregroundHwnd() {
  _ensureForegroundWindowFn();
  final fn = _getForegroundWindow;
  if (fn == null) return 0;
  try {
    return fn();
  } catch (error, trace) {
    log.desktopLyric.warn(
      'legacy',
      '[desktop lyric] GetForegroundWindow call failed: $error',
      stackTrace: trace,
    );
    return 0;
  }
}

/// 按主窗口是否在前台驱动桌面歌词窗口的显隐。
class DesktopLyricVisibility {
  DesktopLyricVisibility._();

  static final instance = DesktopLyricVisibility._();

  static const _pollInterval = Duration(milliseconds: 500);
  static const _startupRetryInterval = Duration(milliseconds: 200);
  static const _startupMaxAttempts = 10;

  final DesktopLyricVisibilityLogic _logic = DesktopLyricVisibilityLogic();

  Timer? _pollTimer;
  Timer? _startupTimer;
  int _startupAttempts = 0;
  int? _mainHwnd;
  Future<void>? _hwndResolution;
  Future<void> _applyChain = Future<void>.value();
  bool _restoreExhaustedLogged = false;

  /// 主窗口最小化、隐藏到托盘或不在前台时显示桌面歌词。
  bool get shouldShowLyric => _computeShouldShowLyric();

  /// 等待主窗口句柄解析完成，供开启歌词后的即时判定使用。
  Future<void> waitForMainHwnd() => _ensureMainHwnd();

  bool _computeShouldShowLyric() {
    final gate = WindowRenderGate.instance;
    return desktopLyricShouldShow(
      windowMinimized: gate.isWindowMinimized,
      trayHidden: gate.isTrayHidden,
      foregroundHwnd: _foregroundHwnd(),
      mainHwnd: _mainHwnd,
    );
  }

  /// 后台解析主窗口句柄；并发调用共享同一个在途 Future。
  /// 句柄缓存后直接返回已完成的 Future，解析失败时下次调用重试。
  Future<void> _ensureMainHwnd() {
    final pending = _hwndResolution;
    if (pending != null) return pending;
    if (_mainHwnd != null || _logic.disposed) return Future<void>.value();
    final Future<void> future = _resolveMainHwnd();
    _hwndResolution = future;
    return future;
  }

  Future<void> _resolveMainHwnd() async {
    try {
      _mainHwnd = await windowManager.getId();
    } catch (error, trace) {
      _mainHwnd = null;
      log.desktopLyric.warn(
        'legacy',
        '[desktop lyric] windowManager.getId failed: $error',
        stackTrace: trace,
      );
    } finally {
      _hwndResolution = null;
      if (!_logic.disposed && _mainHwnd != null) {
        try {
          _evaluateAndApply();
        } catch (error, trace) {
          log.desktopLyric.warn(
            'legacy',
            '[desktop lyric] visibility refresh after hwnd resolution failed: '
                '$error',
            stackTrace: trace,
          );
        }
      }
    }
  }

  /// 窗口事件、托盘切换与跟随开关变化后重新判定。
  void refresh() {
    if (_logic.disposed) return;
    try {
      unawaited(_ensureMainHwnd());
      _evaluateAndApply();
    } catch (error, trace) {
      log.desktopLyric.warn(
        'legacy',
        '[desktop lyric] visibility refresh failed: $error',
        stackTrace: trace,
      );
    }
  }

  /// 歌词进程启动后进入跟随状态。
  void onLyricStarted() {
    if (_logic.disposed) return;
    try {
      _logic.onLyricStarted();
      unawaited(_ensureMainHwnd());
      _evaluateAndApply();
      // 进程刚启动时歌词窗口可能尚未创建，补一次窗口就绪补偿。
      if (_logic.followEnabled && _startupTimer == null) {
        _startStartupCompensation();
      }
    } catch (error, trace) {
      log.desktopLyric.warn(
        'legacy',
        '[desktop lyric] entering follow state failed: $error',
        stackTrace: trace,
      );
    }
  }

  /// 歌词进程结束（手动关闭、意外退出、应用退出）后停止跟随，不下发窗口恢复。
  void onLyricStopped() {
    if (_logic.disposed) return;
    try {
      _logic.onLyricStopped();
      _stopStartupCompensation();
      _syncPolling(enabled: false);
    } catch (error, trace) {
      log.desktopLyric.warn(
        'legacy',
        '[desktop lyric] leaving follow state failed: $error',
        stackTrace: trace,
      );
    }
  }

  void _evaluateAndApply() {
    if (_logic.disposed) return;
    // 同步跟随开关；由关变开时补一次窗口就绪补偿。
    final turnedOn = _logic.setFollowEnabled(
      AppSettings.instance.desktopFollowWindow,
    );
    if (turnedOn) {
      _startStartupCompensation();
    } else if (!_logic.followEnabled) {
      _stopStartupCompensation();
    }
    // 恢复耗尽状态回落时复位汇总告警标记，供新的恢复周期重新告警。
    if (!_logic.restoreExhausted) _restoreExhaustedLogged = false;
    // 跟随开启或恢复仍可重试时保持轮询；恢复连续失败达上限后停止。
    _syncPolling(enabled: _logic.needsRetry);

    final bool shouldShow;
    try {
      shouldShow = _computeShouldShowLyric();
    } catch (error, trace) {
      log.desktopLyric.warn(
        'legacy',
        '[desktop lyric] computing visibility failed: $error',
        stackTrace: trace,
      );
      return;
    }

    final visible = _logic.decideApply(shouldShow);
    if (visible != null) _enqueueApply(visible);
  }

  /// 串行下发一次显隐；去重基准在 [DesktopLyricVisibilityLogic.decideApply]
  /// 入队时即写入，结果经 [_handleApplyResult] 回传给状态机，
  /// 成功保留、失败回滚，等待下一次判定重试。
  void _enqueueApply(bool visible) {
    final Future<void> next = _applyChain
        .then<void>((_) async {
          final succeeded = await _applyVisible(visible);
          _handleApplyResult(visible: visible, succeeded: succeeded);
        })
        .catchError((Object error) {
          log.desktopLyric.warn(
            'legacy',
            '[desktop lyric] visibility apply chain failed: $error',
          );
          _handleApplyResult(visible: visible, succeeded: false);
        });
    _applyChain = next;
  }

  /// 回传下发结果；恢复连续失败达上限时停止轮询并给出一条汇总告警。
  void _handleApplyResult({
    required bool visible,
    required bool succeeded,
  }) {
    _logic.onApplyResult(visible: visible, succeeded: succeeded);
    if (!_logic.restoreExhausted || _restoreExhaustedLogged) return;
    _restoreExhaustedLogged = true;
    _syncPolling(enabled: false);
    log.desktopLyric.warn(
      'legacy',
      '[desktop lyric] restore visibility exhausted after '
          '${DesktopLyricVisibilityLogic.maxRestoreAttempts} attempts, '
          'stopping retries',
    );
  }

  /// 下发一次显隐；返回通道是否成功（窗口已就绪）。
  Future<bool> _applyVisible(bool visible) async {
    if (_logic.disposed) return false;
    final service = PlayService.existingDesktopLyricService;
    if (service == null || !service.isRunning) return false;
    try {
      await service.setWindowVisible(visible);
      return service.lastSetVisibleSucceeded;
    } catch (error, trace) {
      log.desktopLyric.warn(
        'legacy',
        '[desktop lyric] apply visibility($visible) failed: $error',
        stackTrace: trace,
      );
      return false;
    }
  }

  /// 进程启动后按 200ms 间隔重试首次判定，覆盖歌词窗口创建延迟。
  void _startStartupCompensation() {
    _stopStartupCompensation();
    _startupAttempts = 0;
    _startupTimer = Timer.periodic(_startupRetryInterval, (timer) {
      if (_logic.disposed) {
        timer.cancel();
        _startupTimer = null;
        return;
      }
      _startupAttempts++;
      final service = PlayService.existingDesktopLyricService;
      if (service != null && service.lastSetVisibleSucceeded) {
        timer.cancel();
        _startupTimer = null;
        return;
      }
      try {
        // decideApply 内部按入队即写的去重基准判定，失败的回滚会自动重试。
        _evaluateAndApply();
      } catch (error, trace) {
        log.desktopLyric.warn(
          'legacy',
          '[desktop lyric] startup visibility attempt failed: $error',
          stackTrace: trace,
        );
      }
      if (_startupAttempts >= _startupMaxAttempts) {
        timer.cancel();
        _startupTimer = null;
        // 窗口在补偿期后才创建时，交给下一次轮询继续尝试。
        log.desktopLyric.warn(
          'legacy',
          '[desktop lyric] startup visibility compensation exhausted, '
              'waiting for next poll',
        );
      }
    });
  }

  void _stopStartupCompensation() {
    _startupTimer?.cancel();
    _startupTimer = null;
    _startupAttempts = 0;
  }

  void _syncPolling({required bool enabled}) {
    if (enabled) {
      if (_pollTimer != null) return;
      _pollTimer = Timer.periodic(_pollInterval, (_) {
        if (_logic.disposed) return;
        try {
          _evaluateAndApply();
        } catch (error, trace) {
          log.desktopLyric.warn(
            'legacy',
            '[desktop lyric] visibility poll failed: $error',
            stackTrace: trace,
          );
        }
      });
      return;
    }
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// 应用退出时停止定时器，不下发窗口恢复。
  void dispose() {
    _logic.dispose();
    _stopStartupCompensation();
    _syncPolling(enabled: false);
  }
}
