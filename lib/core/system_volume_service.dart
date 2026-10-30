import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';

class SystemVolumeService {
  SystemVolumeService._();

  static SystemVolumeService? _instance;
  static SystemVolumeService get instance {
    _instance ??= SystemVolumeService._();
    return _instance!;
  }

  final volume = ValueNotifier<double>(0.5);

  bool _bound = false;
  bool _eventListenerBound = false;
  late final ValueChanged<double> _pluginListener;

  Timer? _windowsPollTimer;
  bool _windowsPollBusy = false;
  bool _disposed = false;
  final Set<Future<void>> _inFlightOperations = <Future<void>>{};

  void ensureBound() {
    if (_bound || _disposed) return;
    _pluginListener = (v) {
      if ((v - volume.value).abs() > 0.0001) {
        volume.value = v;
      }
    };
    if (!Platform.isWindows) {
      FlutterVolumeController.addListener(_pluginListener);
      _eventListenerBound = true;
    }
    _bound = true;
    refresh(timeout: const Duration(milliseconds: 600));
    if (Platform.isWindows) {
      _startWindowsPoll();
    }
  }

  Future<double?> read({required Duration timeout}) async {
    if (_disposed) return null;
    final operation = FlutterVolumeController.getVolume();
    _trackOperation(operation);
    try {
      final value = await operation.timeout(timeout);
      return _normalizeVolume(value);
    } catch (_) {
      return null;
    }
  }

  Future<void> refresh({required Duration timeout}) async {
    final v = await read(timeout: timeout);
    _publishVolume(v);
  }

  Future<void> set(double v) async {
    final normalized = _normalizeVolume(v);
    if (normalized == null || _disposed) return;
    final operation = FlutterVolumeController.setVolume(normalized);
    _trackOperation(operation);
    try {
      await operation.timeout(const Duration(seconds: 1));
    } catch (_) {}
  }

  double? _normalizeVolume(double? value) {
    if (value == null || !value.isFinite) return null;
    return value.clamp(0.0, 1.0).toDouble();
  }

  void _publishVolume(double? value) {
    if (_disposed || value == null) return;
    if ((value - volume.value).abs() > 0.0001) {
      volume.value = value;
    }
  }

  void _startWindowsPoll() {
    _windowsPollTimer?.cancel();
    _windowsPollTimer = Timer.periodic(const Duration(milliseconds: 250), (
      _,
    ) async {
      if (_disposed || _windowsPollBusy) return;
      _windowsPollBusy = true;
      try {
        final v = await read(timeout: const Duration(seconds: 1));
        if (_disposed) return;
        _publishVolume(v);
      } finally {
        _windowsPollBusy = false;
      }
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _windowsPollTimer?.cancel();
    if (_eventListenerBound) {
      FlutterVolumeController.removeListener();
      _eventListenerBound = false;
    }
    final operations = List<Future<void>>.of(_inFlightOperations);
    if (operations.isNotEmpty) {
      await Future.wait(
        operations,
      ).timeout(const Duration(seconds: 2), onTimeout: () => <void>[]);
    }
    _bound = false;
    volume.dispose();
    _instance = null;
  }

  void _trackOperation<T>(Future<T> operation) {
    final tracked = operation.then<void>((_) {}).catchError((_) {});
    _inFlightOperations.add(tracked);
    unawaited(tracked.whenComplete(() => _inFlightOperations.remove(tracked)));
  }
}
