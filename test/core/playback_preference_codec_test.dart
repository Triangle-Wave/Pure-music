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

  test('SACD PCM 设置缺省为 PCM 44.1kHz 24bit', () {
    final preference = PlaybackPreferenceCodec.decode(
      const <String, dynamic>{},
    );
    expect(
      preference.dsdPlaybackMode,
      PlaybackPreference.dsdPlaybackModePcm,
    );
    expect(preference.sacdPcmSampleRate, 44100);
    expect(preference.sacdPcmBitDepth, 24);

    final encoded = PlaybackPreferenceCodec.encode(preference);
    expect(encoded['dsdPlaybackMode'], 'pcm');
    expect(encoded['sacdPcmSampleRate'], 44100);
    expect(encoded['sacdPcmBitDepth'], 24);
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

  test('SACD PCM 设置非法值回退缺省值', () {
    final preference = PlaybackPreferenceCodec.decode({
      'dsdPlaybackMode': 'unknown',
      'sacdPcmSampleRate': 32000,
      'sacdPcmBitDepth': 32,
    });
    expect(
      preference.dsdPlaybackMode,
      PlaybackPreference.dsdPlaybackModePcm,
    );
    expect(preference.sacdPcmSampleRate, 44100);
    expect(preference.sacdPcmBitDepth, 24);
  });
}
