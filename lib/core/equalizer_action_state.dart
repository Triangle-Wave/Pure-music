import 'dart:math' as math;

final _eqPresetNameWhitespacePattern = RegExp(r'\s+');
const int eqBandCount = 10;
const int legacyEqBandModelVersion = 1;
const int currentEqBandModelVersion = 2;
const double eqGainMinDb = -15.0;
const double eqGainMaxDb = 15.0;
const double eqPreampMinDb = -24.0;
const double eqPreampMaxDb = 24.0;
const double eqAutoGainMinDb = -48.0;
const double eqBandBandwidthOctaves = 1.0;
const double eqBandQ = 1.414;
const double eqOutputVolumeMax = 8.0;
const double eqDx8CenterMinHz = 80.0;
const double eqDx8CenterMaxHz = 16000.0;

const List<double> eqBandFrequenciesHz = [
  31.0,
  62.0,
  125.0,
  250.0,
  500.0,
  1000.0,
  2000.0,
  4000.0,
  8000.0,
  16000.0,
];

const List<String> eqBandLabels = [
  '31',
  '62',
  '125',
  '250',
  '500',
  '1k',
  '2k',
  '4k',
  '8k',
  '16k',
];

const List<double> _legacyEqBandFrequenciesHz = [
  80.0,
  100.0,
  125.0,
  250.0,
  500.0,
  1000.0,
  2000.0,
  4000.0,
  8000.0,
  16000.0,
];

String normalizedEqPresetName(String value) {
  return value.trim().replaceAll(_eqPresetNameWhitespacePattern, ' ');
}

String eqPresetNameKey(String value) =>
    normalizedEqPresetName(value).toLowerCase();

String? findEquivalentEqPresetName({
  required Iterable<String> existingNames,
  required String input,
}) {
  final inputKey = eqPresetNameKey(input);
  if (inputKey.isEmpty) return null;
  for (final name in existingNames) {
    if (eqPresetNameKey(name) == inputKey) {
      return normalizedEqPresetName(name);
    }
  }
  return null;
}

bool canSubmitEqPresetName({required String input, required bool isSaving}) {
  if (isSaving) return false;
  return normalizedEqPresetName(input).isNotEmpty;
}

bool shouldRemoveEqPresetName({
  required String storedName,
  required String targetName,
}) {
  final targetKey = eqPresetNameKey(targetName);
  if (targetKey.isEmpty) return false;
  return eqPresetNameKey(storedName) == targetKey;
}

List<double> normalizedEqGains(Object? value) {
  final result = <double>[];
  if (value is Iterable) {
    for (final item in value) {
      final gain = _normalizedEqNumber(item);
      result.add(
        gain == null || !gain.isFinite
            ? 0.0
            : gain.clamp(eqGainMinDb, eqGainMaxDb).toDouble(),
      );
      if (result.length == eqBandCount) break;
    }
  }
  while (result.length < eqBandCount) {
    result.add(0.0);
  }
  return result;
}

List<double> migrateEqGains(Object? value, {required int fromVersion}) {
  final gains = normalizedEqGains(value);
  if (fromVersion >= currentEqBandModelVersion) return gains;

  return [
    for (final frequency in eqBandFrequenciesHz)
      _interpolateLogFrequencyGain(
        frequency,
        _legacyEqBandFrequenciesHz,
        gains,
      ),
  ];
}

double eqBandwidthFromQ(double q) {
  final normalizedQ = q.clamp(0.1, 10.0).toDouble();
  final x = 1.0 / (2.0 * normalizedQ);
  return (2.0 * math.log(x + math.sqrt(x * x + 1.0)) / math.ln2)
      .clamp(0.1, 10.0)
      .toDouble();
}

double eqQFromBandwidthOctaves(double bandwidthOctaves) {
  final normalizedBandwidth = bandwidthOctaves.isFinite
      ? bandwidthOctaves.clamp(0.1, 10.0).toDouble()
      : 1.0;
  final x = normalizedBandwidth * math.ln2 / 2.0;
  return 1.0 / (math.exp(x) - math.exp(-x));
}

double eqDx8BandwidthSemitonesFromQ(double q) {
  return (eqBandwidthFromQ(q) * 12.0).clamp(1.0, 36.0).toDouble();
}

double eqDx8CenterHz(double frequency) {
  return frequency.clamp(eqDx8CenterMinHz, eqDx8CenterMaxHz).toDouble();
}

