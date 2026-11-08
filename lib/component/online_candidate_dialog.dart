import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/log/app_log.dart';

/// 搜索词长度上限：超过该长度的输入先截断，不直接拼进请求。
const int _maxQueryLength = 100;

/// 缩略图 Future 的缓存条目上限。
const int _maxArtworkFutures = 64;

/// 去掉首尾空白并截断到 [_maxQueryLength] 个字符。
String _limitQuery(String raw) {
  final trimmed = raw.trim();
  if (trimmed.runes.length <= _maxQueryLength) return trimmed;
  return String.fromCharCodes(trimmed.runes.take(_maxQueryLength));
}

enum OnlineCandidateAction { auto, select, disable }

class OnlineCandidateChoice {
  const OnlineCandidateChoice._(this.action, this.candidateId);

  const OnlineCandidateChoice.auto()
    : this._(OnlineCandidateAction.auto, null);

  const OnlineCandidateChoice.disabled()
    : this._(OnlineCandidateAction.disable, null);

  const OnlineCandidateChoice.select(String id)
    : this._(OnlineCandidateAction.select, id);

  final OnlineCandidateAction action;
  final String? candidateId;
}

class OnlineCandidateOption {
  const OnlineCandidateOption({
    required this.id,
    required this.source,
    required this.title,
    required this.score,
    this.subtitle,
    this.imageUrl,
  });

  final String id;
  final String source;
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final double score;
}

/// 在线专辑/艺术家候选选择对话框。
///
/// [search] 非空时标题下方显示搜索行：用户可以改写搜索词并重新搜索，返回的
/// 候选替换当前列表。[initialQuery] 是搜索框的初始文本，[defaultQuery] 是
/// 实体默认搜索词（仅“恢复默认”按钮使用），[searchHint] 是占位提示。搜索
/// 失败时保留原列表并提示错误。
Future<OnlineCandidateChoice?> showOnlineCandidateDialog(
  BuildContext context, {
  required String title,
  required List<OnlineCandidateOption> options,
  required String? selectedId,
  required bool disabled,
  required Future<ImageProvider?> Function(String url) artworkLoader,
  String? initialQuery,
  String? defaultQuery,
  Future<List<OnlineCandidateOption>> Function(String query)? search,
  String? searchHint,
}) {
  return showDialog<OnlineCandidateChoice>(
    context: context,
    builder: (context) => _OnlineCandidateDialog(
      title: title,
      options: options,
      selectedId: selectedId,
      disabled: disabled,
      artworkLoader: artworkLoader,
      initialQuery: initialQuery,
      defaultQuery: defaultQuery,
      search: search,
      searchHint: searchHint,
    ),
  );
}

class _OnlineCandidateDialog extends StatefulWidget {
  const _OnlineCandidateDialog({
    required this.title,
    required this.options,
    required this.selectedId,
    required this.disabled,
    required this.artworkLoader,
    this.initialQuery,
    this.defaultQuery,
    this.search,
    this.searchHint,
  });

  final String title;
  final List<OnlineCandidateOption> options;
  final String? selectedId;
  final bool disabled;
  final Future<ImageProvider?> Function(String url) artworkLoader;
  final String? initialQuery;

  /// 实体默认搜索词；“恢复默认”按钮用它重搜，缺失时回退 [initialQuery]。
  final String? defaultQuery;
  final Future<List<OnlineCandidateOption>> Function(String query)? search;
  final String? searchHint;

  @override
  State<_OnlineCandidateDialog> createState() => _OnlineCandidateDialogState();
}

class _OnlineCandidateDialogState extends State<_OnlineCandidateDialog> {
  late final TextEditingController _queryController;
  late List<OnlineCandidateOption> _options;
  bool _searching = false;
  String? _errorText;
  String? _hintText;
  int _searchToken = 0;

