import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/preference.dart';

void main() {
  test('audio output uses defaults when keys are missing', () {
    final preference = PlaybackPreferenceCodec.decode(null);

    expect(preference.outputDeviceId, PlaybackPreference.defaultOutputDeviceId);
    expect(preference.outputDeviceName, '');
    expect(preference.outputMode, PlaybackPreference.outputModeShared);
    expect(preference.outputSampleRate, 0);
    expect(preference.outputFormat, PlaybackPreference.outputFormatFloat32);
  });

  test('audio output round-trips supported values', () {
    final preference = PlaybackPreferenceCodec.decode({
      'outputDeviceId': 3,
      'outputDeviceName': 'Speakers (Realtek)',
      'outputMode': 'exclusive',
      'outputSampleRate': 96000,
      'outputFormat': 'pcm24',
    });

    expect(preference.outputDeviceId, 3);
    expect(preference.outputDeviceName, 'Speakers (Realtek)');
    expect(preference.outputMode, PlaybackPreference.outputModeExclusive);
    expect(preference.outputSampleRate, 96000);
    expect(preference.outputFormat, PlaybackPreference.outputFormatPcm24);

    final encoded = PlaybackPreferenceCodec.encode(preference);
    expect(encoded['outputDeviceId'], 3);
    expect(encoded['outputDeviceName'], 'Speakers (Realtek)');
    expect(encoded['outputMode'], 'exclusive');
    expect(encoded['outputSampleRate'], 96000);
    expect(encoded['outputFormat'], 'pcm24');
  });

  test('audio output rejects invalid values', () {
    final preference = PlaybackPreferenceCodec.decode({
      'outputDeviceId': 'not-a-device',
      'outputMode': 'unknown-mode',
      'outputSampleRate': 12345,
      'outputFormat': 'dsd',
    });

    expect(preference.outputDeviceId, PlaybackPreference.defaultOutputDeviceId);
    expect(preference.outputMode, PlaybackPreference.outputModeShared);
    expect(preference.outputSampleRate, 0);
    expect(preference.outputFormat, PlaybackPreference.outputFormatFloat32);
  });

  test('existing PCM cache and DSD keys keep their semantics', () {
    final preference = PlaybackPreferenceCodec.decode({
      'dsdPlaybackMode': 'dsf',
      'sacdPcmSampleRate': 88200,
      'sacdPcmBitDepth': 16,
    });

    expect(preference.dsdPlaybackMode, PlaybackPreference.dsdPlaybackModeDsf);
    expect(preference.sacdPcmSampleRate, 88200);
    expect(preference.sacdPcmBitDepth, 16);
  });
}
