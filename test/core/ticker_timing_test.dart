import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/ticker_timing.dart';

void main() {
  group('tickerModeResumed', () {
    test('只在关闭恢复到开启时为 true', () {
      expect(tickerModeResumed(previousEnabled: false, enabled: true), isTrue);
      expect(tickerModeResumed(previousEnabled: null, enabled: true), isFalse);
      expect(tickerModeResumed(previousEnabled: true, enabled: true), isFalse);
      expect(tickerModeResumed(previousEnabled: true, enabled: false), isFalse);
    });
  });

  group('tickerFrameDelta', () {
    test('首帧只建立基准', () {
      expect(
        tickerFrameDelta(null, const Duration(seconds: 5)),
        Duration.zero,
      );
    });

    test('正常帧推进实际间隔', () {
      expect(
        tickerFrameDelta(
          const Duration(milliseconds: 100),
          const Duration(milliseconds: 133),
        ),
        const Duration(milliseconds: 33),
      );
    });

    test('静音恢复或长时间挂起只校准不推进', () {
      expect(
        tickerFrameDelta(
          const Duration(seconds: 1),
          const Duration(seconds: 30),
        ),
        Duration.zero,
      );
    });

    test('时间回退不推进', () {
      expect(
        tickerFrameDelta(
          const Duration(seconds: 2),
          const Duration(seconds: 1),
        ),
        Duration.zero,
      );
    });
  });
}
