import 'dart:async';

import 'package:flutter/widgets.dart';

/// 只有主窗口可见且未最小化时才持续绘制。
bool windowRenderShouldEnableFrames({
  required bool trayHidden,
  bool windowMinimized = false,
}) => !trayHidden && !windowMinimized;

bool shouldAcceptLyricUiUpdate({required bool windowFramesEnabled}) =>
    windowFramesEnabled;

/// 窗口被挡住太久时连歌词、封面、进度这些 ticker 一起停；
/// 最小化/托盘由 framesEnabled 负责，调整窗口大小由 resizing 负责，
/// 被遮挡闲时由 backgroundIdle 负责。
bool windowTickersEnabled({
  required bool resizing,
  required bool framesEnabled,
  required bool backgroundIdle,
}) => !resizing && framesEnabled && !backgroundIdle;

/// 恢复窗口的回调排队期间窗口可能再次最小化，只有仍属于同一次恢复
/// 才允许把窗口状态改回非最小化。
bool windowRestoreStillCurrent({
  required int scheduledEpoch,
  required int currentEpoch,
}) => scheduledEpoch == currentEpoch;

void applyWindowSchedulerFrames(bool enabled) {
  final binding = WidgetsBinding.instance;
  final next = enabled ? AppLifecycleState.resumed : AppLifecycleState.hidden;
  if (binding.lifecycleState == next) return;
  // ignore: invalid_use_of_protected_member
  binding.handleAppLifecycleStateChanged(next);
}

class WindowRenderGate with WidgetsBindingObserver {
  WindowRenderGate({void Function(bool enabled)? applyFramesEnabled})
    : _applyFramesEnabled = applyFramesEnabled ?? applyWindowSchedulerFrames;

  static final instance = WindowRenderGate();

  final void Function(bool enabled) _applyFramesEnabled;
  final ValueNotifier<bool> framesEnabled = ValueNotifier(true);
  final ValueNotifier<bool> backgroundIdle = ValueNotifier(false);

  bool _trayHidden = false;
  bool _windowMinimized = false;
  bool _schedulerFramesEnabled = true;
  bool _pauseScheduled = false;
  bool _attached = false;
  bool _windowFocused = true;
  Timer? _backgroundIdleTimer;

  static const _backgroundIdleDelay = Duration(seconds: 30);

  bool get shouldRender => windowRenderShouldEnableFrames(
    trayHidden: _trayHidden,
    windowMinimized: _windowMinimized,
  );

  void attach() {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    _backgroundIdleTimer?.cancel();
    _backgroundIdleTimer = null;
    _windowFocused = true;
    if (backgroundIdle.value) backgroundIdle.value = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  /// 仅由隐藏到托盘 / 重新显示主窗口调用。
  void setTrayHidden(bool hidden) {
    if (_trayHidden == hidden) return;
    _trayHidden = hidden;
    _syncBackgroundIdle();
    _sync();
  }

  void setWindowMinimized(bool minimized) {
    if (_windowMinimized == minimized) return;
    _windowMinimized = minimized;
    _syncBackgroundIdle();
    _sync();
  }

  /// 主窗口只要还在桌面上，就必须回到前台。
  void enterForeground() {
    final changed = _trayHidden || _windowMinimized;
    if (!changed) return;
    _trayHidden = false;
    _windowMinimized = false;
    _syncBackgroundIdle();
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _setWindowFocused(true);
        // 藏进托盘后不能把系统焦点当成「窗口回来了」
        if (!_trayHidden) enterForeground();
        break;
      case AppLifecycleState.inactive:
        _setWindowFocused(false);
        // 藏进托盘后不能把系统焦点当成「窗口回来了」
        if (!_trayHidden) enterForeground();
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _setWindowFocused(false);
        break;
    }
  }

  void _setWindowFocused(bool focused) {
    if (_windowFocused == focused) return;
    _windowFocused = focused;
    _syncBackgroundIdle();
  }

  /// 窗口失焦且仍停留在桌面（未最小化、未藏托盘）超过 30 秒后进入闲时档，
  /// 连歌词、封面、进度这些 ticker 一起停；回到前台或窗口被隐藏时立即复位。
  /// 该门闩由 inactive 生命周期驱动，被遮挡但仍可见时不会触发。
  void _syncBackgroundIdle() {
    final shouldCount =
        !_windowFocused && !_trayHidden && !_windowMinimized;
    if (!shouldCount) {
      _backgroundIdleTimer?.cancel();
      _backgroundIdleTimer = null;
      if (backgroundIdle.value) backgroundIdle.value = false;
      return;
    }
    if (_backgroundIdleTimer != null || backgroundIdle.value) return;
    _backgroundIdleTimer = Timer(_backgroundIdleDelay, () {
      _backgroundIdleTimer = null;
      if (_windowFocused || _trayHidden || _windowMinimized) return;
      backgroundIdle.value = true;
    });
  }

  void _sync() {
    final enabled = shouldRender;
    if (enabled) {
      _pauseScheduled = false;
      if (!_schedulerFramesEnabled) {
        _applyFramesEnabled(true);
        _schedulerFramesEnabled = true;
      }
      if (!framesEnabled.value) {
        framesEnabled.value = true;
      }
      return;
    }

    if (framesEnabled.value) {
      framesEnabled.value = false;
    }
    // 任务栏最小化只停视觉 ticker，不改变 Flutter 生命周期；音频、媒体会话和
    // 其他依赖生命周期的后台工作仍保持运行。隐藏到托盘才暂停 scheduler。
    if (!_trayHidden || !_schedulerFramesEnabled || _pauseScheduled) return;
    _pauseScheduled = true;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      _pauseScheduled = false;
      if (shouldRender || !_schedulerFramesEnabled) return;
      _applyFramesEnabled(false);
      _schedulerFramesEnabled = false;
    });
    if (!binding.hasScheduledFrame) {
      binding.scheduleFrame();
    }
  }

  Future<void> waitForWarmup({
    Duration timeout = const Duration(milliseconds: 64),
  }) async {
    if (!shouldRender) return;
    final binding = WidgetsBinding.instance;
    binding.scheduleWarmUpFrame();
    try {
      await binding.endOfFrame.timeout(timeout);
    } on TimeoutException {
      return;
    }
  }
}
