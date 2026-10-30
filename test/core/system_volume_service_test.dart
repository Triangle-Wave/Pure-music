import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:pure_music/core/system_volume_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          FlutterVolumeController.methodChannel,
          (call) async => call.method == 'getVolume' ? '0.5' : null,
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FlutterVolumeController.methodChannel, null);
    await SystemVolumeService.instance.dispose();
  });

  test('waits for an in-flight Windows volume read before disposing', () async {
    if (!Platform.isWindows) return;

    final getVolume = Completer<String>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          FlutterVolumeController.methodChannel,
          (call) => call.method == 'getVolume' ? getVolume.future : null,
        );

    final service = SystemVolumeService.instance;
    service.ensureBound();
    await Future<void>.delayed(Duration.zero);

    var disposed = false;
    final disposeFuture = service.dispose().then((_) => disposed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(disposed, isFalse);
    getVolume.complete('0.5');
    await disposeFuture;
    expect(disposed, isTrue);
  });
}
