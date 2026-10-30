import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/preference.dart';

void main() {
  test('audio output uses defaults when keys are missing', () {
    final preference = PlaybackPreferenceCodec.decode(null);

    expect(
      preference.activeOutputDeviceId,
      PlaybackPreference.defaultOutputDeviceId,
    );
    expect(preference.activeOutputDeviceName, '');
    expect(
      preference.sharedOutputDeviceId,
      PlaybackPreference.defaultOutputDeviceId,
    );
    expect(
      preference.wasapiOutputDeviceId,
      PlaybackPreference.defaultOutputDeviceId,
    );
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

    expect(preference.wasapiOutputDeviceId, 3);
    expect(preference.wasapiOutputDeviceName, 'Speakers (Realtek)');
    expect(
      preference.sharedOutputDeviceId,
      PlaybackPreference.defaultOutputDeviceId,
    );
    expect(preference.sharedOutputDeviceName, '');
    expect(preference.outputMode, PlaybackPreference.outputModeExclusive);
    expect(preference.outputSampleRate, 96000);
    expect(preference.outputFormat, PlaybackPreference.outputFormatPcm24);

    final encoded = PlaybackPreferenceCodec.encode(preference);
    expect(encoded['wasapiOutputDeviceId'], 3);
    expect(encoded['outputDeviceId'], 3);
    expect(encoded['outputDeviceName'], 'Speakers (Realtek)');
    expect(encoded['outputMode'], 'exclusive');
    expect(encoded['outputSampleRate'], 96000);
    expect(encoded['outputFormat'], 'pcm24');
  });

  test('legacy shared config migrates into the shared slot', () {
    final preference = PlaybackPreferenceCodec.decode({
      'outputDeviceId': 2,
      'outputDeviceName': 'Speakers',
      'outputMode': 'shared',
    });

    expect(preference.sharedOutputDeviceId, 2);
    expect(preference.sharedOutputDeviceName, 'Speakers');
    expect(
      preference.wasapiOutputDeviceId,
      PlaybackPreference.defaultOutputDeviceId,
    );
    expect(preference.wasapiOutputDeviceName, '');
  });

  test('per-mode devices round-trip independently', () {
    final preference = PlaybackPreferenceCodec.decode({
      'outputMode': 'exclusive',
      'sharedOutputDeviceId': 1,
      'sharedOutputDeviceName': 'Speakers',
      'wasapiOutputDeviceId': 4,
      'wasapiOutputDeviceName': 'USB DAC',
      'outputDeviceId': 1,
      'outputDeviceName': 'Speakers',
    });

    expect(preference.sharedOutputDeviceId, 1);
    expect(preference.wasapiOutputDeviceId, 4);
    expect(preference.activeOutputDeviceId, 4);
    expect(preference.outputDeviceIdFor(false), 1);
    expect(preference.outputDeviceNameFor(true), 'USB DAC');

    final encoded = PlaybackPreferenceCodec.encode(preference);
    expect(encoded['sharedOutputDeviceId'], 1);
    expect(encoded['wasapiOutputDeviceId'], 4);
    expect(encoded['outputDeviceId'], 4);
    expect(encoded['outputDeviceName'], 'USB DAC');
  });

  test('switching mode writes only the current mode slot', () {
    final preference = PlaybackPreferenceCodec.decode({});
    preference.setOutputDeviceForMode(false, 2, 'Speakers');
    preference.setOutputDeviceForMode(true, 5, 'USB DAC');

    // 当前仍为共享模式，读到共享槽的 2；写入独占槽的 5 不污染当前模式。
    expect(preference.activeOutputDeviceId, 2);
    expect(preference.activeOutputDeviceName, 'Speakers');
    expect(preference.wasapiOutputDeviceId, 5);
    preference.outputMode = PlaybackPreference.outputModeExclusive;
    expect(preference.activeOutputDeviceId, 5);
    expect(preference.activeOutputDeviceName, 'USB DAC');

    final encoded = PlaybackPreferenceCodec.encode(preference);
    expect(encoded['outputDeviceId'], 5);
    expect(encoded['sharedOutputDeviceId'], 2);
  });

  test('audio output rejects invalid values', () {
    final preference = PlaybackPreferenceCodec.decode({
      'outputDeviceId': 'not-a-device',
      'outputMode': 'unknown-mode',
      'outputSampleRate': 12345,
      'outputFormat': 'dsd',
    });

    expect(
      preference.activeOutputDeviceId,
      PlaybackPreference.defaultOutputDeviceId,
    );
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
