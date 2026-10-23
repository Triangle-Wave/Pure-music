import 'dart:async';

import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/hidden_songs.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// 隐藏歌曲管理页：列出被隐藏的乐曲，支持单曲、批量与全部恢复。
class HiddenSongsPage extends StatefulWidget {
  const HiddenSongsPage({super.key});

  @override
  State<HiddenSongsPage> createState() => _HiddenSongsPageState();
}

class _HiddenSongsPageState extends State<HiddenSongsPage> {
  final MultiSelectController<Audio> _multiSelectController =
      MultiSelectController<Audio>();
  List<Audio>? _hiddenList;
  bool _restoringAll = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void dispose() {
    _multiSelectController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final items = await loadHiddenSongs();
    if (!mounted) return;
    setState(() {
      _hiddenList = items;
      _multiSelectController.selected.clear();
      _multiSelectController.enableMultiSelectView = false;
    });
  }

  Future<void> _restoreSelected() async {
    if (_restoringAll) return;
    final selected = _multiSelectController.selected.toList();
    if (selected.isEmpty) return;
    await _performRestore(selected);
  }

  Future<void> _restoreAll() async {
    final items = _hiddenList;
    if (items == null || items.isEmpty || _restoringAll) return;
    final confirmed = await showDangerConfirmDialog(
      context: context,
      title: '恢复全部隐藏乐曲？',
      message: '全部 ${items.length} 首乐曲将回到曲库列表、专辑和歌手页。',
      confirmLabel: '全部恢复',
    );
    if (!confirmed) return;
    await _performRestore(items);
  }

  Future<void> _performRestore(List<Audio> audios) async {
    setState(() => _restoringAll = true);
    try {
      await setSongsHidden(audios, hidden: false);
      await _reload();
      if (mounted) {
        showTextOnSnackBar(
          '已恢复 ${audios.length} 首',
          variant: ToastVariant.success,
        );
      }
    } catch (error, trace) {
      log.library.error('legacy', '恢复隐藏歌曲失败', error: error, stackTrace: trace);
      if (mounted) {
        showTextOnSnackBar('恢复失败，请查看日志', variant: ToastVariant.error);
      }
    } finally {
      if (mounted) setState(() => _restoringAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _hiddenList;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _multiSelectController,
      builder: (context, _) {
        final inMultiSelect = _multiSelectController.enableMultiSelectView;
        final selectedCount = _multiSelectController.selected.length;
        return PageScaffold(
          title: '隐藏歌曲',
          subtitle: items == null ? null : '${items.length} 首乐曲',
          actions: [
            if (inMultiSelect) ...[
              IconButton.filledTonal(
                tooltip: '恢复所选',
                onPressed: selectedCount == 0 || _restoringAll
                    ? null
                    : () => unawaited(_restoreSelected()),
                iconSize: 20,
                icon: const Icon(Symbols.visibility),
                style: AppButton.iconSquare,
              ),
              IconButton.filledTonal(
                tooltip: '退出多选视图',
                onPressed: () {
                  _multiSelectController
                    ..useMultiSelectView(false)
                    ..clear();
                },
                iconSize: 20,
                icon: const Icon(Symbols.cancel),
                style: AppButton.iconSquare,
              ),
            ] else ...[
              if (items != null && items.isNotEmpty) ...[
                IconButton.filledTonal(
                  tooltip: '多选',
                  onPressed: () =>
                      _multiSelectController.useMultiSelectView(true),
                  iconSize: 20,
                  icon: const Icon(Symbols.select),
                  style: AppButton.iconSquare,
                ),
                FilledButton.tonalIcon(
                  onPressed: _restoringAll
                      ? null
                      : () => unawaited(_restoreAll()),
                  icon: const Icon(Symbols.undo, size: 20),
                  label: const Text('全部恢复'),
                  style: AppButton.pageAction,
                ),
              ],
            ],
          ],
          body: _buildBody(items, scheme),
        );
      },
    );
  }

  Widget _buildBody(List<Audio>? items, ColorScheme scheme) {
    if (items == null) {
      return Center(child: CircularProgressIndicator(color: scheme.primary));
    }
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.visibility,
                color: scheme.onSurfaceVariant,
                size: 40.0,
              ),
              const SizedBox(height: 12.0),
              Text('没有隐藏的乐曲', style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) => AudioTile(
        audioIndex: i,
        playlist: items,
        multiSelectController: _multiSelectController,
        allowRestore: true,
        onRestore: (_) => _reload(),
      ),
    );
  }
}
