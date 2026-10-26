import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/preference.dart';

void main() {
  test('codec preserves protected audio preference fields', () {
    final preference = PlaybackPreferenceCodec.decode({
      'playMode': 'PlayMode.forward',
      'volumeDsp': 0.8,
      'eqGains': List<double>.filled(10, 1.5),
      'eqEnabled': false,
      'replayGainEnabled': true,
      'replayGainMode': 'album',
      'skipLeadingSilence': true,
      'transitionMode': 'smart',
      'transitionFadeOutMs': 900,
      'transitionFadeInMs': 700,
    });

    expect(preference.eqEnabled, isFalse);
    expect(preference.replayGainEnabled, isTrue);
    expect(preference.replayGainMode, ReplayGainMode.album);
    expect(preference.skipLeadingSilence, isTrue);
    expect(preference.transitionMode, TransitionMode.smart);
    expect(preference.transitionFadeOutMs, 900);
    expect(preference.transitionFadeInMs, 700);
    expect(
      PlaybackPreferenceCodec.encode(preference)['transitionMode'],
      'smart',
    );
  });

  test('missing replayGainMode defaults to track', () {
    final preference = PlaybackPreferenceCodec.decode({
      'replayGainEnabled': true,
    });
    expect(preference.replayGainMode, ReplayGainMode.track);
    expect(
      PlaybackPreferenceCodec.encode(preference)['replayGainMode'],
      'track',
    );
  });

  test('DSD 播放模式缺省为 DSF 直解', () {
    final preference = PlaybackPreferenceCodec.decode(
      const <String, dynamic>{},
    );
    expect(
      preference.dsdPlaybackMode,
      PlaybackPreference.dsdPlaybackModeDsf,
    );
    expect(preference.dsdPlaybackModeMigratedToDsf, isTrue);
    expect(preference.sacdPcmSampleRate, 44100);
    expect(preference.sacdPcmBitDepth, 24);

    final encoded = PlaybackPreferenceCodec.encode(preference);
    expect(encoded['dsdPlaybackMode'], 'dsf');
    expect(encoded['dsdPlaybackModeMigratedToDsf'], isTrue);
    expect(encoded['sacdPcmSampleRate'], 44100);
    expect(encoded['sacdPcmBitDepth'], 24);
  });

  test('旧配置的默认 PCM 模式一次性迁移到 DSF', () {
    final preference = PlaybackPreferenceCodec.decode({
      'dsdPlaybackMode': 'pcm',
      'sacdPcmSampleRate': 96000,
      'sacdPcmBitDepth': 24,
    });

    expect(
      preference.dsdPlaybackMode,
      PlaybackPreference.dsdPlaybackModeDsf,
    );
    expect(preference.dsdPlaybackModeMigratedToDsf, isTrue);
    expect(
      PlaybackPreferenceCodec.encode(preference)['dsdPlaybackMode'],
      'dsf',
    );
  });

  test('迁移后手动选择的 PCM 模式保持不被改回', () {
    final preference = PlaybackPreferenceCodec.decode({
      'dsdPlaybackMode': 'pcm',
      'dsdPlaybackModeMigratedToDsf': true,
    });

    expect(
      preference.dsdPlaybackMode,
      PlaybackPreference.dsdPlaybackModePcm,
    );
    final encoded = PlaybackPreferenceCodec.encode(preference);
    expect(encoded['dsdPlaybackMode'], 'pcm');
    expect(encoded['dsdPlaybackModeMigratedToDsf'], isTrue);
  });

  test('SACD PCM 设置按受支持取值读取', () {
    final preference = PlaybackPreferenceCodec.decode({
      'dsdPlaybackMode': 'DSF',
      'sacdPcmSampleRate': 96000,
      'sacdPcmBitDepth': 16,
    });
    expect(
      preference.dsdPlaybackMode,
      PlaybackPreference.dsdPlaybackModeDsf,
    );
    expect(preference.sacdPcmSampleRate, 96000);
    expect(preference.sacdPcmBitDepth, 16);
  });

  test('SACD PCM 设置支持 192000Hz 往返', () {
    final preference = PlaybackPreferenceCodec.decode({
      'sacdPcmSampleRate': 192000,
      'sacdPcmBitDepth': 24,
    });
    expect(preference.sacdPcmSampleRate, 192000);
    expect(preference.sacdPcmBitDepth, 24);

    final encoded = PlaybackPreferenceCodec.encode(preference);
    expect(encoded['sacdPcmSampleRate'], 192000);
    expect(encoded['sacdPcmBitDepth'], 24);
  });

  test('SACD PCM 设置非法值回退缺省值', () {
    final preference = PlaybackPreferenceCodec.decode({
      'dsdPlaybackMode': 'unknown',
      'sacdPcmSampleRate': 32000,
      'sacdPcmBitDepth': 32,
    });
    expect(
      preference.dsdPlaybackMode,
      PlaybackPreference.dsdPlaybackModeDsf,
    );
    expect(preference.sacdPcmSampleRate, 44100);
    expect(preference.sacdPcmBitDepth, 24);
  });
}
