import 'dart:async';

import 'package:flutter/material.dart';
import 'package:github/github.dart' as gh;
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/component/stacked_list_view.dart'
    show SmoothScrollListView;
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/update_checker.dart';
import 'package:pure_music/core/update_route.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/native/rust/api/utils.dart' as rust_utils;
import 'package:pure_music/page/settings_page/check_update.dart';
import 'package:pure_music/page/settings_page/create_issue.dart';
import 'package:pure_music/page/settings_page/tabs/settings_section_header.dart';

class AboutTabContent extends StatelessWidget {
  const AboutTabContent({
    super.key,
    this.contributorsSection = const _AboutContributorsSection(),
  });

  final Widget contributorsSection;

  @override
  Widget build(BuildContext context) {
    return SmoothScrollListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        const SettingsSectionHeader('更新'),
        const SizedBox(height: 4.0),
        const _AboutVersionItem(),
        const SizedBox(height: 16.0),
        const _AboutUpdateSourceItem(),
        const SizedBox(height: 16.0),
        const _AboutDownloadRouteItem(),
        const SizedBox(height: 16.0),
        const _AboutAutoUpdateItem(),
        const SizedBox(height: 24.0),
        const SettingsSectionHeader('相关链接'),
        const SizedBox(height: 4.0),
        const _AboutLinkItem(
          title: '官方网站',
          url: 'https://qingyueyin.github.io/Pure-music/',
          actionLabel: '访问官网',
          icon: Symbols.language,
        ),
        const SizedBox(height: 16.0),
        const _AboutLinkItem(
          title: '项目主页',
          url: 'https://github.com/Triangle-Wave/Pure-music',
          actionLabel: '打开仓库',
          icon: Symbols.code,
        ),
        const SizedBox(height: 16.0),
        const _AboutLinkItem(
          title: '交流群组',
          url: 'https://t.me/+NsZamWiEKh5lOWNl',
          actionLabel: '加入群组',
          icon: Symbols.send,
        ),
        const SizedBox(height: 16.0),
        const CreateIssueTile(),
        contributorsSection,
      ],
    );
  }
}

class _AboutContributorsSection extends StatefulWidget {
  const _AboutContributorsSection();

  @override
  State<_AboutContributorsSection> createState() =>
      _AboutContributorsSectionState();
}

class _AboutContributorsSectionState extends State<_AboutContributorsSection> {
  static List<_AboutContributor>? _cachedContributors;
  static Future<List<_AboutContributor>>? _pendingRequest;

  late List<_AboutContributor> _contributors;

  @override
  void initState() {
    super.initState();
    _contributors = _cachedContributors ?? const [];
    if (_cachedContributors == null) _loadContributors();
  }

  Future<void> _loadContributors() async {
    try {
      final contributors = await _getContributors();
      if (!mounted) return;
      setState(() => _contributors = contributors);
    } catch (error, trace) {
      log.settings.warn(
        'legacy',
        '[About] contributors request failed: ${error.runtimeType}',
      );
      log.settings.debug('legacy', trace.toString());
    }
  }

  static Future<List<_AboutContributor>> _getContributors() async {
    final cached = _cachedContributors;
    if (cached != null) return cached;

    final pending = _pendingRequest;
    if (pending != null) return pending;

    final request = _fetchContributors();
    _pendingRequest = request;
    try {
      final contributors = await request;
      _cachedContributors = contributors;
      return contributors;
    } finally {
      if (identical(_pendingRequest, request)) _pendingRequest = null;
    }
  }

  static Future<List<_AboutContributor>> _fetchContributors() async {
    final slug = gh.RepositorySlug.full(AppPreference.defaultUpdateRepoSlug);
    final response = await AppSettings.github.repositories
        .listContributors(slug, anon: true)
        .toList()
        .timeout(const Duration(seconds: 15));
    final contributors = response
        .where((item) {
          final login = item.login?.trim();
          final type = item.type?.toLowerCase();
          return login != null &&
              login.isNotEmpty &&
              type != 'bot' &&
              !login.toLowerCase().endsWith('[bot]');
        })
        .map(_AboutContributor.fromGitHub)
        .toList();
    contributors.sort((left, right) {
      final contributionOrder = right.contributions.compareTo(
        left.contributions,
      );
      if (contributionOrder != 0) return contributionOrder;
      return left.login.toLowerCase().compareTo(right.login.toLowerCase());
    });
    return List.unmodifiable(contributors);
  }

