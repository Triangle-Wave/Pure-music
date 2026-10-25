import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';

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
Future<OnlineCandidateChoice?> showOnlineCandidateDialog(
  BuildContext context, {
  required String title,
  required List<OnlineCandidateOption> options,
  required String? selectedId,
  required bool disabled,
  required Future<ImageProvider?> Function(String url) artworkLoader,
}) {
  return showDialog<OnlineCandidateChoice>(
    context: context,
    builder: (context) => _OnlineCandidateDialog(
      title: title,
      options: options,
      selectedId: selectedId,
      disabled: disabled,
      artworkLoader: artworkLoader,
    ),
  );
}

class _OnlineCandidateDialog extends StatelessWidget {
  const _OnlineCandidateDialog({
    required this.title,
    required this.options,
    required this.selectedId,
    required this.disabled,
    required this.artworkLoader,
  });

  final String title;
  final List<OnlineCandidateOption> options;
  final String? selectedId;
  final bool disabled;
  final Future<ImageProvider?> Function(String url) artworkLoader;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: AppType.subtitle,
              fontWeight: AppType.weightSemibold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '选择结果长期保存在本地，只有点刷新才重新获取。',
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
          child: options.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 24,
                  ),
                  child: Text(
                    '没有可用的在线候选，可以保持“不使用”或稍后刷新。',
                    style: TextStyle(
                      fontSize: AppType.body,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (context, index) => _optionTile(
                    context,
                    scheme,
                    options[index],
                  ),
                ),
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
            foregroundColor: disabled ? scheme.primary : scheme.onSurface,
          ),
          icon: Icon(
            disabled ? Symbols.check_circle : Symbols.visibility_off,
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

  Widget _optionTile(
    BuildContext context,
    ColorScheme scheme,
    OnlineCandidateOption option,
  ) {
    final selected = !disabled && option.id == selectedId;
    final subtitle = option.subtitle?.trim();
    return InkWell(
      onTap: () => Navigator.of(
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
                future: artworkLoader(value),
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
