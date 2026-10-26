import 'dart:io';

import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/native/rust/api/network_proxy.dart'
    as rust_network_proxy;

/// 代理模式。
///
/// - [system]：读取 `http_proxy` / `https_proxy` / `no_proxy` 环境变量。
///   Dart 的 `HttpClient` 不读取 Windows 注册表里的系统代理，需要走系统
///   代理的用户应选择 [manual]。
/// - [direct]：所有请求直连。
/// - [manual]：HTTP/HTTPS 请求统一走手动配置的代理。
enum ProxyMode { system, direct, manual }

/// 默认端口贴合常见本地代理（Clash / Mihomo）。
const int defaultProxyPort = 7890;

/// 本地地址始终直连，不随 bypass 列表变化。
const String defaultProxyBypass = 'localhost,127.0.0.1,::1';

/// 全局网络代理配置。
class ProxyConfig {
  const ProxyConfig({
    this.mode = ProxyMode.system,
    this.host = '',
    this.port = defaultProxyPort,
    this.username = '',
    this.password = '',
    this.bypass = defaultProxyBypass,
  });

  factory ProxyConfig.fromSettings(AppSettings settings) {
    return ProxyConfig(
      mode: settings.proxyMode,
      host: settings.proxyHost,
      port: settings.proxyPort,
      username: settings.proxyUser,
      password: settings.proxyPass,
      bypass: settings.proxyBypass,
    );
  }

  final ProxyMode mode;
  final String host;
  final int port;
  final String username;
  final String password;

  /// 逗号、分号或空白分隔的绕过规则。
  final String bypass;

  void applyToSettings(AppSettings settings) {
    settings
      ..proxyMode = mode
      ..proxyHost = host
      ..proxyPort = port
      ..proxyUser = username
      ..proxyPass = password
      ..proxyBypass = bypass;
  }

  /// 手动配置不完整时按直连运行，避免把请求发往不存在的代理。
  ProxyConfig get effective {
    if (mode == ProxyMode.manual && !hasValidManualTarget) {
      return const ProxyConfig(mode: ProxyMode.direct);
    }
    return this;
  }

  /// Rust 网络层接受的模式名。
  String get rustModeName => switch (mode) {
    ProxyMode.system => 'system',
    ProxyMode.direct => 'direct',
    ProxyMode.manual => 'manual',
  };

  /// Rust 网络层接受的主机形式，IPv6 地址带方括号。
  String get rustHost {
    final target = normalizedHost;
    if (target.contains(':') && !target.startsWith('[')) {
      return '[$target]';
    }
    return target;
  }

  bool get hasValidManualTarget {
    final target = normalizedHost;
    if (target.isEmpty) return false;
    if (target.contains(RegExp(r'[\s/\\]'))) return false;
    final port = resolvedPort;
    return port >= 1 && port <= 65535;
  }

  /// 去掉协议前缀、路径与端口，输入 `http://127.0.0.1:7890` 也能用。
  String get normalizedHost => _hostAndPort.host;

  /// 手动代理实际使用的端口；`host` 中附带端口时以该端口为准。
  int get resolvedPort => _hostAndPort.port ?? port;

  String get _hostWithoutScheme {
    var value = host.trim();
    final lower = value.toLowerCase();
    if (lower.startsWith('http://')) {
      value = value.substring(7);
    } else if (lower.startsWith('https://')) {
      value = value.substring(8);
    }
    final slash = value.indexOf('/');
    if (slash >= 0) value = value.substring(0, slash);
    return value.trim();
  }

  _HostAndPort get _hostAndPort => _parseHostAndPort(_hostWithoutScheme);