  @override
  Widget build(BuildContext context) {
    if (_contributors.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SettingsSectionHeader('贡献者'),
          const SizedBox(height: 8.0),
          LayoutBuilder(builder: (context, constraints) => _contributorWrap(constraints)),
        ],
      ),
    );
  }

  Widget _contributorWrap(BoxConstraints constraints) {
    final columns = constraints.maxWidth >= 720
        ? 3
        : constraints.maxWidth >= 460
        ? 2
        : 1;
    final tileWidth =
        (constraints.maxWidth - (columns - 1) * Spacing.sm) / columns;
    return Wrap(
      spacing: Spacing.sm,
      runSpacing: Spacing.sm,
      children: [
        for (final contributor in _contributors)
          _ContributorTile(contributor: contributor, width: tileWidth),
      ],
    );
  }


}

class _AboutContributor {
  const _AboutContributor({
    required this.login,
    required this.avatarUrl,
    required this.profileUrl,
    required this.contributions,
  });

  factory _AboutContributor.fromGitHub(gh.Contributor contributor) {
    final login = contributor.login!.trim();
    return _AboutContributor(
      login: login,
      avatarUrl: contributor.avatarUrl?.trim(),
      profileUrl: contributor.htmlUrl?.trim().isNotEmpty == true
          ? contributor.htmlUrl!.trim()
          : 'https://github.com/$login',
      contributions: contributor.contributions ?? 0,
    );
  }

  final String login;
  final String? avatarUrl;
  final String profileUrl;
  final int contributions;
}

class _ContributorTile extends StatelessWidget {
  const _ContributorTile({required this.contributor, required this.width});

  final _AboutContributor contributor;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      height: 60.0,
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: AppRadius.smCircular,
        child: InkWell(
          borderRadius: AppRadius.smCircular,
          onTap: () => _openProfile(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            child: Row(
              children: [
                _ContributorAvatar(contributor: contributor),
                const SizedBox(width: 10.0),
                Expanded(child: _info(scheme)),
                Icon(Symbols.open_in_new, size: 16, color: scheme.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openProfile(BuildContext context) async {
    final opened = await rust_utils.launchInBrowser(
      uri: contributor.profileUrl,
    );
    if (!opened && context.mounted) {
      showTextOnSnackBar('打开链接失败');
    }
  }

  Widget _info(ColorScheme scheme) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          contributor.login,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: AppType.body,
            fontWeight: AppType.weightSemibold,
          ),
        ),
        Text(
          '${contributor.contributions} 次贡献',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: AppType.caption,
          ),
        ),
      ],
    );
  }
}

class _ContributorAvatar extends StatelessWidget {
  const _ContributorAvatar({required this.contributor});

  final _AboutContributor contributor;

  @override
  Widget build(BuildContext context) {
    final login = contributor.login;
    final initials = login.substring(0, login.length > 2 ? 2 : login.length);
    final avatarUrl = contributor.avatarUrl;
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: 18,
      backgroundColor: scheme.secondaryContainer,
      foregroundColor: scheme.onSecondaryContainer,
      child: avatarUrl?.isNotEmpty == true
          ? ClipOval(
              child: Image.network(
                avatarUrl!,
                width: 36,
                height: 36,
                fit: BoxFit.cover,
                cacheWidth: 72,
                cacheHeight: 72,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => Text(initials.toUpperCase()),
              ),
            )
          : Text(initials.toUpperCase()),
    );
  }
}

class _AboutVersionItem extends StatefulWidget {
  const _AboutVersionItem();

  @override
  State<_AboutVersionItem> createState() => _AboutVersionItemState();
}

class _AboutVersionItemState extends State<_AboutVersionItem> {
  bool _isChecking = false;

