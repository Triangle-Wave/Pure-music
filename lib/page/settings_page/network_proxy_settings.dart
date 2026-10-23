import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/app_http.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/network_proxy.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/settings_page/tabs/settings_section_header.dart';

class NetworkProxySettingsPanel extends StatefulWidget {
  const NetworkProxySettingsPanel({super.key});

  @override
  State<NetworkProxySettingsPanel> createState() =>
      _NetworkProxySettingsPanelState();
}

class _NetworkProxySettingsPanelState extends State<NetworkProxySettingsPanel> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _bypassController = TextEditingController();

  ProxyMode _mode = ProxyMode.system;
  bool _saving = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _loadFromSettings();
  }

  void _loadFromSettings() {
    final settings = AppSettings.instance;
    _mode = settings.proxyMode;
    _hostController.text = settings.proxyHost;
    _portController.text = '${settings.proxyPort}';
    _userController.text = settings.proxyUser;
    _passController.text = settings.proxyPass;
    _bypassController.text = settings.proxyBypass;
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _userController.dispose();
    _passController.dispose();
    _bypassController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final settings = AppSettings.instance;
    final portText = _portController.text.trim();
    final port = portText.isEmpty ? null : int.tryParse(portText);
    if (portText.isNotEmpty && (port == null || port < 1 || port > 65535)) {
      showTextOnSnackBar('端口需为 1-65535 的数字', variant: ToastVariant.error);
      return;
    }
    final config = ProxyConfig(
      mode: _mode,
      host: _hostController.text.trim(),
      port: port ?? settings.proxyPort,
      username: _userController.text.trim(),
      password: _passController.text,
      bypass: _bypassController.text.trim(),
    );
    final previous = ProxyConfig.fromSettings(settings);
    var saved = false;
    setState(() => _saving = true);
    try {
      config.applyToSettings(settings);
      saved = await settings.saveSettings();
      if (!saved) {
        previous.applyToSettings(settings);
        _loadFromSettings();
        if (mounted) {
          showTextOnSnackBar('代理设置保存失败', variant: ToastVariant.error);
        }
        return;
      }
      NetworkProxy.instance.apply(config);
      AppHttp.instance.rebuild();
      await NetworkProxy.instance.applyToRust(config);
      if (!mounted) return;
      if (config.mode == ProxyMode.manual && !config.hasValidManualTarget) {
        showTextOnSnackBar('代理地址不完整，已回退直连', variant: ToastVariant.error);
      } else {
        showTextOnSnackBar('代理设置已保存，图片等静态缓存需重启生效');
      }
    } catch (error, trace) {
      if (!saved) {
        previous.applyToSettings(settings);
        _loadFromSettings();
      }
      try {
        NetworkProxy.instance.apply(previous);
        AppHttp.instance.rebuild();
        await NetworkProxy.instance.applyToRust(previous);
      } catch (recoverError, recoverTrace) {
        log.settings.error(
          'legacy',
          '[network] 恢复代理配置失败',
          error: recoverError,
          stackTrace: recoverTrace,
        );
      }
      log.settings.error(
        'legacy',
        '[network] 保存代理设置失败',
        error: error,
        stackTrace: trace,
      );
      if (mounted) {
        showTextOnSnackBar('代理设置应用失败', variant: ToastVariant.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _modeSubtitle() {
    return switch (_mode) {
      ProxyMode.system => '读取 http_proxy / https_proxy 环境变量',
      ProxyMode.direct => '所有网络请求直连',
      ProxyMode.manual => '在线歌词、封面、Last.fm 与更新检查统一走代理',
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        const SettingsSectionHeader('网络'),
        const SizedBox(height: 4.0),
        SettingsTile(
          description: '代理模式',
          subtitle: _modeSubtitle(),
          action: SegmentedButton<ProxyMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ProxyMode.system, label: Text('系统')),
              ButtonSegment(value: ProxyMode.direct, label: Text('直连')),
              ButtonSegment(value: ProxyMode.manual, label: Text('手动')),
            ],
            selected: {_mode},
            onSelectionChanged: _saving
                ? null
                : (value) => setState(() => _mode = value.first),
          ),
        ),
        if (_mode == ProxyMode.manual) ...[
          const SizedBox(height: 16.0),
          _textField(
            label: '主机',
            controller: _hostController,
            hint: '127.0.0.1',
          ),
          const SizedBox(height: 16.0),
          _textField(
            label: '端口',
            controller: _portController,
            hint: '$defaultProxyPort',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 16.0),
          _textField(
            label: '用户名',
            controller: _userController,
            hint: '可选',
          ),
          const SizedBox(height: 16.0),
          _textField(
            label: '密码',
            controller: _passController,
            hint: '可选',
            obscure: _obscurePassword,
            suffix: IconButton(
              icon: Icon(
                _obscurePassword ? Symbols.visibility : Symbols.visibility_off,
              ),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          const SizedBox(height: 16.0),
          _textField(
            label: '绕过列表',
            controller: _bypassController,
            hint: 'localhost,127.0.0.1,::1',
          ),
          const SizedBox(height: 8.0),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0),
            child: Text(
              '逗号、分号或空格分隔；支持 *.example.com 与 example.com'
              '（含子域名）。本地地址始终直连。',
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        const SizedBox(height: 20.0),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Symbols.save, size: 18),
            label: Text(_saving ? '保存中' : '保存代理设置'),
          ),
        ),
        const SizedBox(height: 24.0),
        const SettingsSectionHeader('说明'),
        const SizedBox(height: 4.0),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
          child: Text(
            '系统模式只读取 http_proxy / https_proxy / no_proxy 环境变量；'
            'Dart 不读取 Windows 注册表中的系统代理，需要跟随 Windows '
            '代理设置时请使用手动模式。',
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  Widget _textField({
    required String label,
    required TextEditingController controller,
    String? hint,
    bool obscure = false,
    TextInputType? keyboardType,
    Widget? suffix,
  }) {
    return SettingsTile(
      description: label,
      action: SizedBox(
        width: 260,
        child: Focus(
          onFocusChange: (focused) {
            unawaited(HotkeysHelper.onFocusChanges(focused));
          },
          child: TextField(
            controller: controller,
            enabled: !_saving,
            obscureText: obscure,
            enableSuggestions: false,
            autocorrect: false,
            keyboardType: keyboardType,
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              border: const OutlineInputBorder(),
              suffixIcon: suffix,
            ),
          ),
        ),
      ),
    );
  }
}
