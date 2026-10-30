part of 'preference.dart';

class PlaybackPreference {
  PlayMode playMode;
  double volumeDsp;
  List<double> eqGains;
  int eqBandModelVersion;
  bool eqEnabled;
  double eqPreampDb;
  bool eqAutoGainEnabled;
  double eqAutoHeadroomDb;
  List<EqPreset> eqPresets;
  AudioDspSettings audioDspSettings;
  String lastAudioPath;
  List<String> lastPlaylistPaths;
  int lastPlaylistIndex;
  bool lastShuffleActive;
  List<String> lastOriginalPlaylistPaths;
  double lastPositionSeconds;
  bool reinitOnSetSource;
  bool replayGainEnabled;
  ReplayGainMode replayGainMode;
  bool skipLeadingSilence;
  TransitionMode transitionMode;
  int transitionFadeOutMs;
  int transitionFadeInMs;
  String dsdPlaybackMode;
  bool dsdPlaybackModeMigratedToDsf;
  int sacdPcmSampleRate;
  int sacdPcmBitDepth;

  /// 共享模式记录的输出设备。共享与独占使用各自独立的编号空间与设备名。
  int sharedOutputDeviceId;
  String sharedOutputDeviceName;

  /// 独占（WASAPI）模式记录的输出设备。
  int wasapiOutputDeviceId;
  String wasapiOutputDeviceName;

  String outputMode;
  int outputSampleRate;
  String outputFormat;

  static const String dsdPlaybackModePcm = 'pcm';
  static const String dsdPlaybackModeDsf = 'dsf';
  static const int defaultSacdPcmSampleRate = 44100;
  static const int defaultSacdPcmBitDepth = 24;
  static const List<int> sacdPcmSampleRates = [
    44100,
    48000,
    88200,
    96000,
    192000,
  ];
  static const List<int> sacdPcmBitDepths = [16, 24];
  static const int defaultOutputDeviceId = -1;
  static const String outputModeShared = 'shared';
  static const String outputModeExclusive = 'exclusive';
  static const String outputFormatFloat32 = 'float32';
  static const String outputFormatPcm24 = 'pcm24';
  static const String outputFormatPcm16 = 'pcm16';
  static const List<int> outputSampleRates = [0, 44100, 48000, 96000, 192000];

  PlaybackPreference(
    this.playMode,
    this.volumeDsp,
    this.eqGains,
    this.eqPresets, {
    this.eqBandModelVersion = currentEqBandModelVersion,
    this.eqEnabled = true,
    this.audioDspSettings = const AudioDspSettings(),
    this.replayGainEnabled = false,
    this.replayGainMode = ReplayGainMode.track,
    this.skipLeadingSilence = false,
    this.eqPreampDb = 0.0,
    this.eqAutoGainEnabled = true,
    this.eqAutoHeadroomDb = 1.0,
    this.lastAudioPath = '',
    this.lastPlaylistPaths = const [],
    this.lastPlaylistIndex = 0,
    this.lastShuffleActive = false,
    this.lastOriginalPlaylistPaths = const [],
    this.lastPositionSeconds = 0.0,
    this.reinitOnSetSource = false,
    this.transitionMode = TransitionMode.seamless,
    this.transitionFadeOutMs = 300,
    this.transitionFadeInMs = 200,
    this.dsdPlaybackMode = dsdPlaybackModeDsf,
    this.dsdPlaybackModeMigratedToDsf = true,
    this.sacdPcmSampleRate = defaultSacdPcmSampleRate,
    this.sacdPcmBitDepth = defaultSacdPcmBitDepth,
    this.sharedOutputDeviceId = defaultOutputDeviceId,
    this.sharedOutputDeviceName = '',
    this.wasapiOutputDeviceId = defaultOutputDeviceId,
    this.wasapiOutputDeviceName = '',
    this.outputMode = outputModeShared,
    this.outputSampleRate = 0,
    this.outputFormat = outputFormatFloat32,
  });

  bool get isExclusiveOutput => outputMode == outputModeExclusive;

  /// 当前模式记录的输出设备，供播放器与设置页读取。
  int get activeOutputDeviceId =>
      isExclusiveOutput ? wasapiOutputDeviceId : sharedOutputDeviceId;

  String get activeOutputDeviceName =>
      isExclusiveOutput ? wasapiOutputDeviceName : sharedOutputDeviceName;

  int outputDeviceIdFor(bool exclusive) =>
      exclusive ? wasapiOutputDeviceId : sharedOutputDeviceId;

