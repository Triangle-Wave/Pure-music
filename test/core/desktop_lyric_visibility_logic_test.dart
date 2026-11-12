import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/desktop_lyric_visibility_logic.dart';

void main() {
  group('desktopLyricShouldShow', () {
    test('前台窗口是主窗口时隐藏歌词，渲染门闩未同步也按前台处理', () {
      expect(
        desktopLyricShouldShow(
          windowMinimized: true,
          trayHidden: true,
          foregroundHwnd: 42,
          mainHwnd: 42,
        ),
        isFalse,
      );
    });

    test('前台窗口是其它窗口时显示歌词', () {
      expect(
        desktopLyricShouldShow(
          windowMinimized: false,
          trayHidden: false,
          foregroundHwnd: 99,
          mainHwnd: 42,
        ),
        isTrue,
      );
    });

    test('GetForegroundWindow 返回 0 时显示歌词', () {
      expect(
        desktopLyricShouldShow(
          windowMinimized: false,
          trayHidden: false,
          foregroundHwnd: 0,
          mainHwnd: 42,
        ),
        isTrue,
      );
    });

    test('主窗口句柄未就绪时显示歌词', () {
      expect(
        desktopLyricShouldShow(
          windowMinimized: false,
          trayHidden: false,
          foregroundHwnd: 99,
          mainHwnd: null,
        ),
        isTrue,
      );
    });

    test('主窗口句柄非正时显示歌词', () {
      expect(
        desktopLyricShouldShow(
          windowMinimized: false,
          trayHidden: false,
          foregroundHwnd: 99,
          mainHwnd: 0,
        ),
        isTrue,
      );
    });

    test('主窗口最小化时显示歌词', () {
      expect(
        desktopLyricShouldShow(
          windowMinimized: true,
          trayHidden: false,
          foregroundHwnd: 99,
          mainHwnd: 42,
        ),
        isTrue,
      );
    });

    test('主窗口隐藏到托盘时显示歌词', () {
      expect(
        desktopLyricShouldShow(
          windowMinimized: false,
          trayHidden: true,
          foregroundHwnd: 99,
          mainHwnd: 42,
        ),
        isTrue,
      );
    });
  });

  group('DesktopLyricVisibilityLogic', () {
    test('首次判定入队即写入去重基准，重复判定不再下发', () {
      final logic = DesktopLyricVisibilityLogic();
      logic.onLyricStarted();

      expect(logic.decideApply(false), isFalse);
      expect(logic.pendingVisible, isFalse);
      expect(logic.decideApply(false), isNull);
    });

    test('下发成功后保留去重基准并更新自动隐藏状态', () {
      final logic = DesktopLyricVisibilityLogic();
      logic.onLyricStarted();
      logic.decideApply(false);

      logic.onApplyResult(visible: false, succeeded: true);

      expect(logic.pendingVisible, isFalse);
      expect(logic.autoHidden, isTrue);
      expect(logic.decideApply(false), isNull);
    });

    test('下发失败后回滚去重基准以允许重试', () {
      final logic = DesktopLyricVisibilityLogic();
      logic.onLyricStarted();
      logic.decideApply(false);

      logic.onApplyResult(visible: false, succeeded: false);

      expect(logic.pendingVisible, isNull);
      expect(logic.decideApply(false), isFalse);
    });

    test('关闭跟随后的恢复失败保留重试，成功后停止下发', () {
      final logic = DesktopLyricVisibilityLogic();
      logic.onLyricStarted();
      logic.decideApply(false);
      logic.onApplyResult(visible: false, succeeded: true);

      expect(logic.setFollowEnabled(false), isFalse);
      expect(logic.restorePending, isTrue);
      expect(logic.needsRetry, isTrue);

      expect(logic.decideApply(true), isTrue);
      logic.onApplyResult(visible: true, succeeded: false);
      expect(logic.restorePending, isTrue);
      expect(logic.pendingVisible, isNull);

      expect(logic.decideApply(true), isTrue);
      logic.onApplyResult(visible: true, succeeded: true);
      expect(logic.restorePending, isFalse);
      expect(logic.needsRetry, isFalse);
      expect(logic.decideApply(true), isNull);
    });

    test('移出下发在途时关闭跟随仍保留恢复待办', () {
      final logic = DesktopLyricVisibilityLogic();
      logic.onLyricStarted();
      logic.decideApply(false);

      expect(logic.setFollowEnabled(false), isFalse);
      expect(logic.restorePending, isTrue);
      expect(logic.decideApply(true), isTrue);
    });

    test('由关变开返回 true，幂等调用返回 false', () {
      final logic = DesktopLyricVisibilityLogic(followEnabled: false);
      logic.onLyricStarted();

      expect(logic.setFollowEnabled(false), isFalse);
      expect(logic.setFollowEnabled(true), isTrue);
      expect(logic.followEnabled, isTrue);
      expect(logic.setFollowEnabled(true), isFalse);
      expect(logic.restorePending, isFalse);
    });

    test('隐藏成功后恢复下发失败，关闭跟随仍需恢复窗口', () {
      final logic = DesktopLyricVisibilityLogic();
      logic.onLyricStarted();
      logic.decideApply(false);
      logic.onApplyResult(visible: false, succeeded: true);
      logic.decideApply(true);
      logic.onApplyResult(visible: true, succeeded: false);

      expect(logic.autoHidden, isTrue);
      expect(logic.pendingVisible, isNull);

      expect(logic.setFollowEnabled(false), isFalse);
      expect(logic.restorePending, isTrue);
      expect(logic.decideApply(true), isTrue);
    });

    test('重复设置相同跟随值不重置去重基准', () {
      final logic = DesktopLyricVisibilityLogic();
      logic.onLyricStarted();
      logic.decideApply(false);

      expect(logic.setFollowEnabled(true), isFalse);
      expect(logic.pendingVisible, isFalse);
      expect(logic.decideApply(false), isNull);
    });

    test('进程停止后不再下发，状态复位', () {
      final logic = DesktopLyricVisibilityLogic();
      logic.onLyricStarted();
      logic.decideApply(false);

      logic.onLyricStopped();

      expect(logic.lyricRunning, isFalse);
      expect(logic.pendingVisible, isNull);
      expect(logic.autoHidden, isFalse);
      expect(logic.decideApply(false), isNull);
    });

    test('dispose 后不再下发且无待办', () {
      final logic = DesktopLyricVisibilityLogic();
      logic.onLyricStarted();

      logic.dispose();

      expect(logic.decideApply(false), isNull);
      expect(logic.needsRetry, isFalse);
    });

    test('恢复连续失败达上限后停止下发，开关变化重启恢复', () {
      final logic = DesktopLyricVisibilityLogic();
      logic.onLyricStarted();
      logic.decideApply(false);
      logic.onApplyResult(visible: false, succeeded: true);

      expect(logic.setFollowEnabled(false), isFalse);
      expect(logic.restorePending, isTrue);
      expect(logic.canRetryRestore, isTrue);
      expect(logic.needsRetry, isTrue);

      for (var i = 0;
          i < DesktopLyricVisibilityLogic.maxRestoreAttempts;
          i++) {
        expect(logic.decideApply(true), isTrue);
        logic.onApplyResult(visible: true, succeeded: false);
      }

      expect(
        logic.restoreFailures,
        DesktopLyricVisibilityLogic.maxRestoreAttempts,
      );
      expect(logic.restoreExhausted, isTrue);
      expect(logic.canRetryRestore, isFalse);
      expect(logic.needsRetry, isFalse);
      expect(logic.decideApply(true), isNull);

      logic.setFollowEnabled(true);
      logic.setFollowEnabled(false);

      expect(logic.restoreFailures, 0);
      expect(logic.canRetryRestore, isTrue);
      expect(logic.decideApply(true), isTrue);
    });
  });
}
