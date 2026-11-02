import 'package:pure_music/core/artist_alias_groups.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// 关联歌手对话框的返回值：编辑后的显示名。
class ArtistLinkResult {
  const ArtistLinkResult({required this.displayName});

  final String displayName;
}

Future<ArtistLinkResult?> showArtistLinkDialog(
  BuildContext context, {
  required String artistName,
}) {
  return showDialog<ArtistLinkResult>(
    context: context,
    builder: (context) => _ArtistLinkDialog(artistName: artistName),
  );
}

class _ArtistLinkDialog extends StatefulWidget {
  const _ArtistLinkDialog({required this.artistName});

  final String artistName;

  @override
  State<_ArtistLinkDialog> createState() => _ArtistLinkDialogState();
}

class _ArtistLinkDialogState extends State<_ArtistLinkDialog> {
  late final Map<String, String> _aliases = Map<String, String>.from(
    AppSettings.instance.artistAliases,
  );
  late final Set<String> _selected = <String>{
    ...artistGroupMembers(widget.artistName, _aliases),
  };
  late final List<String> _pool = _buildPool();
  late final TextEditingController _displayController = TextEditingController(
    text: widget.artistName,
  );
  final TextEditingController _searchController = TextEditingController();
  bool _saving = false;

  List<String> _buildPool() {
    final names = <String>{
      ...AudioLibrary.instance.artistCollection.keys,
      ...artistGroupMembers(widget.artistName, _aliases),
    };
    names.remove(widget.artistName);
    return names.toList()..sort();
  }

  @override
  void initState() {
    super.initState();
    _displayController.addListener(_onTextChanged);
    _searchController.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _displayController.removeListener(_onTextChanged);
    _searchController.removeListener(_onTextChanged);
    _displayController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  List<String> get _visibleNames {
    final query = normalizedSearchQuery(_searchController.text).toLowerCase();
    if (query.isEmpty) return _pool;
    return _pool.where((name) {
      final normalized = normalizedSearchQuery(name).toLowerCase();
      return normalized.contains(query) ||
          name.getPinyinInitials().toLowerCase().contains(query) ||
          name.getPinyin().toLowerCase().contains(query);
    }).toList();
  }

  bool get _hasGroup => artistGroupMembers(widget.artistName, _aliases).isNotEmpty;

  bool get _canSave =>
      !_saving && _displayController.text.trim().isNotEmpty;

  Future<void> _save() async {
    if (!_canSave) return;
    final displayName = _displayController.text.trim();
    final next = applyArtistGroupLink(
      currentName: widget.artistName,
      displayName: displayName,
      selectedNames: _selected,
      aliases: _aliases,
    );
    if (mapEquals(next, AppSettings.instance.artistAliases)) {
      Navigator.pop(context);
      return;
    }

    setState(() => _saving = true);
    final previous = Map<String, String>.from(AppSettings.instance.artistAliases);
    AppSettings.instance.artistAliases = next;
    final saved = await AppSettings.instance.saveSettings();
    if (!saved) {
      AppSettings.instance.artistAliases = previous;
      if (!mounted) return;
      setState(() => _saving = false);
      showTextOnSnackBar('保存关联歌手失败');
      return;
    }

    try {
      await AudioLibrary.initFromIndex();
    } catch (error, stackTrace) {
      log.library.error(
        'artist_link_rebuild_failed',
        '关联歌手后重建曲库失败',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        showTextOnSnackBar('关联已保存，曲库刷新失败，重启后生效');
        Navigator.pop(context);
      }
      return;
    }

    if (!mounted) return;
    Navigator.pop(context, ArtistLinkResult(displayName: displayName));
  }

  Future<void> _dissolve() async {
    if (!_hasGroup || _saving) return;
    setState(() {
      _selected.clear();
      _displayController.text = widget.artistName;
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48.0).clamp(320.0, 520.0).toDouble();
    final height = (size.height - 96.0).clamp(360.0, 620.0).toDouble();
    final names = _visibleNames;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 24.0,
        vertical: 24.0,
      ),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '关联歌手',
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: AppType.sectionTitle,
                  fontWeight: AppType.weightBold,
                ),
              ),
              Text(
                '把不同写法的名字归到同一个歌手，作品合并显示',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: AppType.caption,
                ),
              ),
              const SizedBox(height: 12.0),
              Focus(
                onFocusChange: HotkeysHelper.onFocusChanges,
                child: TextField(
                  controller: _displayController,
                  decoration: const InputDecoration(
                    labelText: '显示名称',
                    prefixIcon: Icon(Symbols.badge),
                  ),
                  onSubmitted: (_) => _save(),
                ),
              ),
              const SizedBox(height: 12.0),
              Focus(
                onFocusChange: HotkeysHelper.onFocusChanges,
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    labelText: '搜索歌手',
                    prefixIcon: const Icon(Symbols.search),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空',
                            onPressed: _searchController.clear,
                            icon: const Icon(Symbols.close),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 8.0),
              Text(
                '已关联 ${_selected.length} 个名字',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: AppType.caption,
                ),
              ),
              const SizedBox(height: 4.0),
              Expanded(
                child: names.isEmpty
                    ? Center(
                        child: Text(
                          '没有可关联的歌手',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                        itemCount: names.length,
                        itemBuilder: (context, index) {
                          final name = names[index];
                          final groupSize = artistGroupMembers(
                            name,
                            _aliases,
                          ).length;
                          return CheckboxListTile(
                            value: _selected.contains(name),
                            onChanged: _saving
                                ? null
                                : (value) => setState(() {
                                    if (value == true) {
                                      _selected.add(name);
                                    } else {
                                      _selected.remove(name);
                                    }
                                  }),
                            controlAffinity: ListTileControlAffinity.leading,
                            dense: true,
                            title: Text(name),
                            subtitle: groupSize > 0
                                ? Text('本身已关联 $groupSize 个名字')
                                : null,
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12.0),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8.0,
                overflowSpacing: 8.0,
                children: [
                  TextButton.icon(
                    onPressed: _hasGroup && !_saving ? _dissolve : null,
                    icon: const Icon(Symbols.link_off),
                    label: const Text('解除关联'),
                  ),
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  FilledButton.icon(
                    onPressed: _canSave ? _save : null,
                    icon: const Icon(Symbols.check),
                    label: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