  String outputDeviceNameFor(bool exclusive) =>
      exclusive ? wasapiOutputDeviceName : sharedOutputDeviceName;

  void setActiveOutputDevice(int id, String name) =>
      setOutputDeviceForMode(isExclusiveOutput, id, name);

  void setOutputDeviceForMode(bool exclusive, int id, String name) {
    final normalized = name.trim();
    if (exclusive) {
      wasapiOutputDeviceId = id;
      wasapiOutputDeviceName = normalized;
    } else {
      sharedOutputDeviceId = id;
      sharedOutputDeviceName = normalized;
    }
  }

  Map<String, dynamic> toMap() => {
    'playMode': playMode.name,
    'volumeDsp': volumeDsp,
    'eqGains': eqGains,
    'eqBandModelVersion': currentEqBandModelVersion,
    'eqEnabled': eqEnabled,
    'eqPreampDb': eqPreampDb,
    'eqAutoGainEnabled': eqAutoGainEnabled,
    'eqAutoHeadroomDb': eqAutoHeadroomDb,
    'eqPresets': eqPresets.map((e) => e.toMap()).toList(),
    'audioDspSettings': audioDspSettings.toMap(),
    'lastAudioPath': lastAudioPath,
    'lastPlaylistPaths': lastPlaylistPaths,
    'lastPlaylistIndex': lastPlaylistIndex,
    'lastShuffleActive': lastShuffleActive,
    'lastOriginalPlaylistPaths': lastOriginalPlaylistPaths,
    'lastPositionSeconds': lastPositionSeconds,
    'reinitOnSetSource': reinitOnSetSource,
    'replayGainEnabled': replayGainEnabled,
    'replayGainMode': replayGainMode.name,
    'skipLeadingSilence': skipLeadingSilence,
    'transitionMode': transitionMode.name,
    'transitionFadeOutMs': transitionFadeOutMs,
    'transitionFadeInMs': transitionFadeInMs,
    'dsdPlaybackMode': dsdPlaybackMode,
    'dsdPlaybackModeMigratedToDsf': dsdPlaybackModeMigratedToDsf,
    'sacdPcmSampleRate': sacdPcmSampleRate,
    'sacdPcmBitDepth': sacdPcmBitDepth,
    'sharedOutputDeviceId': sharedOutputDeviceId,
    'sharedOutputDeviceName': sharedOutputDeviceName,
    'wasapiOutputDeviceId': wasapiOutputDeviceId,
    'wasapiOutputDeviceName': wasapiOutputDeviceName,
    // 旧版本只认识这一对键，写入当前模式那份以保持向后兼容。
    'outputDeviceId': activeOutputDeviceId,
    'outputDeviceName': activeOutputDeviceName,
    'outputMode': outputMode,
    'outputSampleRate': outputSampleRate,
    'outputFormat': outputFormat,
  };

  factory PlaybackPreference.fromMap(Object? value) {
    final map = value is Map<String, dynamic>
        ? value
        : const <String, dynamic>{};
    final session = _sessionFromMap(map);
    final eq = _eqFromMap(map);
    final transition = _transitionFromMap(map);
    final outputDevices = _outputDevicesFromMap(map);
    return PlaybackPreference(
      _playModeFromStoredValue(map['playMode']) ?? PlayMode.forward,
      _normalizedVolumeDsp(map['volumeDsp']),
      eq.gains,
      eq.presets,
      eqBandModelVersion: currentEqBandModelVersion,
      eqEnabled: eq.enabled,
      audioDspSettings: eq.dsp,
      eqPreampDb: eq.preampDb,
      eqAutoGainEnabled: eq.autoGainEnabled,
      eqAutoHeadroomDb: eq.autoHeadroomDb,
      lastAudioPath: session.lastAudioPath,
      lastPlaylistPaths: session.lastPlaylistPaths,
      lastPlaylistIndex: session.lastPlaylistIndex,
      lastShuffleActive: session.lastShuffleActive,
      lastOriginalPlaylistPaths: session.lastOriginalPlaylistPaths,
      lastPositionSeconds: session.lastPositionSeconds,
      reinitOnSetSource: session.reinitOnSetSource,
      replayGainEnabled: session.replayGainEnabled,
      replayGainMode: session.replayGainMode,
      skipLeadingSilence: session.skipLeadingSilence,
      transitionMode: transition.mode,
      transitionFadeOutMs: transition.fadeOutMs,
      transitionFadeInMs: transition.fadeInMs,
      dsdPlaybackMode: _dsdPlaybackModeFromMap(map),
      dsdPlaybackModeMigratedToDsf: true,
      sacdPcmSampleRate: _sacdPcmSampleRateFromStored(
        map['sacdPcmSampleRate'],
      ),
      sacdPcmBitDepth: _sacdPcmBitDepthFromStored(map['sacdPcmBitDepth']),
      sharedOutputDeviceId: outputDevices.sharedId,
      sharedOutputDeviceName: outputDevices.sharedName,
      wasapiOutputDeviceId: outputDevices.wasapiId,
      wasapiOutputDeviceName: outputDevices.wasapiName,
      outputMode: _outputModeFromStored(map['outputMode']),
      outputSampleRate: _outputSampleRateFromStored(map['outputSampleRate']),
      outputFormat: _outputFormatFromStored(map['outputFormat']),
    );
  }

