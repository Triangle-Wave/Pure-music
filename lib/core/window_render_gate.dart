import 'dart:async';

import 'package:flutter/widgets.dart';

/// 只有主窗口可见且未最小化时才持续绘制。
bool windowRenderShouldEnableFrames({
  required bool trayHidden,
  bool windowMinimized = false,
}) => !trayHidden && !windowMinimized;

bool shouldAcceptLyricUiUpdate({required bool windowFramesEnabled}) =>
    windowFramesEnabled;

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

  bool _trayHidden = false;
  bool _windowMinimized = false;
  bool _schedulerFramesEnabled = true;
  bool _pauseScheduled = false;
  bool _attached = false;

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
    WidgetsBinding.instance.removeObserver(this);
  }

  /// 仅由隐藏到托盘 / 重新显示主窗口调用。
  void setTrayHidden(bool hidden) {
    if (_trayHidden == hidden) return;
    _trayHidden = hidden;
    _sync();
  }

  void setWindowMinimized(bool minimized) {
    if (_windowMinimized == minimized) return;
    _windowMinimized = minimized;
    _sync();
  }

  /// 主窗口只要还在桌面上，就必须回到前台。
  void enterForeground() {
    final changed = _trayHidden || _windowMinimized;
    if (!changed) return;
    _trayHidden = false;
    _windowMinimized = false;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        // 藏进托盘后不能把系统焦点当成「窗口回来了」
        if (_trayHidden) return;
        enterForeground();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        break;
    }
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
