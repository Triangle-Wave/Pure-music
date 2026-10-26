import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/settings_page/tabs/settings_section_header.dart';
import 'package:pure_music/play_service/play_service.dart';

/// 音频输出设置：设备、共享/独占、采样率、格式、PCM 缓存与 DSD 模式。
class AudioOutputSettingsPanel extends StatefulWidget {
  const AudioOutputSettingsPanel({super.key});

  @override
  State<AudioOutputSettingsPanel> createState() =>
      _AudioOutputSettingsPanelState();
}

class _AudioOutputSettingsPanelState extends State<AudioOutputSettingsPanel> {
  static const _pcmCacheOptions = <String>[
    'auto',
    '44100-16',
    '44100-24',
    '88200-24',
    '96000-24',
    '192000-24',
  ];

  final _pref = AppPreference.instance.playbackPref;
  late bool _exclusive;
  late int _deviceId;
  late String _deviceName;
  late int _sampleRate;
  late BassOutputFormat _format;
  List<BassOutputDevice> _devices = const [
    BassOutputDevice(
      id: PlaybackPreference.defaultOutputDeviceId,
      name: '系统默认',
      isDefault: true,
    ),
  ];
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _syncFromPreference();
    unawaited(_reloadDevices());
  }

  void _syncFromPreference() {
    _exclusive = _pref.outputMode == PlaybackPreference.outputModeExclusive;
    _deviceId = _pref.outputDeviceId;
    _deviceName = _pref.outputDeviceName;
    _sampleRate = _pref.outputSampleRate;
    _format = bassOutputFormatFromPreference(_pref.outputFormat);
  }

  Future<List<BassOutputDevice>> _loadDevices(bool exclusive) async {
    try {
      final devices = await PlayService.instance.playbackService
          .enumerateOutputDevices(exclusive: exclusive);
      if (devices.isEmpty) {
        return const [
          BassOutputDevice(
            id: PlaybackPreference.defaultOutputDeviceId,
            name: '系统默认',
            isDefault: true,
          ),
        ];
      }
      return devices;
    } catch (err, trace) {
      log.settings.warn(
        'audio-output',
        '枚举输出设备失败',
        error: err,
        stackTrace: trace,
      );
      return const [
        BassOutputDevice(
          id: PlaybackPreference.defaultOutputDeviceId,
          name: '系统默认',
          isDefault: true,
        ),
      ];
    }
  }

  Future<void> _reloadDevices() async {
    final devices = await _loadDevices(_exclusive);
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _normalizeSelection();
    });
  }

  void _normalizeSelection() {
    for (final device in _devices) {
      if (device.id == _deviceId) return;
    }
    for (final device in _devices) {
      if (device.id >= 0 && device.name == _deviceName) {
        _deviceId = device.id;
        return;
      }
    }
    _deviceId = PlaybackPreference.defaultOutputDeviceId;
    _deviceName = '系统默认';
  }

  Future<void> _apply({
    int? deviceId,
    String? deviceName,
    bool? exclusive,
    int? sampleRate,
    BassOutputFormat? format,
  }) async {
    if (_applying) return;
    setState(() => _applying = true);
    try {
      final result = await PlayService.instance.playbackService
          .applyAudioOutputConfig(
            deviceId: deviceId ?? _deviceId,
            deviceName: deviceName ?? _deviceName,
            exclusive: exclusive ?? _exclusive,
            sampleRate: sampleRate ?? _sampleRate,
            format: format ?? _format,
          );
      if (!mounted) return;
      final devices = await _loadDevices(
        AppPreference.instance.playbackPref.outputMode ==
            PlaybackPreference.outputModeExclusive,
      );
      if (!mounted) return;
      setState(() {
        _syncFromPreference();
        _devices = devices;
        _normalizeSelection();
      });
      if (!result.success) {
        log.settings.warn(
          'audio-output',
          '音频输出切换未生效: ${result.message}',
        );
      }
    } catch (err, trace) {
      log.settings.error(
        'audio-output',
        '应用音频输出设置时发生异常',
        error: err,
        stackTrace: trace,
      );
      if (mounted) {
        showTextOnSnackBar('音频输出设置失败，请查看日志', variant: ToastVariant.error);
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  void _selectDevice(int? id) {
    if (id == null) return;
    for (final device in _devices) {
      if (device.id != id) continue;
      unawaited(_apply(deviceId: device.id, deviceName: device.name));
      return;
    }
  }

  void _setExclusive(bool exclusive) {
    if (exclusive == _exclusive) return;
    unawaited(
      _apply(
        exclusive: exclusive,
        deviceId: _deviceId,
        deviceName: _deviceName,
      ),
    );
  }

  String get _pcmCacheSelection {
    if (_pref.sacdPcmSampleRate ==
            PlaybackPreference.defaultSacdPcmSampleRate &&
        _pref.sacdPcmBitDepth == PlaybackPreference.defaultSacdPcmBitDepth) {
      return 'auto';
    }
    final key = '${_pref.sacdPcmSampleRate}-${_pref.sacdPcmBitDepth}';
    return _pcmCacheOptions.contains(key) ? key : 'auto';
  }

  void _setPcmCache(String value) {
    if (value == 'auto') {
      _pref.sacdPcmSampleRate = PlaybackPreference.defaultSacdPcmSampleRate;
      _pref.sacdPcmBitDepth = PlaybackPreference.defaultSacdPcmBitDepth;
    } else {
      final parts = value.split('-');
      if (parts.length != 2) return;
      final rate = int.tryParse(parts[0]);
      final depth = int.tryParse(parts[1]);
      if (rate == null || depth == null) return;
      _pref.sacdPcmSampleRate = rate;
      _pref.sacdPcmBitDepth = depth;
    }
    setState(() {});
    unawaited(_savePlaybackPreference());
  }

  void _setDsdPlaybackMode(String mode) {
    final normalized = mode == PlaybackPreference.dsdPlaybackModeDsf
        ? PlaybackPreference.dsdPlaybackModeDsf
        : PlaybackPreference.dsdPlaybackModePcm;
    if (_pref.dsdPlaybackMode == normalized) return;
    _pref.dsdPlaybackMode = normalized;
    setState(() {});
    unawaited(_savePlaybackPreference());
  }

  Future<void> _savePlaybackPreference() async {
    try {
      final saved = await AppPreference.instance.savePlaybackOnly();
      if (!saved && mounted) {
        showTextOnSnackBar('设置保存失败', variant: ToastVariant.error);
      }
    } catch (err, trace) {
      log.settings.error(
        'audio-output',
        '保存播放偏好失败',
        error: err,
        stackTrace: trace,
      );
      if (mounted) {
        showTextOnSnackBar('设置保存失败', variant: ToastVariant.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = PlayService.instance.playbackService.outputState;
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        const SettingsSectionHeader('音频输出'),
        const SizedBox(height: 4.0),
        if (_applying)
          Padding(
            padding: const EdgeInsets.only(bottom: 16.0),
            child: Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(
                  '正在切换输出…',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: AppType.body,
                  ),
                ),
              ],
            ),
          ),
        SettingsTile(
          description: '输出设备',
          subtitle:
              '${state.deviceName} · ${state.exclusive ? '独占' : '共享'} · '
              '${state.sampleRate}Hz · ${state.formatLabel}',
          action: DropdownMenu<int>(
            key: ValueKey('output-device-$_exclusive-$_deviceId'),
            initialSelection: _deviceId,
            width: 240,
            enableFilter: false,
            requestFocusOnTap: false,
            dropdownMenuEntries: [
              for (final device in _devices)
                DropdownMenuEntry<int>(
                  value: device.id,
                  label: device.displayName,
                ),
            ],
            onSelected: _applying ? null : _selectDevice,
          ),
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: '输出模式',
          subtitle: '独占绕过系统混音器，应用独占时自动关闭均衡器与变速变调',
          action: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('共享')),
              ButtonSegment(value: true, label: Text('独占')),
            ],
            selected: {_exclusive},
            onSelectionChanged: _applying
                ? null
                : (selection) {
                    if (selection.isEmpty) return;
                    _setExclusive(selection.first);
                  },
          ),
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: '输出采样率',
          subtitle: _exclusive
              ? '独占请求 ${_sampleRateLabel(_sampleRate)}，自动时跟随设备混音格式；实际 ${state.sampleRate}Hz'
              : '共享请求 ${_sampleRateLabel(_sampleRate)}，自动时为 44100Hz；实际 ${state.sampleRate}Hz',
          action: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 0, label: Text('自动')),
              ButtonSegment(value: 44100, label: Text('44.1k')),
              ButtonSegment(value: 48000, label: Text('48k')),
              ButtonSegment(value: 96000, label: Text('96k')),
              ButtonSegment(value: 192000, label: Text('192k')),
            ],
            selected: {_sampleRate},
            onSelectionChanged: _applying
                ? null
                : (selection) {
                    if (selection.isEmpty) return;
                    final rate = selection.first;
                    unawaited(_apply(sampleRate: rate));
                  },
          ),
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: '输出格式',
          subtitle: _exclusive
              ? '独占按所选格式请求，设备不支持时自动选择兼容格式；当前 ${state.formatLabel}'
              : '共享格式由系统混音器决定，当前 ${state.formatLabel}',
          action: SegmentedButton<BassOutputFormat>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: BassOutputFormat.float32,
                label: Text('float32'),
              ),
              ButtonSegment(value: BassOutputFormat.pcm24, label: Text('24bit')),
              ButtonSegment(value: BassOutputFormat.pcm16, label: Text('16bit')),
            ],
            selected: {_format},
            onSelectionChanged: _applying || !_exclusive
                ? null
                : (selection) {
                    if (selection.isEmpty) return;
                    unawaited(_apply(format: selection.first));
                  },
          ),
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: 'PCM 缓存格式',
          subtitle: 'SACD ISO 转 PCM 时使用；下次加载 SACD 音轨时生效',
          action: DropdownMenu<String>(
            key: ValueKey('pcm-cache-$_pcmCacheSelection'),
            initialSelection: _pcmCacheSelection,
            width: 220,
            enableFilter: false,
            requestFocusOnTap: false,
            dropdownMenuEntries: const [
              DropdownMenuEntry<String>(
                value: 'auto',
                label: '自动（44100 / 24bit）',
              ),
              DropdownMenuEntry<String>(
                value: '44100-16',
                label: '44100 / 16bit',
              ),
              DropdownMenuEntry<String>(
                value: '44100-24',
                label: '44100 / 24bit',
              ),
              DropdownMenuEntry<String>(
                value: '88200-24',
                label: '88200 / 24bit',
              ),
              DropdownMenuEntry<String>(
                value: '96000-24',
                label: '96000 / 24bit',
              ),
              DropdownMenuEntry<String>(
                value: '192000-24',
                label: '192000 / 24bit',
              ),
            ],
            onSelected: _applying
                ? null
                : (value) {
                    if (value != null) _setPcmCache(value);
                  },
          ),
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: 'DSD 播放模式',
          subtitle: '直接解出 DSF 与会转换为 PCM 缓存；缓存格式由上方设置决定',
          action: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: PlaybackPreference.dsdPlaybackModePcm,
                label: Text('PCM 缓存'),
              ),
              ButtonSegment(
                value: PlaybackPreference.dsdPlaybackModeDsf,
                label: Text('DSF 直解'),
              ),
            ],
            selected: {_pref.dsdPlaybackMode},
            onSelectionChanged: _applying
                ? null
                : (selection) {
                    if (selection.isEmpty) return;
                    _setDsdPlaybackMode(selection.first);
                  },
          ),
        ),
        const SizedBox(height: 16.0),
        Text(
          '独占模式为独占设备请求所选采样率与格式；共享模式由 Windows 混音器决定实际格式。'
          '切换失败会自动回退到切换前的设备与模式。',
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: AppType.caption,
          ),
        ),
      ],
    );
  }

  String _sampleRateLabel(int rate) {
    if (rate <= 0) return '自动';
    if (rate % 1000 == 0) return '${rate ~/ 1000}kHz';
    return '${(rate / 1000).toStringAsFixed(1)}kHz';
  }
}