  /// 读取 DSD 播放模式，并把旧配置中默认的 PCM 一次性迁移到 DSF。
  ///
  /// 迁移标记随播放偏好一起保存：没有标记且存储为 `pcm` 的记录按旧默认值处理，
  /// 迁移为 `dsf`；带标记的记录完全尊重存储值，用户手动选择的 `pcm` 会保留。
  static String _dsdPlaybackModeFromMap(Map<String, dynamic> map) {
    final migrated = _normalizedBool(
      map['dsdPlaybackModeMigratedToDsf'],
      defaultValue: false,
    );
    final storedMode = _normalizedString(map['dsdPlaybackMode']).toLowerCase();
    if (!migrated && storedMode == dsdPlaybackModePcm) {
      return dsdPlaybackModeDsf;
    }
    return _dsdPlaybackModeFromStored(map['dsdPlaybackMode']);
  }

  static String _dsdPlaybackModeFromStored(Object? value) {
    final mode = _normalizedString(value).toLowerCase();
    return mode == dsdPlaybackModePcm
        ? dsdPlaybackModePcm
        : dsdPlaybackModeDsf;
  }

  static int _sacdPcmSampleRateFromStored(Object? value) {
    final rate = _normalizedInteger(value);
    return rate != null && sacdPcmSampleRates.contains(rate)
        ? rate
        : defaultSacdPcmSampleRate;
  }

  static int _sacdPcmBitDepthFromStored(Object? value) {
    final depth = _normalizedInteger(value);
    return depth != null && sacdPcmBitDepths.contains(depth)
        ? depth
        : defaultSacdPcmBitDepth;
  }

  /// 读取两种模式各自的输出设备，并把旧配置的单份设备迁移到当时记录的模式。
  ///
  /// 缺少分模式键时，按 `outputMode` 把 `outputDeviceId/outputDeviceName` 并入
  /// 该模式；另一模式保持系统默认，由用户在该模式下重新选择。
  static ({
    int sharedId,
    String sharedName,
    int wasapiId,
    String wasapiName,
  })
  _outputDevicesFromMap(Map<String, dynamic> map) {
    final legacyId = _outputDeviceIdFromStored(map['outputDeviceId']);
    final legacyName = _normalizedString(map['outputDeviceName']);
    final legacyExclusive =
        _outputModeFromStored(map['outputMode']) == outputModeExclusive;
    final hasShared =
        map.containsKey('sharedOutputDeviceId') ||
        map.containsKey('sharedOutputDeviceName');
    final hasWasapi =
        map.containsKey('wasapiOutputDeviceId') ||
        map.containsKey('wasapiOutputDeviceName');
    return (
      sharedId: hasShared
          ? _outputDeviceIdFromStored(map['sharedOutputDeviceId'])
          : (legacyExclusive ? defaultOutputDeviceId : legacyId),
      sharedName: hasShared
          ? _normalizedString(map['sharedOutputDeviceName'])
          : (legacyExclusive ? '' : legacyName),
      wasapiId: hasWasapi
          ? _outputDeviceIdFromStored(map['wasapiOutputDeviceId'])
          : (legacyExclusive ? legacyId : defaultOutputDeviceId),
      wasapiName: hasWasapi
          ? _normalizedString(map['wasapiOutputDeviceName'])
          : (legacyExclusive ? legacyName : ''),
    );
  }

  static int _outputDeviceIdFromStored(Object? value) {
    final id = _normalizedInteger(value);
    return id != null && id >= defaultOutputDeviceId
        ? id
        : defaultOutputDeviceId;
  }

  static String _outputModeFromStored(Object? value) {
    final mode = _normalizedString(value).toLowerCase();
    return mode == outputModeExclusive ? outputModeExclusive : outputModeShared;
  }