  /// 拆分 `host:port` 与 `[v6]:port`，裸 IPv6 地址整体作为主机。
  static _HostAndPort _parseHostAndPort(String value) {
    if (value.startsWith('[')) {
      final end = value.indexOf(']');
      if (end <= 0) return const _HostAndPort('', null);
      final host = value.substring(1, end);
      final rest = value.substring(end + 1).trim();
      if (rest.isEmpty) return _HostAndPort(host, null);
      if (!rest.startsWith(':')) return const _HostAndPort('', null);
      final parsed = int.tryParse(rest.substring(1));
      if (parsed == null) return _HostAndPort(host, null);
      return _HostAndPort(host, parsed);
    }
    final separator = value.indexOf(':');
    if (separator < 0) return _HostAndPort(value, null);
    if (separator != value.lastIndexOf(':')) return _HostAndPort(value, null);
    final parsed = int.tryParse(value.substring(separator + 1));
    if (parsed == null) return const _HostAndPort('', null);
    return _HostAndPort(value.substring(0, separator), parsed);
  }

  /// `PROXY host:port` 形式的 PAC 规则。
  String get proxyRule {
    final target = normalizedHost;
    final authority = target.contains(':') && !target.startsWith('[')
        ? '[$target]:$resolvedPort'
        : '$target:$resolvedPort';
    return 'PROXY $authority';
  }

  List<String> get bypassRules => bypass
      .split(RegExp(r'[,;\s]+'))
      .map((rule) => rule.trim().toLowerCase())
      .where((rule) => rule.isNotEmpty)
      .toList(growable: false);

  /// 传给 Rust 的绕过列表：只保留用户规则（含默认 loopback），去重并保持顺序。
  String get rustBypass {
    final seen = <String>{};
    final merged = <String>[];
    for (final entry in bypass.split(RegExp(r'[,;\s]+'))) {
      final value = entry.trim();
      if (value.isEmpty || !seen.add(value.toLowerCase())) continue;
      merged.add(value);
    }
    return merged.join(',');
  }

  /// 返回给 `HttpClient.findProxy` 的规则。
  ///
  /// [ProxyMode.manual] 下除 loopback 与用户 bypass 外一律走代理，由代理
  /// 软件自行决定国内直连或境外转发。
  String findProxyFor(Uri uri) {
    switch (mode) {
      case ProxyMode.direct:
        return 'DIRECT';
      case ProxyMode.system:
        return HttpClient.findProxyFromEnvironment(uri);
      case ProxyMode.manual:
        if (!hasValidManualTarget || shouldBypass(uri.host)) {
          return 'DIRECT';
        }
        return proxyRule;
    }
  }

  bool shouldBypass(String host) {
    final target = _normalizedHostName(host);
    if (target.isEmpty) return false;
    if (_alwaysDirectHosts.contains(target)) return true;
    if (target.endsWith('.localhost')) return true;
    for (final rule in bypassRules) {
      if (_matchesBypassRule(target, rule)) return true;
    }
    return false;
  }

  static const _alwaysDirectHosts = {'localhost', '127.0.0.1', '::1'};

  static String _normalizedHostName(String host) {
    var value = host.trim().toLowerCase();
    if (value.startsWith('[') && value.endsWith(']')) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }

  static bool _matchesBypassRule(String host, String rule) {
    if (rule == '<local>') return !host.contains('.');
    var value = rule;
    if (value.startsWith('*.')) {
      final suffix = value.substring(1);
      return host.endsWith(suffix) || host == value.substring(2);
    }
    if (value.startsWith('.')) {
      return host == value.substring(1) || host.endsWith(value);
    }
    if (value.startsWith('[')) {
      final end = value.indexOf(']');
      if (end > 0) value = value.substring(1, end);
    } else if (value.contains(':') &&
        value.indexOf(':') == value.lastIndexOf(':')) {
      final port = int.tryParse(value.substring(value.lastIndexOf(':') + 1));
      if (port != null) value = value.substring(0, value.lastIndexOf(':'));
    }
    if (value.contains('*')) {
      final wildcard = value.split('*').map(RegExp.escape).join('.*');
      return RegExp('^$wildcard\$').hasMatch(host);
    }
    return host == value || host.endsWith('.$value');
  }

  /// 不输出密码，避免日志泄露凭据。
  @override
  String toString() {
    final user = username.isEmpty ? '' : '***';
    return 'ProxyConfig(mode: ${mode.name}, host: $host, port: $port, '
        'user: $user, bypass: $bypass)';
  }
}

class _HostAndPort {
  const _HostAndPort(this.host, this.port);

  final String host;
  final int? port;
}

