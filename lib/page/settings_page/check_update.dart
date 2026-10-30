import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/update_checker.dart';
import 'package:pure_music/core/update_download_monitor.dart';
import 'package:pure_music/core/update_installer.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/native/rust/api/utils.dart' as rust_utils;

Future<void> _launchBrowserUrl(String uri) async {
  final opened = await rust_utils.launchInBrowser(uri: uri);
  if (!opened) {
    showTextOnSnackBar('打开链接失败');
  }
}

Future<UpdateChannel> ensureUpdateChannel() async {
  const channel = UpdateChannel.supported;
  final preference = AppPreference.instance;
  if (UpdateChannel.parse(preference.updateChannel) == channel) {
    return channel;
  }
  final previous = preference.updateChannel;
  preference.updateChannel = channel.name;
  if (!await preference.save()) {
    preference.updateChannel = previous;
    log.settings.warn('legacy', '[Update] 保存更新渠道失败');
  }
  return channel;
}

String _formatMb(int bytes) {
  if (bytes <= 0) return '0 MB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

enum _UpdatePhase {
  idle,
  checking,
  downloading,
  preparing,
  verifying,
  installing,
  ready,
  error,
}

Future<void> showTrackedUpdateDialog(BuildContext context) {
  final monitor = UpdateDownloadMonitor.instance;
  final info = monitor.info;
  final channel = monitor.channel;
  if (info == null || channel == null || monitor.dialogOpen) {
    return Future<void>.value();
  }
  return showDialog<void>(
    context: context,
    builder: (context) => NewestUpdateView(info: info, channel: channel),
  );
}

class NewestUpdateView extends StatefulWidget {
  const NewestUpdateView({
    super.key,
    required this.info,
    required this.channel,
  });

  final UpdateInfo info;
  final UpdateChannel channel;

  @override
  State<NewestUpdateView> createState() => _NewestUpdateViewState();
}

class _NewestUpdateViewState extends State<NewestUpdateView> {
  _UpdatePhase _phase = _UpdatePhase.idle;
  int _received = 0;
  int _total = 0;
  late UpdateInfo _info;
  late UpdateChannel _channel;
  String? _errorMessage;
  var _mirroring = false;
  UpdateMonitorPhase _seenMonitorPhase = UpdateMonitorPhase.idle;

  UpdateDownloadMonitor get _monitor => UpdateDownloadMonitor.instance;

  @override
  void initState() {
    super.initState();
    _info = widget.info;
    _channel = widget.channel;
    _monitor.noteDialogOpened();
    _monitor.addListener(_onMonitor);
    _seenMonitorPhase = _monitor.phase;
    _applyMonitor();
  }

  @override
  void dispose() {
    _monitor.removeListener(_onMonitor);
    _monitor.noteDialogClosed();
    super.dispose();
  }

  void _onMonitor() {
    final previous = _seenMonitorPhase;
    _seenMonitorPhase = _monitor.phase;
    _applyMonitor();
    if (!mounted) return;
    if (previous != UpdateMonitorPhase.failed &&
        _monitor.phase == UpdateMonitorPhase.failed &&
        _errorMessage != null) {
      showTextOnSnackBar(_errorMessage!, variant: ToastVariant.error);
    }
    setState(() {});
  }

  void _applyMonitor() {
    if (_monitor.phase == UpdateMonitorPhase.idle) {
      if (!_mirroring) return;
      _mirroring = false;
      _phase = _UpdatePhase.idle;
      _errorMessage = null;
      _received = 0;
      return;
    }
    if (_monitor.info?.tagName != widget.info.tagName &&
        _monitor.info?.tagName != _info.tagName) {
      return;
    }
    _mirroring = true;
    final info = _monitor.info;
    final channel = _monitor.channel;
    if (info != null) _info = info;
    if (channel != null) _channel = channel;
    _received = _monitor.received;
    _total = _monitor.total;
    switch (_monitor.phase) {
      case UpdateMonitorPhase.idle:
        break;
      case UpdateMonitorPhase.downloading:
        _phase = _UpdatePhase.downloading;
        _errorMessage = null;
      case UpdateMonitorPhase.verifying:
        _phase = _UpdatePhase.verifying;
        _errorMessage = null;
      case UpdateMonitorPhase.preparing:
        _phase = _UpdatePhase.preparing;
        _errorMessage = null;
      case UpdateMonitorPhase.installing:
        _phase = _UpdatePhase.installing;
        _errorMessage = null;
      case UpdateMonitorPhase.ready:
        _phase = _UpdatePhase.ready;
        _errorMessage = null;
      case UpdateMonitorPhase.failed:
        _phase = _UpdatePhase.error;
        _errorMessage = _monitor.errorMessage ?? '更新失败';
    }
  }

  String? get _updateUrl {
    final url = _info.releasePageUrl(_channel)?.trim();
    if (url == null || url.isEmpty) return null;
    return url;
  }

  Future<void> _startUpdate() async {
    if (_busy || _phase == _UpdatePhase.ready) return;
    final downloadUrl = _info.downloadUrl(
      channel: _channel,
      portableBuild: portableBuild,
    );
    if (downloadUrl == null || downloadUrl.isEmpty) {
      await _missingDownloadUrl();
      return;
    }
    await _monitor.startDownload(_info, _channel);
  }

  Future<void> _missingDownloadUrl() async {
    if (_updateUrl != null) {
      await _openReleasePage();
      if (!mounted) return;
      Navigator.pop(context);
      return;
    }
    if (mounted) {
      showTextOnSnackBar('缺少下载地址', variant: ToastVariant.error);
    }
  }

  Future<void> _openReleasePage() async {
    final updateUrl = _updateUrl;
    if (updateUrl == null) return;
    await _launchBrowserUrl(updateUrl);
  }

  Future<void> _retry() async {
    if (_busy) return;
    setState(() {
      _phase = _UpdatePhase.checking;
      _errorMessage = null;
    });
    try {
      final newest = await UpdateChecker.checkForUpdate();
      if (!mounted) return;
      if (newest == null ||
          !UpdateChecker.hasNewVersion(newest.tagName, AppSettings.version)) {
        throw UpdateInstallException('GitHub 暂未提供可用的新版本');
      }
      final hasDownload = newest
          .downloadUrl(
            channel: UpdateChannel.supported,
            portableBuild: portableBuild,
          )
          ?.isNotEmpty;
      if (hasDownload != true) {
        throw UpdateInstallException('GitHub 暂未提供对应安装包');
      }
      setState(() {
        _channel = UpdateChannel.supported;
        _info = newest;
        _phase = _UpdatePhase.idle;
      });
      await _startUpdate();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _UpdatePhase.error;
        _errorMessage = error is UpdateInstallException
            ? error.message
            : '无法从 GitHub 获取更新';
      });
    }
  }

  void _cancel() {
    _monitor.cancel();
  }

  String get _progressLabel {
    final received = _received;
    final total = _total;
    if (total > 0) {
      final percent = ((received / total) * 100).clamp(0, 100).round();
      return '$percent% · ${_formatMb(received)} / ${_formatMb(total)}';
    }
    return _formatMb(received);
  }

  String get _statusLabel {
    switch (_phase) {
      case _UpdatePhase.idle:
        return '准备安装';
      case _UpdatePhase.checking:
        return '正在检查更新';
      case _UpdatePhase.downloading:
        return '正在下载 $_progressLabel';
      case _UpdatePhase.preparing:
        return '正在解压更新';
      case _UpdatePhase.verifying:
        return '正在校验完整性';
      case _UpdatePhase.installing:
        return portableBuild ? '正在切换到新版本' : '正在启动安装程序';
      case _UpdatePhase.ready:
        return '更新已下载，可以安装';
      case _UpdatePhase.error:
        return _errorMessage ?? '更新失败';
    }
  }

  bool get _busy =>
      _phase == _UpdatePhase.checking ||
      _phase == _UpdatePhase.downloading ||
      _phase == _UpdatePhase.preparing ||
      _phase == _UpdatePhase.verifying ||
      _phase == _UpdatePhase.installing;

  bool get _hasDownload =>
      _info
          .downloadUrl(channel: _channel, portableBuild: portableBuild)
          ?.isNotEmpty ==
      true;

  bool get _hasChecksum => _info.hasChecksum(
    channel: _channel,
    portableBuild: portableBuild,
  );

  bool get _canInstall => _hasDownload && _hasChecksum;

  bool get _holdDialog =>
      _phase == _UpdatePhase.checking ||
      _phase == _UpdatePhase.preparing ||
      _phase == _UpdatePhase.installing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48.0).clamp(320.0, 720.0).toDouble();
    final height = (size.height - 96.0).clamp(360.0, 640.0).toDouble();
    return PopScope(
      canPop: !_holdDialog,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(
          horizontal: 24.0,
          vertical: 24.0,
        ),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
        child: SizedBox(
          width: width,
          height: height,
          child: Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(scheme),
                const SizedBox(height: Spacing.md),
                Expanded(child: _changelog(context, scheme)),
                if (_busy) ..._progress(scheme),
                if (_phase == _UpdatePhase.error && _errorMessage != null)
                  ..._error(scheme),
                if (!_busy &&
                    _hasDownload &&
                    !_hasChecksum &&
                    _phase != _UpdatePhase.error)
                  ..._missingChecksumHint(scheme),
                const SizedBox(height: Spacing.lg),
                _actions(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '有新更新',
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: AppType.hero,
            fontWeight: AppType.weightBold,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          '当前 ${AppSettings.version} · ${_info.tagName} · ${_channel.label}',
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: AppType.body,
          ),
        ),
      ],
    );
  }

  Widget _changelog(BuildContext context, ColorScheme scheme) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: AppRadius.mdCircular,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Markdown(
        data: _info.body?.trim().isNotEmpty == true
            ? _info.body!
            : '这个版本暂时没有更新说明。',
        onTapLink: (text, href, title) {
          if (href != null) {
            _launchBrowserUrl(href);
          }
        },
        padding: const EdgeInsets.all(Spacing.md),
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
      ),
    );
  }

  List<Widget> _progress(ColorScheme scheme) {
    return [
      const SizedBox(height: Spacing.md),
      ClipRRect(
        borderRadius: AppRadius.smCircular,
        child: LinearProgressIndicator(
          value: _phase == _UpdatePhase.downloading && _total > 0
              ? (_received / _total).clamp(0.0, 1.0)
              : null,
          minHeight: 6,
        ),
      ),
      const SizedBox(height: Spacing.sm),
      Text(
        _statusLabel,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: AppType.body,
        ),
      ),
    ];
  }

  List<Widget> _error(ColorScheme scheme) {
    return [
      const SizedBox(height: Spacing.sm),
      Text(
        _errorMessage!,
        style: TextStyle(color: scheme.error, fontSize: AppType.body),
      ),
    ];
  }

  List<Widget> _missingChecksumHint(ColorScheme scheme) {
    return [
      const SizedBox(height: Spacing.sm),
      Text(
        '此版本还不能应用内安装，请从网页下载。',
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: AppType.body,
        ),
      ),
    ];
  }

  Widget _actions(BuildContext context) {
    final updateUrl = _updateUrl;
    final hasUpdateUrl = updateUrl?.isNotEmpty == true;
    return OverflowBar(
      alignment: MainAxisAlignment.end,
      spacing: Spacing.sm,
      overflowSpacing: Spacing.sm,
      children: [
        TextButton(
          onPressed: () {
            if (_busy) {
              _cancel();
              return;
            }
            Navigator.pop(context);
          },
          child: Text(_busy ? '取消' : '关闭'),
        ),
        if (_phase == _UpdatePhase.error)
          OutlinedButton.icon(
            onPressed: _retry,
            icon: const Icon(Symbols.refresh, size: 18),
            label: const Text('重试'),
          ),
        _primaryAction(context, hasUpdateUrl),
        if (hasUpdateUrl && _canInstall && !_busy)
          TextButton.icon(
            onPressed: () async {
              await _openReleasePage();
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Symbols.arrow_outward, size: 18),
            label: const Text('打开网页'),
          ),
      ],
    );
  }

  Widget _primaryAction(BuildContext context, bool hasUpdateUrl) {
    if (!_hasDownload && !hasUpdateUrl) {
      return FilledButton.icon(
        onPressed: null,
        icon: const Icon(Symbols.arrow_outward),
        label: const Text('获取更新'),
      );
    }
    if (_busy) {
      return FilledButton.icon(
        onPressed: null,
        icon: const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: const Text('处理中'),
      );
    }
    if (_phase == _UpdatePhase.ready) {
      return FilledButton.icon(
        onPressed: _monitor.install,
        icon: const Icon(Symbols.download),
        label: const Text('安装更新'),
      );
    }
    if (_canInstall) {
      final bytes = _info.downloadSize(portableBuild: portableBuild);
      const action = portableBuild ? '下载更新' : '下载并安装';
      final label = bytes != null && bytes > 0
          ? '$action · ${_formatMb(bytes)}'
          : action;
      return FilledButton.icon(
        onPressed: _startUpdate,
        icon: const Icon(Symbols.download),
        label: Text(label),
      );
    }
    return FilledButton.icon(
      onPressed: hasUpdateUrl
          ? () async {
              await _openReleasePage();
              if (context.mounted) Navigator.pop(context);
            }
          : null,
      icon: const Icon(Symbols.arrow_outward),
      label: const Text('打开网页'),
    );
  }
}

class UpdateTitleStatus extends StatelessWidget {
  const UpdateTitleStatus({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: UpdateDownloadMonitor.instance,
      builder: (context, _) {
        final monitor = UpdateDownloadMonitor.instance;
        if (!monitor.visible) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Material(
          color: scheme.secondaryContainer,
          borderRadius: AppRadius.smCircular,
          clipBehavior: Clip.antiAlias,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: InkWell(
                  onTap: () => showTrackedUpdateDialog(context),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                    child: Text(
                      monitor.titleLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSecondaryContainer,
                        fontSize: AppType.caption,
                        fontWeight: AppType.weightMedium,
                      ),
                    ),
                  ),
                ),
              ),
              if (monitor.canCancel)
                IconButton(
                  tooltip: '取消',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  onPressed: monitor.cancel,
                  icon: Icon(
                    Symbols.close,
                    size: 16,
                    color: scheme.onSecondaryContainer,
                  ),
                )
              else
                const SizedBox(width: 6),
            ],
          ),
        );
      },
    );
  }
}