  Future<void> _check() async {
    if (_isChecking) return;
    setState(() => _isChecking = true);

    try {
      final channel = await ensureUpdateChannel();
      if (!mounted) return;
      final newest = await UpdateChecker.checkForUpdate();
      if (!mounted) return;

      if (newest != null &&
          UpdateChecker.hasNewVersion(newest.tagName, AppSettings.version)) {
        unawaited(
          showDialog<void>(
            context: context,
            builder: (context) =>
                NewestUpdateView(info: newest, channel: channel),
          ),
        );
      } else {
        showTextOnSnackBar('无新版本');
      }
    } catch (err, trace) {
      log.settings.error('legacy', err.toString(), stackTrace: trace);
      if (mounted) {
        showTextOnSnackBar(
          err is UpdateCheckException ? err.message : '检查更新失败，请稍后再试',
        );
      }
    } finally {
      if (mounted) setState(() => _isChecking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '当前版本',
      subtitle: AppSettings.version,
      action: FilledButton.tonalIcon(
        onPressed: _isChecking ? null : _check,
        icon: _isChecking
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Symbols.update, size: 18),
        label: Text(_isChecking ? '检查中' : '检查更新'),
      ),
    );
  }
}

class _AboutUpdateSourceItem extends StatelessWidget {
  const _AboutUpdateSourceItem();

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '更新源',
      subtitle: 'GitHub · ${AppPreference.defaultUpdateRepoSlug}',
      action: const Icon(Symbols.check_circle, size: 18),
    );
  }
}

class _AboutDownloadRouteItem extends StatefulWidget {
  const _AboutDownloadRouteItem();

  @override
  State<_AboutDownloadRouteItem> createState() =>
      _AboutDownloadRouteItemState();
}

class _AboutDownloadRouteItemState extends State<_AboutDownloadRouteItem> {
  var _saving = false;

  Future<void> _select(UpdateDownloadRoute route) async {
    final preference = AppPreference.instance;
    if (_saving || preference.updateDownloadRoute == route) return;
    final previous = preference.updateDownloadRoute;
    setState(() {
      preference.updateDownloadRoute = route;
      _saving = true;
    });
    final saved = await preference.save();
    if (!mounted) return;
    if (!saved) {
      preference.updateDownloadRoute = previous;
      showTextOnSnackBar('保存下载线路失败', variant: ToastVariant.error);
    }
    setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final route = AppPreference.instance.updateDownloadRoute;
    final scheme = Theme.of(context).colorScheme;
    final usesProxy =
        route == UpdateDownloadRoute.auto ||
        route == UpdateDownloadRoute.proxy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsTile(
          description: '下载线路',
          subtitle: route.description,
          action: DropdownMenu<UpdateDownloadRoute>(
            key: ValueKey('update-download-route-${route.name}'),
            initialSelection: route,
            width: 200,
            enableFilter: false,
            requestFocusOnTap: false,
            dropdownMenuEntries: [
              for (final value in UpdateDownloadRoute.values)
                DropdownMenuEntry<UpdateDownloadRoute>(
                  value: value,
                  label: value.label,
                ),
            ],
            onSelected: _saving
                ? null
                : (value) {
                    if (value != null) unawaited(_select(value));
                  },
          ),
        ),
        if (usesProxy)
          Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Symbols.info, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6.0),
                Expanded(
                  child: Text(
                    '加速代理为第三方服务，可能看到下载内容与你的 IP；'
                    '校验值取自官方清单（GitHub 直连或 Gitee），'
                    '代理只承担安装包传输。',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: AppType.caption,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _AboutAutoUpdateItem extends StatefulWidget {
  const _AboutAutoUpdateItem();

  @override
  State<_AboutAutoUpdateItem> createState() => _AboutAutoUpdateItemState();
}

class _AboutAutoUpdateItemState extends State<_AboutAutoUpdateItem> {
  @override
  Widget build(BuildContext context) {
    final enabled = AppPreference.instance.autoCheckUpdate;
    return SettingsTile(
      description: '启动时自动检查更新',
      subtitle: enabled ? '已开启' : '已关闭',
      action: Switch(
        value: enabled,
        onChanged: (value) async {
          setState(() => AppPreference.instance.autoCheckUpdate = value);
          await AppPreference.instance.save();
        },
      ),
    );
  }
}

class _AboutLinkItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String url;
  final String actionLabel;

  const _AboutLinkItem({
    required this.icon,
    required this.title,
    required this.url,
    required this.actionLabel,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: title,
      action: FilledButton.tonalIcon(
        onPressed: () async {
          final opened = await rust_utils.launchInBrowser(uri: url);
          if (!opened) {
            showTextOnSnackBar('打开链接失败');
          }
        },
        icon: Icon(icon, size: 18),
        label: Text(actionLabel),
      ),
    );
  }
}