  /// 同一 URL 只发起一次加载；搜索状态变化触发重建时复用，避免缩略图闪烁。
  final Map<String, Future<ImageProvider?>> _artworkFutures =
      <String, Future<ImageProvider?>>{};

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(
      text: _limitQuery(widget.initialQuery ?? ''),
    );
    _options = widget.options;
  }

  @override
  void dispose() {
    _artworkFutures.clear();
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String rawQuery) async {
    final search = widget.search;
    if (search == null || _searching) return;
    final query = _limitQuery(rawQuery);
    if (query.isEmpty) {
      setState(() {
        _errorText = '请输入搜索词';
        _hintText = null;
      });
      return;
    }
    final token = ++_searchToken;
    setState(() {
      _searching = true;
      _errorText = null;
      _hintText = null;
    });
    try {
      final results = await search(query);
      if (!mounted || token != _searchToken) return;
      final next = List<OnlineCandidateOption>.unmodifiable(results);
      setState(() {
        _searching = false;
        _errorText = null;
        if (next.isEmpty) {
          // 没有结果时保留调用前的候选，避免列表突然清空。
          _hintText = '该搜索词没有结果，可以换个关键词再试。';
        } else {
          _options = next;
          _hintText = null;
        }
      });
    } catch (error) {
      if (!mounted || token != _searchToken) return;
      log.library.warn(
        'online_candidate_search_failed',
        '在线候选搜索失败',
        fields: {'error': error.runtimeType.toString()},
      );
      // 搜索失败保留调用前的候选，用户仍可选择或取消。
      setState(() {
        _searching = false;
        _hintText = null;
        _errorText = '搜索失败，请稍后重试';
      });
    }
  }

  /// “恢复默认”按钮：填回实体默认词并立即用它搜索。
  void _restoreDefaultQuery() {
    if (_searching) return;
    final preferred = widget.defaultQuery;
    final fallback = preferred != null && preferred.trim().isNotEmpty
        ? preferred
        : (widget.initialQuery ?? '');
    final next = _limitQuery(fallback);
    _queryController.text = next;
    _queryController.selection = TextSelection.collapsed(offset: next.length);
    if (next.isEmpty) {
      setState(() {
        _errorText = null;
        _hintText = null;
      });
      return;
    }
    unawaited(_runSearch(next));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final searchEnabled = widget.search != null;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.title,
            style: TextStyle(
              fontSize: AppType.subtitle,
              fontWeight: AppType.weightSemibold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '结果与选择长期保存在本地，改词会立即重新搜索。',
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: searchEnabled
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _searchRow(scheme),
                    if (_errorText != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                        child: Text(
                          _errorText!,
                          style: TextStyle(
                            fontSize: AppType.caption,
                            color: scheme.error,
                          ),
                        ),
                      ),
                    if (_hintText != null && _options.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                        child: Text(
                          _hintText!,
                          style: TextStyle(
                            fontSize: AppType.caption,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    Flexible(child: _listArea(scheme)),
                  ],
                )
              : _listArea(scheme),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () => Navigator.of(context).pop(
            const OnlineCandidateChoice.auto(),
          ),
          icon: const Icon(Symbols.autorenew, size: 18),
          label: const Text('恢复自动选择'),
        ),
        TextButton.icon(
          onPressed: () => Navigator.of(context).pop(
            const OnlineCandidateChoice.disabled(),
          ),
          style: TextButton.styleFrom(
            foregroundColor: widget.disabled ? scheme.primary : scheme.onSurface,
          ),
          icon: Icon(
            widget.disabled ? Symbols.check_circle : Symbols.visibility_off,
            size: 18,
          ),
          label: const Text('不使用（显示空白）'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }

  Widget _searchRow(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _queryController,
              enabled: !_searching,
              maxLength: _maxQueryLength,
              textInputAction: TextInputAction.search,
              style: TextStyle(fontSize: AppType.body),
              onSubmitted: _searching
                  ? null
                  : (value) => unawaited(_runSearch(value)),
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                hintText: widget.searchHint ?? '搜索词',
                hintStyle: TextStyle(
                  fontSize: AppType.body,
                  color: scheme.onSurfaceVariant,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: AppRadius.smCircular,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '搜索',
            onPressed: _searching
                ? null
                : () => unawaited(_runSearch(_queryController.text)),
            icon: const Icon(Symbols.search, size: 20),
          ),
          IconButton(
            tooltip: '恢复默认搜索词',
            onPressed: _searching ? null : _restoreDefaultQuery,
            icon: const Icon(Symbols.restart_alt, size: 20),
          ),
          if (_searching)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
    );
  }

  Widget _listArea(ColorScheme scheme) {
    if (_options.isEmpty) {
      final text = widget.search == null
          ? '没有可用的在线候选，可以保持“不使用”或稍后刷新。'
          : '该搜索词没有结果，可以换个关键词再试。';
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
        child: Text(
          text,
          style: TextStyle(
            fontSize: AppType.body,
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _options.length,
      itemBuilder: (context, index) => _optionTile(
        context,
        scheme,
        _options[index],
      ),
    );
  }

  Widget _optionTile(
    BuildContext context,
    ColorScheme scheme,
    OnlineCandidateOption option,
  ) {
    final selected = !widget.disabled && option.id == widget.selectedId;
    final subtitle = option.subtitle?.trim();
    return InkWell(
      onTap: _searching
          ? null
          : () => Navigator.of(
              context,
            ).pop(OnlineCandidateChoice.select(option.id)),
      borderRadius: AppRadius.smCircular,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer.withValues(alpha: 0.45)
              : Colors.transparent,
          borderRadius: AppRadius.smCircular,
        ),
        child: Row(
          children: [
            _thumbnail(scheme, option.imageUrl),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    option.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.body,
                      fontWeight: AppType.weightSemibold,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (subtitle != null && subtitle.isNotEmpty) subtitle,
                      option.source,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              option.score.toStringAsFixed(0),
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.78),
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              selected ? Symbols.check_circle : Symbols.chevron_right,
              size: 18,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumbnail(ColorScheme scheme, String? url) {
    final value = url?.trim();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 48,
        height: 48,
        child: value == null || value.isEmpty
            ? _placeholder(scheme)
            : FutureBuilder<ImageProvider?>(
                future: _artworkFuture(value),
                builder: (context, snapshot) {
                  final provider = snapshot.data;
                  if (provider == null) return _placeholder(scheme);
                  return Image(
                    image: ResizeImage(
                      provider,
                      width: 96,
                      height: 96,
                      allowUpscaling: false,
                    ),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => _placeholder(scheme),
                  );
                },
              ),
      ),
    );
  }

  /// 同一 URL 复用同一个 Future，重建时不再重新发起图片加载。
  Future<ImageProvider?> _artworkFuture(String url) {
    final cached = _artworkFutures[url];
    if (cached != null) return cached;
    if (_artworkFutures.length >= _maxArtworkFutures) {
      _artworkFutures.remove(_artworkFutures.keys.first);
    }
    final future = _loadArtwork(url);
    _artworkFutures[url] = future;
    return future;
  }

  Future<ImageProvider?> _loadArtwork(String url) async {
    try {
      return await widget.artworkLoader(url);
    } catch (error) {
      log.library.warn(
        'online_candidate_artwork_failed',
        '在线候选缩略图加载失败',
        fields: {'error': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Widget _placeholder(ColorScheme scheme) {
    return ColoredBox(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Icon(
        Symbols.image,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}
