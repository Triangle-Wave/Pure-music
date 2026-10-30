import 'dart:io';

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

    test('Rust 模式名与生效模式一致', () {
      expect(const ProxyConfig(mode: ProxyMode.system).rustModeName, 'system');
      expect(const ProxyConfig(mode: ProxyMode.direct).rustModeName, 'direct');
      expect(
        const ProxyConfig(
          mode: ProxyMode.manual,
          host: '127.0.0.1',
        ).rustModeName,
        'manual',
      );
      expect(
        const ProxyConfig(
          mode: ProxyMode.manual,
          host: '',
        ).effective.rustModeName,
        'direct',
      );
    });

    test('手动模式按主机与绕过规则选择代理', () {
      const config = ProxyConfig(
        mode: ProxyMode.manual,
        host: '127.0.0.1',
        port: 7890,
        bypass: '*.corp.example;internal.example,192.168.*',
      );

      expect(
        config.findProxyFor(Uri.parse('https://api.github.com/repos/x/y')),
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

    test('手动代理下所有公网域名统一走代理', () {
      const config = ProxyConfig(
        mode: ProxyMode.manual,
        host: '127.0.0.1',
        port: 7890,
      );

      for (final url in const [
        'https://music.163.com/api/cloudsearch/pc',
        'https://p1.music.126.net/cover.jpg',
        'https://u.y.qq.com/cgi-bin/musicu.fcg',
        'https://y.gtimg.cn/music/photo_new/T001.jpg',
        'https://mobilecdn.kugou.com/api/v3/search/album',
        'https://imge.kugou.com/stdmusic/cover.jpg',
        'https://api.github.com/repos/a/b/releases/latest',
        'https://raw.githubusercontent.com/a/b/main/version.json',
        'https://coverartarchive.org/release/x',
      ]) {
        expect(
          config.findProxyFor(Uri.parse(url)),
          'PROXY 127.0.0.1:7890',
          reason: url,
        );
      }
    });

    test('系统模式沿用环境变量代理设置', () {
      const config = ProxyConfig(mode: ProxyMode.system);
      final uri = Uri.parse('https://music.163.com/api');

      expect(
        config.findProxyFor(uri),
        HttpClient.findProxyFromEnvironment(uri),
      );
    });

    test('host 附带端口时以该端口生成代理规则', () {
      const config = ProxyConfig(
        mode: ProxyMode.manual,
        host: 'http://127.0.0.1:7890/',
      );

      expect(config.normalizedHost, '127.0.0.1');
      expect(config.resolvedPort, 7890);
      expect(config.proxyRule, 'PROXY 127.0.0.1:7890');
      expect(
        config.findProxyFor(Uri.parse('https://api.github.com/x')),
        'PROXY 127.0.0.1:7890',
      );
    });

    test('IPv6 主机附带端口时正确拆分', () {
      const config = ProxyConfig(mode: ProxyMode.manual, host: '[::1]:7890');

      expect(config.normalizedHost, '::1');
      expect(config.resolvedPort, 7890);
      expect(config.rustHost, '[::1]');
      expect(config.proxyRule, 'PROXY [::1]:7890');
      expect(config.hasValidManualTarget, isTrue);
    });

    test('Rust bypass 只保留用户配置并去重', () {
      const config = ProxyConfig(
        mode: ProxyMode.manual,
        host: '127.0.0.1',
        bypass: 'localhost, internal.example; localhost',
      );

      final rules = config.rustBypass.split(',');

      expect(rules, ['localhost', 'internal.example']);
      expect(rules, isNot(contains('music.163.com')));
      expect(rules, isNot(contains('y.qq.com')));
      const defaults = ProxyConfig(mode: ProxyMode.manual, host: '127.0.0.1');
      expect(defaults.rustBypass, defaultProxyBypass);
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
      expect(config.rustHost, '[::1]');
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

  test('全局覆盖保留自动解压', () {
    final client = AppHttpOverrides(
      config: const ProxyConfig(mode: ProxyMode.direct),
    ).createHttpClient(null);

    expect(client.autoUncompress, isTrue);
    client.close(force: true);
  });
}
