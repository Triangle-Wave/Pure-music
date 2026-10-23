import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/network_proxy.dart';
import 'package:pure_music/core/settings.dart';

void main() {
  tearDown(() async {
    await AppSettings.readFromSettingsMapForTest({'Version': 'test'});
  });

  group('ProxyConfig', () {
    test('默认使用系统模式', () async {
      await AppSettings.readFromSettingsMapForTest({'Version': 'test'});

      final config = ProxyConfig.fromSettings(AppSettings.instance);

      expect(config.mode, ProxyMode.system);
      expect(config.host, isEmpty);
      expect(config.port, defaultProxyPort);
      expect(config.bypass, defaultProxyBypass);
    });

    test('手动模式按主机与绕过规则选择代理', () {
      const config = ProxyConfig(
        mode: ProxyMode.manual,
        host: '127.0.0.1',
        port: 7890,
        bypass: '*.corp.example;internal.example,192.168.*',
      );

      expect(
        config.findProxyFor(Uri.parse('https://music.163.com/api')),
        'PROXY 127.0.0.1:7890',
      );
      expect(config.findProxyFor(Uri.parse('http://localhost/a')), 'DIRECT');
      expect(config.findProxyFor(Uri.parse('https://127.0.0.1/a')), 'DIRECT');
      expect(config.findProxyFor(Uri.parse('https://[::1]/a')), 'DIRECT');
      expect(
        config.findProxyFor(Uri.parse('https://api.corp.example/a')),
        'DIRECT',
      );
      expect(
        config.findProxyFor(Uri.parse('https://corp.example/a')),
        'DIRECT',
      );
      expect(
        config.findProxyFor(Uri.parse('https://internal.example/a')),
        'DIRECT',
      );
      expect(
        config.findProxyFor(Uri.parse('https://deep.internal.example/a')),
        'DIRECT',
      );
      expect(
        config.findProxyFor(Uri.parse('https://192.168.1.10/a')),
        'DIRECT',
      );
    });

    test('直连模式始终返回 DIRECT', () {
      const config = ProxyConfig(
        mode: ProxyMode.direct,
        host: '127.0.0.1',
        port: 7890,
      );

      expect(config.findProxyFor(Uri.parse('https://example.com')), 'DIRECT');
    });

    test('手动配置非法时回退直连', () {
      const config = ProxyConfig(mode: ProxyMode.manual, host: '');

      expect(config.hasValidManualTarget, isFalse);
      expect(config.effective.mode, ProxyMode.direct);
      expect(config.findProxyFor(Uri.parse('https://example.com')), 'DIRECT');
    });

    test('端口越界视为非法配置', () {
      const config = ProxyConfig(
        mode: ProxyMode.manual,
        host: 'proxy.local',
        port: 70000,
      );

      expect(config.hasValidManualTarget, isFalse);
      expect(config.findProxyFor(Uri.parse('https://example.com')), 'DIRECT');
    });

    test('主机带协议前缀时做归一化', () {
      const config = ProxyConfig(
        mode: ProxyMode.manual,
        host: 'http://proxy.local/',
        port: 8080,
      );

      expect(config.normalizedHost, 'proxy.local');
      expect(config.proxyRule, 'PROXY proxy.local:8080');
    });

    test('IPv6 代理主机加方括号', () {
      const config = ProxyConfig(
        mode: ProxyMode.manual,
        host: '::1',
        port: 7890,
      );

      expect(config.proxyRule, 'PROXY [::1]:7890');
    });
  });

  group('代理设置读写', () {
    test('从 settings 读取并写回', () async {
      await AppSettings.readFromSettingsMapForTest({
        'Version': 'test',
        'ProxyMode': 'manual',
        'ProxyHost': 'proxy.local',
        'ProxyPort': 8081,
        'ProxyUser': 'user',
        'ProxyPass': 'secret',
        'ProxyBypass': 'localhost',
      });

      final config = ProxyConfig.fromSettings(AppSettings.instance);

      expect(config.mode, ProxyMode.manual);
      expect(config.host, 'proxy.local');
      expect(config.port, 8081);
      expect(config.username, 'user');
      expect(config.password, 'secret');
      expect(config.bypass, 'localhost');

      const updated = ProxyConfig(
        mode: ProxyMode.direct,
        port: 9000,
        bypass: 'corp.example',
      );
      updated.applyToSettings(AppSettings.instance);

      expect(AppSettings.instance.proxyMode, ProxyMode.direct);
      expect(AppSettings.instance.proxyHost, isEmpty);
      expect(AppSettings.instance.proxyPort, 9000);
      expect(AppSettings.instance.proxyBypass, 'corp.example');
    });

    test('缺失代理键回到默认值', () async {
      await AppSettings.readFromSettingsMapForTest({
        'Version': 'test',
        'ProxyMode': 'manual',
        'ProxyHost': 'proxy.local',
        'ProxyPort': 9000,
      });
      await AppSettings.readFromSettingsMapForTest({'Version': 'test'});

      expect(AppSettings.instance.proxyMode, ProxyMode.system);
      expect(AppSettings.instance.proxyHost, isEmpty);
      expect(AppSettings.instance.proxyPort, defaultProxyPort);
      expect(AppSettings.instance.proxyBypass, defaultProxyBypass);
    });

    test('ProxyMode 支持存储枚举下标', () async {
      await AppSettings.readFromSettingsMapForTest({
        'Version': 'test',
        'ProxyMode': ProxyMode.manual.index,
      });

      expect(AppSettings.instance.proxyMode, ProxyMode.manual);
    });
  });

  test('全局覆盖关闭自动解压', () {
    final client = AppHttpOverrides(
      config: const ProxyConfig(mode: ProxyMode.direct),
    ).createHttpClient(null);

    expect(client.autoUncompress, isFalse);
    client.close(force: true);
  });
}
