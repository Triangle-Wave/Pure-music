import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/equalizer_action_state.dart';

void main() {
  test('keeps positive preamp gain above unity output volume', () {
    expect(
      eqOutputVolume(volumeDsp: 1.0, totalDb: 6.0),
      closeTo(eqDbToLinear(6.0), 0.0001),
    );
    expect(eqOutputVolume(volumeDsp: 1.0, totalDb: 6.0), greaterThan(1.0));
    expect(eqOutputVolume(volumeDsp: 1.0, totalDb: 24.0), eqOutputVolumeMax);
  });

  test('migrates legacy 80/100 Hz bands onto ISO 31/62 Hz', () {
    final migrated = migrateEqGains([
      6,
      4,
      2,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ], fromVersion: legacyEqBandModelVersion);

    expect(migrated[0], closeTo(6, 0.0001));
    expect(migrated[1], closeTo(6, 0.0001));
    expect(migrated[2], closeTo(2, 0.0001));
    expect(
      migrateEqGains(migrated, fromVersion: currentEqBandModelVersion),
      migrated,
    );
  });

  test('estimates stacked peak gain instead of a single band maximum', () {
    final stacked = estimateEqPeakGainDb([6, 6, 6, 0, 0, 0, 0, 0, 0, 0]);

    expect(stacked, greaterThan(6));
    expect(
      computeEqAutoGainDb(
        eqEnabled: true,
        gains: [6, 6, 6, 0, 0, 0, 0, 0, 0, 0],
        preampDb: 0,
        autoHeadroomDb: 1,
      ),
      closeTo((-stacked - 1).clamp(eqAutoGainMinDb, 0.0), 0.0001),
    );
    expect(
      computeEqAutoGainDb(
        eqEnabled: false,
        gains: [6, 6, 6, 0, 0, 0, 0, 0, 0, 0],
        preampDb: 6,
        autoHeadroomDb: 1,
      ),
      0,
    );
  });

  test('auto gain also protects a positive preamp on a flat EQ', () {
    expect(
      computeEqAutoGainDb(
        eqEnabled: true,
        gains: List.filled(eqBandCount, 0.0),
        preampDb: 6.0,
        autoHeadroomDb: 1.0,
      ),
      -7.0,
    );
  });

  test('converts peak Q into DX8 semitone bandwidth', () {
    expect(eqDx8BandwidthSemitonesFromQ(eqBandQ), closeTo(12, 0.2));
    expect(eqDx8CenterHz(31), eqDx8CenterMinHz);
    expect(eqDx8CenterHz(62), eqDx8CenterMinHz);
    expect(eqDx8CenterHz(1000), 1000);
    expect(eqDx8CenterForSampleRate(16000, 44100), closeTo(14700, 0.0001));
  });

  test('keeps peak estimate on the reduced log grid', () {
    expect(
      estimateEqPeakGainDb(List.filled(eqBandCount, 0.0)),
      closeTo(0.0, 0.0001),
    );
    final singleLowBand = estimateEqPeakGainDb([
      15.0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
    expect(singleLowBand, greaterThan(14.0));
    expect(singleLowBand, lessThanOrEqualTo(15.5));
    final singleHighBand = estimateEqPeakGainDb(
      const <double>[0, 0, 0, 0, 0, 0, 0, 0, 0, 12.0],
      sampleRate: 44100,
    );
    expect(singleHighBand, greaterThan(10.0));
  });
}