/// 把代理配置应用到单个 [HttpClient]。
///
/// 主 isolate 通过 [AppHttpOverrides] 自动覆盖所有 `HttpClient()`；
/// isolate 内的客户端不继承全局覆盖，需要显式调用本函数。
void applyProxyToHttpClient(HttpClient client, ProxyConfig config) {
  final effective = config.effective;
  switch (effective.mode) {
    case ProxyMode.direct:
      client.findProxy = (_) => 'DIRECT';
      break;
    case ProxyMode.system:
      client.findProxy = (uri) => HttpClient.findProxyFromEnvironment(uri);
      break;
    case ProxyMode.manual:
      client.findProxy = effective.findProxyFor;
      final username = effective.username.trim();
      if (username.isNotEmpty) {
        client.authenticateProxy = (host, port, scheme, realm) async {
          client.addProxyCredentials(
            host,
            port,
            realm ?? '',
            HttpClientBasicCredentials(username, effective.password),
          );
          return true;
        };
      }
      break;
  }
}

/// 全局 `HttpOverrides`，覆盖 `Image.network` 与手写 `HttpClient()`。
class AppHttpOverrides extends HttpOverrides {
  AppHttpOverrides({required this.config});

  final ProxyConfig config;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    // Dio 的 IO 适配器直接转发响应流，不做解压；关闭自动解压会让 gzip
    // 响应以压缩字节进入 JSON 与图片解析，最终表现为 DioException(unknown)。
    client.autoUncompress = true;
    applyProxyToHttpClient(client, config);
    return client;
  }
}

/// 保存运行期生效的代理配置，并把全局覆盖安装到主 isolate。
class NetworkProxy {
  NetworkProxy._();

  static final NetworkProxy instance = NetworkProxy._();

  ProxyConfig _config = const ProxyConfig();

  ProxyConfig get config => _config;

  /// 必须在创建任何网络客户端之前调用；重复调用会替换全局覆盖。
  void apply(ProxyConfig config) {
    _config = config.effective;
    HttpOverrides.global = AppHttpOverrides(config: _config);
  }

  String? _appliedRustSignature;

  /// 把代理配置同步给 Rust 网络层（网易云、AMLL 等请求共用）。
  ///
  /// 手动配置不完整时按直连同步，与 [apply] 的生效结果一致。调用失败只记录
  /// 告警，Dart 侧代理与启动流程继续使用已有配置；相同配置重复调用会跳过。
  Future<void> applyToRust(ProxyConfig config) async {
    final effective = config.effective;
    final isManual = effective.mode == ProxyMode.manual;
    final username = isManual ? effective.username.trim() : '';
    final host = isManual ? effective.rustHost : '';
    final port = isManual ? effective.resolvedPort : 0;
    // Rust 的网易云、QQ、酷狗请求共用这份 bypass，只排除用户配置的地址。
    final bypass = isManual ? effective.rustBypass : '';
    // Rust 拒绝无用户名的密码，Dart 侧同样不使用该密码。
    final password = username.isEmpty ? '' : effective.password;
    final signature = [
      effective.rustModeName,
      host,
      '$port',
      username,
      password,
      bypass,
    ].join('\u0000');
    if (signature == _appliedRustSignature) return;
    try {
      await rust_network_proxy.setNetworkProxy(
        mode: effective.rustModeName,
        host: host,
        port: port,
        username: username,
        password: password,
        bypass: bypass,
      );
      _appliedRustSignature = signature;
    } catch (error, trace) {
      log.app.warn(
        'legacy',
        '[network] Rust 代理设置失败（mode: ${config.mode.name}）',
        fields: {'mode': config.mode.name},
        error: error,
        stackTrace: trace,
      );
    }
  }

  HttpClient createHttpClient({SecurityContext? context}) {
    return AppHttpOverrides(config: _config).createHttpClient(context);
  }

  /// 强制直连的客户端，作为代理连接失败后的回退。
  HttpClient createDirectHttpClient({SecurityContext? context}) {
    return AppHttpOverrides(
      config: const ProxyConfig(mode: ProxyMode.direct),
    ).createHttpClient(context);
  }
}