double eqDx8CenterForSampleRate(double frequency, double sampleRate) {
  final normalizedSampleRate = sampleRate.isFinite && sampleRate > 0.0
      ? sampleRate
      : 48000.0;
  final maximumCenter = math.min(eqDx8CenterMaxHz, normalizedSampleRate / 3.0);
  if (maximumCenter < eqDx8CenterMinHz) return eqDx8CenterMinHz;
  return frequency.clamp(eqDx8CenterMinHz, maximumCenter).toDouble();
}

double eqBandCenterForSampleRate(double frequency, double sampleRate) {
  final normalizedSampleRate = sampleRate.isFinite && sampleRate > 0.0
      ? sampleRate
      : 48000.0;
  final maximumCenter = (normalizedSampleRate * 0.5 * 0.9)
      .clamp(20.0, eqDx8CenterMaxHz)
      .toDouble();
  return frequency.clamp(20.0, maximumCenter).toDouble();
}

double eqDbToLinear(double db) {
  if (db.isNaN) return 1.0;
  if (db == double.infinity) return double.infinity;
  if (db == double.negativeInfinity) return 0.0;
  return math.pow(10.0, db.clamp(-96.0, 96.0) / 20.0).toDouble();
}

double eqOutputVolume({required double volumeDsp, required double totalDb}) {
  final normalizedVolume = volumeDsp.isFinite
      ? volumeDsp.clamp(0.0, eqOutputVolumeMax).toDouble()
      : 0.0;
  if (normalizedVolume == 0.0) return 0.0;
  if (totalDb.isNaN) return normalizedVolume;
  return (normalizedVolume * eqDbToLinear(totalDb))
      .clamp(0.0, eqOutputVolumeMax)
      .toDouble();
}

double computeEqAutoGainDb({
  required bool eqEnabled,
  required Iterable<double> gains,
  required double preampDb,
  required double autoHeadroomDb,
  double sampleRate = 48000.0,
  bool useDx8Fallback = false,
}) {
  if (!eqEnabled) return 0.0;
  final normalizedGains = normalizedEqGains(gains.toList(growable: false));
  final peakGainDb = estimateEqPeakGainDb(
    normalizedGains,
    sampleRate: sampleRate,
    useDx8Fallback: useDx8Fallback,
  );
  final requiredHeadroomDb = math.max(
    0.0,
    peakGainDb +
        normalizedEqPreampDb(preampDb) +
        autoHeadroomDb.clamp(0.0, 24.0).toDouble(),
  );
  return (-requiredHeadroomDb).clamp(eqAutoGainMinDb, 0.0).toDouble();
}

/// 峰值估算的对数采样点数。10 段 EQ 的带宽约 1 octave，
/// 96 点覆盖每个频段的峰谷，配合预先算好的 biquad 系数完成响应评估。
const int eqPeakEstimateSampleCount = 96;

/// 单个 EQ 频段的 biquad 系数，与待评估频率无关，可在频率循环外预计算。
final class _EqBandBiquad {
  const _EqBandBiquad({
    required this.b0,
    required this.b1,
    required this.b2,
    required this.a0,
    required this.a1,
    required this.a2,
  });

  final double b0;
  final double b1;
  final double b2;
  final double a0;
  final double a1;
  final double a2;
}

double estimateEqPeakGainDb(
  Iterable<double> gains, {
  double sampleRate = 48000.0,
  bool useDx8Fallback = false,
}) {
  final normalizedGains = normalizedEqGains(gains.toList(growable: false));
  var peakDb = 0.0;
  final normalizedSampleRate = sampleRate.isFinite && sampleRate > 0.0
      ? sampleRate
      : 48000.0;
  final maximumFrequency = math.min(20000.0, normalizedSampleRate * 0.5 * 0.98);
  if (maximumFrequency <= 20.0) return 0.0;
  final bands = _buildEqBandBiquads(
    normalizedGains,
    sampleRate: normalizedSampleRate,
    useDx8Fallback: useDx8Fallback,
  );
  if (bands.isEmpty) return 0.0;
  final sampleCount = eqPeakEstimateSampleCount;
  for (var i = 0; i < sampleCount; i++) {
    final ratio = i / (sampleCount - 1);
    final frequency =
        20.0 * math.pow(maximumFrequency / 20.0, ratio).toDouble();
    peakDb = math.max(
      peakDb,
      _eqBandsResponseDb(
        frequency,
        bands,
        sampleRate: normalizedSampleRate,
      ),
    );
  }
  for (var i = 0; i < eqBandCount; i++) {
    peakDb = math.max(
      peakDb,
      _eqBandsResponseDb(
        eqBandFrequenciesHz[i],
        bands,
        sampleRate: normalizedSampleRate,
      ),
    );
  }
  return peakDb;
}

