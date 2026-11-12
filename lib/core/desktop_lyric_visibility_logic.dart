/// 桌面歌词跟随显隐的纯判定与状态决策，不依赖 FFI、单例、定时器与平台通道。

/// 主窗口不在前台或不可见时显示桌面歌词。
///
/// 主窗口句柄确认为前台窗口时按「主窗口可见」处理，覆盖窗口恢复、
/// 从托盘显示时渲染门闩状态尚未同步的瞬间；其余情况以渲染门闩与
/// GetForegroundWindow 的结果为准。
bool desktopLyricShouldShow({
  required bool windowMinimized,
  required bool trayHidden,
  required int foregroundHwnd,
  required int? mainHwnd,
}) {
  final hwnd = mainHwnd;
  if (hwnd != null && hwnd > 0 && foregroundHwnd == hwnd) {
    return false;
  }
  if (windowMinimized || trayHidden) return true;
  // GetForegroundWindow 返回 0 或主窗口句柄未就绪时按不可见处理，显示歌词。
  if (foregroundHwnd == 0) return true;
  if (hwnd == null || hwnd <= 0) return true;
  return foregroundHwnd != hwnd;
}

/// 显隐下发的状态机：去重基准、自动隐藏状态与关闭跟随后的恢复重试。
///
/// 判定结果由 [decideApply] 返回，调用方负责下发并把结果回传给
/// [onApplyResult]；本类不执行任何 I/O。
class DesktopLyricVisibilityLogic {
  DesktopLyricVisibilityLogic({bool followEnabled = true})
    : followEnabled = followEnabled;

  /// 关闭跟随后的恢复下发允许连续失败的次数；通道不可用时据此停止重试。
  static const int maxRestoreAttempts = 10;

  bool followEnabled;
  bool lyricRunning = false;
  bool disposed = false;
  bool autoHidden = false;

  /// 去重基准：入队下发时写入，下发成功后保留，失败后回滚为 null。
  bool? pendingVisible;

  /// 关闭跟随时需要把窗口移回原位且尚未成功。
  bool restorePending = false;

  /// 恢复下发连续失败次数；任一下发成功后清零。
  int restoreFailures = 0;

  /// 恢复待办仍可继续下发。
  bool get canRetryRestore =>
      restorePending && restoreFailures < maxRestoreAttempts;

  /// 恢复待办连续失败已达上限，停止重试。
  bool get restoreExhausted =>
      !disposed &&
      lyricRunning &&
      restorePending &&
      restoreFailures >= maxRestoreAttempts;

  /// 保持显隐轮询的单一口径：跟随开启，或恢复待办仍可重试。
  bool get needsRetry =>
      lyricRunning && !disposed && (followEnabled || canRetryRestore);

  void onLyricStarted() {
    lyricRunning = true;
    pendingVisible = null;
    autoHidden = false;
    restorePending = false;
    restoreFailures = 0;
  }

  void onLyricStopped() {
    lyricRunning = false;
    pendingVisible = null;
    autoHidden = false;
    restorePending = false;
    restoreFailures = 0;
  }

  /// 跟随开关变化；返回是否由关变开，用于启动窗口就绪补偿。
  /// 值未变化时不动去重基准，保证「检查-执行」原子性不受重复刷新影响。
  bool setFollowEnabled(bool enabled) {
    if (followEnabled == enabled) return false;
    final turnedOn = !followEnabled && enabled;
    followEnabled = enabled;
    // 窗口已移出或隐藏下发在途时，关闭跟随都要把窗口移回原位。
    if (!enabled && lyricRunning && (autoHidden || pendingVisible == false)) {
      restorePending = true;
    }
    // 开关变化开启新的恢复周期，重新计数。
    restoreFailures = 0;
    // 开关变化后重新判定，不再沿用上一次的去重基准。
    pendingVisible = null;
    return turnedOn;
  }

  /// 返回本次需要下发的 visible；null 表示无需下发。
  /// 入队时同步写入 [pendingVisible]，保证检查与执行之间的去重原子性。
  bool? decideApply(bool shouldShow) {
    if (disposed) return null;
    if (!followEnabled) {
      // 关闭跟随：歌词常显，仅在窗口曾被移出且连续失败未达上限时下发移回原位。
      if (!lyricRunning || !restorePending || !canRetryRestore) return null;
      if (pendingVisible == true) return null;
      pendingVisible = true;
      return true;
    }
    if (!lyricRunning) return null;
    if (pendingVisible == shouldShow) return null;
    pendingVisible = shouldShow;
    return shouldShow;
  }

  /// 下发结果回传：成功 finalize 去重基准并清零连续失败，失败回滚以允许重试。
  void onApplyResult({required bool visible, required bool succeeded}) {
    if (disposed) return;
    if (succeeded) {
      autoHidden = !visible;
      if (!followEnabled && visible) restorePending = false;
      restoreFailures = 0;
      return;
    }
    // 关闭跟随期间的恢复下发失败计入连续失败次数。
    if (!followEnabled && visible && restorePending) restoreFailures++;
    if (pendingVisible == visible) pendingVisible = null;
  }

  void dispose() {
    disposed = true;
    lyricRunning = false;
    pendingVisible = null;
    restorePending = false;
    restoreFailures = 0;
  }
}
