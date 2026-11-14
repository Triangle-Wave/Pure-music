import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/preference.dart';

void main() {
  group('SleepTimerAction', () {
    test('按名称与枚举前缀解析', () {
      expect(SleepTimerAction.fromString('pause'), SleepTimerAction.pause);
      expect(SleepTimerAction.fromString('stop'), SleepTimerAction.stop);
      expect(SleepTimerAction.fromString('quit'), SleepTimerAction.quit);
      expect(
        SleepTimerAction.fromString('SleepTimerAction.stop'),
        SleepTimerAction.stop,
      );
      expect(SleepTimerAction.fromString('  QUIT  '), SleepTimerAction.quit);
    });

    test('未知名称返回 null', () {
      expect(SleepTimerAction.fromString(''), isNull);
      expect(SleepTimerAction.fromString('unknown'), isNull);
      expect(SleepTimerAction.fromString('SleepTimerAction.play'), isNull);
    });
  });

  group('PlaybackPreference sleepTimerAction', () {
    test('缺省为 pause', () {
      final preference = PlaybackPreferenceCodec.decode(null);
      expect(preference.sleepTimerAction, SleepTimerAction.pause);
      expect(
        PlaybackPreferenceCodec.encode(preference)['sleepTimerAction'],
        'pause',
      );
    });

    test('三态往返', () {
      for (final action in SleepTimerAction.values) {
        final preference = PlaybackPreferenceCodec.decode({
          'sleepTimerAction': action.name,
        });
        expect(preference.sleepTimerAction, action);
        expect(
          PlaybackPreferenceCodec.encode(preference)['sleepTimerAction'],
          action.name,
        );
      }
    });

    test('枚举前缀保留、非法值回落到 pause', () {
      final prefixed = PlaybackPreferenceCodec.decode({
        'sleepTimerAction': 'SleepTimerAction.quit',
      });
      expect(prefixed.sleepTimerAction, SleepTimerAction.quit);

      final nonString = PlaybackPreferenceCodec.decode({
        'sleepTimerAction': 123,
      });
      expect(nonString.sleepTimerAction, SleepTimerAction.pause);

      final unknown = PlaybackPreferenceCodec.decode({
        'sleepTimerAction': 'shutdown',
      });
      expect(unknown.sleepTimerAction, SleepTimerAction.pause);
    });

    test('其它播放偏好键不受影响', () {
      final preference = PlaybackPreferenceCodec.decode({
        'transitionFadeOutMs': 900,
        'sleepTimerAction': 'stop',
      });
      expect(preference.transitionFadeOutMs, 900);
      expect(preference.sleepTimerAction, SleepTimerAction.stop);
    });
  });
}