double _interpolateLogFrequencyGain(
  double targetFrequency,
  List<double> frequencies,
  List<double> gains,
) {
  if (targetFrequency <= frequencies.first) return gains.first;
  if (targetFrequency >= frequencies.last) return gains.last;
  for (var i = 0; i < frequencies.length - 1; i++) {
    final low = frequencies[i];
    final high = frequencies[i + 1];
    if (targetFrequency < low || targetFrequency > high) continue;
    final position =
        (math.log(targetFrequency) - math.log(low)) /
        (math.log(high) - math.log(low));
    return (gains[i] + (gains[i + 1] - gains[i]) * position)
        .clamp(eqGainMinDb, eqGainMaxDb)
        .toDouble();
  }
  return 0.0;
}

List<_EqBandBiquad> _buildEqBandBiquads(
  List<double> gains, {
  required double sampleRate,
  required bool useDx8Fallback,
}) {
  final bandwidthOctaves = useDx8Fallback
      ? eqDx8BandwidthSemitonesFromQ(eqBandQ) / 12.0
      : eqBandBandwidthOctaves;
  final q = eqQFromBandwidthOctaves(bandwidthOctaves);
  final bands = <_EqBandBiquad>[];
  for (var i = 0; i < eqBandCount; i++) {
    final gain = gains[i];
    if (gain.abs() < 1e-6) continue;
    final center = useDx8Fallback
        ? eqDx8CenterForSampleRate(eqBandFrequenciesHz[i], sampleRate)
        : eqBandCenterForSampleRate(eqBandFrequenciesHz[i], sampleRate);
    final w0 = 2.0 * math.pi * center / sampleRate;
    final alpha = math.sin(w0) / (2.0 * q);
    final cosine = math.cos(w0);
    final amplitude = math.pow(10.0, gain / 40.0).toDouble();
    bands.add(
      _EqBandBiquad(
        b0: 1.0 + alpha * amplitude,
        b1: -2.0 * cosine,
        b2: 1.0 - alpha * amplitude,
        a0: 1.0 + alpha / amplitude,
        a1: -2.0 * cosine,
        a2: 1.0 - alpha / amplitude,
      ),
    );
  }
  return bands;
}

double _eqBandsResponseDb(
  double frequency,
  List<_EqBandBiquad> bands, {
  required double sampleRate,
}) {
  final nyquist = sampleRate * 0.5;
  if (frequency <= 0.0 || frequency >= nyquist * 0.98) return 0.0;
  final omega = 2.0 * math.pi * frequency / sampleRate;
  final cosOmega = math.cos(omega);
  final sinOmega = math.sin(omega);
  final cosDoubleOmega = 2.0 * cosOmega * cosOmega - 1.0;
  final sinDoubleOmega = 2.0 * sinOmega * cosOmega;
  var totalDb = 0.0;
  for (final band in bands) {
    final numeratorReal =
        band.b0 + band.b1 * cosOmega + band.b2 * cosDoubleOmega;
    final numeratorImag = -band.b1 * sinOmega - band.b2 * sinDoubleOmega;
    final denominatorReal =
        band.a0 + band.a1 * cosOmega + band.a2 * cosDoubleOmega;
    final denominatorImag = -band.a1 * sinOmega - band.a2 * sinDoubleOmega;
    final denominatorMagnitude = math.sqrt(
      denominatorReal * denominatorReal + denominatorImag * denominatorImag,
    );
    final numeratorMagnitude = math.sqrt(
      numeratorReal * numeratorReal + numeratorImag * numeratorImag,
    );
    if (denominatorMagnitude <= 1e-9 || numeratorMagnitude <= 1e-9) {
      continue;
    }
    totalDb +=
        20.0 * math.log(numeratorMagnitude / denominatorMagnitude) / math.ln10;
  }
  return totalDb;
}

double normalizedEqPreampDb(Object? value) {
  final preamp = _normalizedEqNumber(value);
  if (preamp == null) return 0.0;
  if (!preamp.isFinite) return 0.0;
  return preamp.clamp(eqPreampMinDb, eqPreampMaxDb).toDouble();
}

double? _normalizedEqNumber(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}