  static int _outputSampleRateFromStored(Object? value) {
    final rate = _normalizedInteger(value);
    return rate != null && outputSampleRates.contains(rate) ? rate : 0;
  }

  static String _outputFormatFromStored(Object? value) {
    final format = _normalizedString(value).toLowerCase();
    if (format == outputFormatPcm24) return outputFormatPcm24;
    if (format == outputFormatPcm16) return outputFormatPcm16;
    return outputFormatFloat32;
  }

  static ({
    String lastAudioPath,
    List<String> lastPlaylistPaths,
    int lastPlaylistIndex,
    bool lastShuffleActive,
    List<String> lastOriginalPlaylistPaths,
    double lastPositionSeconds,
    bool reinitOnSetSource,
    bool replayGainEnabled,
    ReplayGainMode replayGainMode,
    bool skipLeadingSilence,
  })
  _sessionFromMap(Map<String, dynamic> map) {
    final lastPlaylistPaths = _normalizedPathStringList(
      map['lastPlaylistPaths'],
    );
    return (
      lastAudioPath: _normalizedPathString(map['lastAudioPath']),
      lastPlaylistPaths: lastPlaylistPaths,
      lastPlaylistIndex: _normalizedBoundedInt(
        map['lastPlaylistIndex'],
        defaultValue: 0,
        min: 0,
        max: lastPlaylistPaths.isEmpty ? 0 : lastPlaylistPaths.length - 1,
      ),
      lastShuffleActive: _normalizedBool(
        map['lastShuffleActive'],
        defaultValue: false,
      ),
      lastOriginalPlaylistPaths: _normalizedPathStringList(
        map['lastOriginalPlaylistPaths'],
      ),
      lastPositionSeconds: _normalizedBoundedDouble(
        map['lastPositionSeconds'],
        defaultValue: 0.0,
        min: 0.0,
        max: 24 * 60 * 60,
      ),
      reinitOnSetSource: _normalizedBool(
        map['reinitOnSetSource'],
        defaultValue: false,
      ),
      replayGainEnabled: _normalizedBool(
        map['replayGainEnabled'],
        defaultValue: false,
      ),
      replayGainMode: _replayGainModeFromStored(map['replayGainMode']),
      skipLeadingSilence: _normalizedBool(
        map['skipLeadingSilence'],
        defaultValue: false,
      ),
    );
  }

  static ({
    List<double> gains,
    List<EqPreset> presets,
    bool enabled,
    AudioDspSettings dsp,
    double preampDb,
    bool autoGainEnabled,
    double autoHeadroomDb,
  })
  _eqFromMap(Map<String, dynamic> map) {
    return (
      gains: migrateEqGains(
        map['eqGains'],
        fromVersion: _storedEqBandVersion(map),
      ),
      presets: _eqPresetsFromStoredValue(map['eqPresets']),
      enabled: _normalizedBool(map['eqEnabled'], defaultValue: true),
      dsp: AudioDspSettings.fromMap(map['audioDspSettings']),
      preampDb: normalizedEqPreampDb(map['eqPreampDb']),
      autoGainEnabled: _normalizedBool(
        map['eqAutoGainEnabled'],
        defaultValue: true,
      ),
      autoHeadroomDb: _normalizedBoundedDouble(
        map['eqAutoHeadroomDb'],
        defaultValue: 1.0,
        min: 0.0,
        max: 24.0,
      ),
    );
  }

  static ({TransitionMode mode, int fadeOutMs, int fadeInMs})
  _transitionFromMap(Map<String, dynamic> map) {
    return (
      mode: _transitionModeFromStored(map),
      fadeOutMs: _normalizedBoundedInt(
        map['transitionFadeOutMs'],
        defaultValue: 300,
        min: 0,
        max: 10000,
      ),
      fadeInMs: _normalizedBoundedInt(
        map['transitionFadeInMs'],
        defaultValue: 200,
        min: 0,
        max: 10000,
      ),
    );
  }

  static int _storedEqBandVersion(Map<String, dynamic> map) {
    return _normalizedBoundedInt(
      map['eqBandModelVersion'],
      defaultValue: legacyEqBandModelVersion,
      min: legacyEqBandModelVersion,
      max: currentEqBandModelVersion,
    );
  }
}

class PlaybackPreferenceCodec {
  const PlaybackPreferenceCodec._();

  static PlaybackPreference decode(Object? value) =>
      PlaybackPreference.fromMap(value);

  static Map<String, dynamic> encode(PlaybackPreference value) => value.toMap();
}
