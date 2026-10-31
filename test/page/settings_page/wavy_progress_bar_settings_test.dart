import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/settings_page/settings_tabs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Set<NowPlayingMode> previousModes;
  var notifications = 0;

  void countNotification() => notifications++;

  setUp(() {
    previousModes = {...AppSettings.instance.wavyBarEnabledModes};
    AppSettings.instance.wavyBarEnabledModes = <NowPlayingMode>{};
    notifications = 0;
    AppSettings.rebuildNotifier.addListener(countNotification);
  });

  tearDown(() {
    AppSettings.rebuildNotifier.removeListener(countNotification);
    AppSettings.instance.wavyBarEnabledModes = previousModes;
    wavyBarSettingsPersistForTest = null;
  });

  testWidgets('切换波浪模式后通知播放页并保留选中状态', (tester) async {
    wavyBarSettingsPersistForTest = () async => true;

    await _pumpProgressSettings(tester);
    expect(find.text('实心'), findsOneWidget);

    await tester.tap(find.text('竖屏'));
    await tester.pumpAndSettle();

    expect(notifications, 1);
    expect(
      AppSettings.instance.wavyBarEnabledModes,
      contains(NowPlayingMode.portrait),
    );
    expect(find.text('波浪'), findsOneWidget);
  });

  testWidgets('波浪模式保存失败时回滚选中状态并提示', (tester) async {
    wavyBarSettingsPersistForTest = () async => false;

    await _pumpProgressSettings(tester, mountToastHost: true);

    await tester.tap(find.text('竖屏'));
    await tester.pumpAndSettle();

    expect(notifications, 2);
    expect(
      AppSettings.instance.wavyBarEnabledModes,
      isNot(contains(NowPlayingMode.portrait)),
    );
    expect(find.text('实心'), findsOneWidget);
    expect(find.text('波浪进度条设置保存失败'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 200));
  });
}

Future<void> _pumpProgressSettings(
  WidgetTester tester, {
  bool mountToastHost = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: mountToastHost ? routerKey : null,
      scaffoldMessengerKey: mountToastHost ? scaffoldMessengerKey : null,
      home: const Scaffold(
        body: Column(
          children: [
            Expanded(
              child: SettingsGroupPage(groupId: 'appearance-progress'),
            ),
            _WavyStateProbe(mode: NowPlayingMode.portrait),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 以播放页相同的监听方式读取波浪开关，验证设置切换后的绘制状态。
class _WavyStateProbe extends StatelessWidget {
  const _WavyStateProbe({required this.mode});

  final NowPlayingMode mode;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.rebuildNotifier,
      builder: (context, _) {
        final enabled = AppSettings.instance.wavyBarEnabledModes.contains(mode);
        return Text(enabled ? '波浪' : '实心');
      },
    );
  }
}
