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

  static const _defaultDevices = <BassOutputDevice>[
    BassOutputDevice(
      id: PlaybackPreference.defaultOutputDeviceId,
      name: '系统默认',
      isDefault: true,
    ),
  ];

  final _pref = AppPreference.instance.playbackPref;
  late bool _exclusive;
  late int _deviceId;
  late String _deviceName;
  late int _sampleRate;
  late BassOutputFormat _format;
  List<BassOutputDevice> _devices = _defaultDevices;
  bool _applying = false;

  /// 已保存的设备当前是否可用。不可用时只置标记，不改写偏好中的设备。
  bool _deviceMissing = false;

  /// 设备枚举失败或列表为空时的说明，显示在下拉菜单内。
  String? _devicesError;

  /// 防止并发枚举的结果乱序覆盖。
  int _deviceLoadToken = 0;

  @override
  void initState() {
    super.initState();
    _syncFromPreference();
    unawaited(_reloadDevices());
  }

  void _syncFromPreference() {
    _exclusive = _pref.isExclusiveOutput;
    _deviceId = _pref.activeOutputDeviceId;
    _deviceName = _pref.activeOutputDeviceName;
    _sampleRate = _pref.outputSampleRate;
    _format = bassOutputFormatFromPreference(_pref.outputFormat);
  }

  Future<void> _reloadDevices() async {
    final token = ++_deviceLoadToken;
    final exclusive = _exclusive;
    try {
      final devices = await PlayService.instance.playbackService
          .enumerateOutputDevices(exclusive: exclusive);
      if (!mounted || token != _deviceLoadToken) return;
      setState(() {
        if (devices.isEmpty) {
          _devices = _defaultDevices;
          _devicesError = '未发现可用的输出设备';
          _deviceMissing = false;
        } else {
          _devices = devices;
          _devicesError = null;
          _normalizeSelection();
        }
      });
    } catch (err, trace) {
      log.settings.warn(
        'audio-output',
        '枚举输出设备失败',
        error: err,
        stackTrace: trace,
      );
      if (!mounted || token != _deviceLoadToken) return;
      setState(() {
        _devices = _defaultDevices;
        _devicesError = '设备列表读取失败，请重新展开下拉重试';
        _deviceMissing = false;
      });
    }
  }

  /// 只判定已保存设备是否仍可用；命中同名设备时更新为当前编号。
  void _normalizeSelection() {
    _deviceMissing = false;
    if (_deviceId == PlaybackPreference.defaultOutputDeviceId) return;
    for (final device in _devices) {
      if (device.id == _deviceId) return;
    }
    final target = _deviceName.trim().toLowerCase();
    if (target.isNotEmpty) {
      for (final device in _devices) {
        if (device.id < 0) continue;
        if (device.name.trim().toLowerCase() == target) {
          _deviceId = device.id;
          return;
        }
      }
    }
    _deviceMissing = true;
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
      final nextExclusive = exclusive ?? _exclusive;
      final modeChanged = nextExclusive != _exclusive;
      // 切换输出模式时由播放服务取目标模式自己的设备记录。
      final applyDeviceId = modeChanged
          ? null
          : (deviceId ??
              (_deviceMissing
                  ? PlaybackPreference.defaultOutputDeviceId
                  : _deviceId));
      final applyDeviceName = modeChanged
          ? null
          : (deviceName ?? (_deviceMissing ? '' : _deviceName));
      // 设备缺失时只改采样率/格式，偏好里保留原设备选择供设备恢复后重解析。
      final keepStoredDevice =
          !modeChanged && deviceId == null && _deviceMissing;
      final result = await PlayService.instance.playbackService
          .applyAudioOutputConfig(
            deviceId: applyDeviceId,
            deviceName: applyDeviceName,
            exclusive: nextExclusive,
            sampleRate: sampleRate ?? _sampleRate,
            format: format ?? _format,
            keepStoredDevice: keepStoredDevice,
          );
      if (!mounted) return;
      setState(_syncFromPreference);
      await _reloadDevices();
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
    unawaited(_apply(exclusive: exclusive));
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
    _pref.dsdPlaybackModeMigratedToDsf = true;
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
          subtitle: _deviceMissing
              ? '设备不可用，将使用系统默认'
              : '${state.deviceName} · ${state.exclusive ? '独占' : '共享'} · '
                    '${state.sampleRate}Hz · ${state.formatLabel}',
          action: Listener(
            onPointerDown: _applying
                ? null
                : (_) => unawaited(_reloadDevices()),
            child: DropdownMenu<int>(
              key: ValueKey('output-device-$_exclusive-$_deviceId'),
              initialSelection: _deviceId,
              width: 240,
              enableFilter: false,
              requestFocusOnTap: false,
              dropdownMenuEntries: [
                if (_devicesError != null)
                  DropdownMenuEntry<int>(
                    value: -2,
                    label: _devicesError!,
                    enabled: false,
                  ),
                if (_deviceMissing)
                  DropdownMenuEntry<int>(
                    value: _deviceId,
                    label: _deviceName.isEmpty
                        ? '设备 #$_deviceId（不可用）'
                        : '$_deviceName（不可用）',
                    enabled: false,
                  ),
                for (final device in _devices)
                  DropdownMenuEntry<int>(
                    value: device.id,
                    label: device.displayName,
                  ),
              ],
              onSelected: _applying ? null : _selectDevice,
            ),
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
          subtitle: '仅 PCM 缓存模式使用，采样率与位深按此设置；下次加载 SACD 音轨时生效',
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
          subtitle: '推荐 DSF 直解：源 DSF 原样输出，不生成 PCM 缓存，采样率与上方 PCM 缓存格式无关；'
              'PCM 缓存会生成 WAV，采样率按上方设置，首次转换较慢',
          action: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: PlaybackPreference.dsdPlaybackModeDsf,
                label: Text('DSF 直解'),
              ),
              ButtonSegment(
                value: PlaybackPreference.dsdPlaybackModePcm,
                label: Text('PCM 缓存'),
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
