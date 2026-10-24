import 'dart:async';

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/audio_sort.dart';
import 'package:pure_music/component/artist_tile.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/page/uni_detail_page.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:pure_music/services/online_album/online_album_service.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

int _discNumber(Audio audio) {
  final disc = audio.disc;
  return disc != null && disc > 0 ? disc : 1;
}

String _trackNumber(Audio audio, {bool includeDisc = false}) {
  final track = audio.track < 10 ? '0${audio.track}' : '${audio.track}';
  return includeDisc ? '${_discNumber(audio)}-$track' : track;
}

int _compareWithinDisc(
  Audio first,
  Audio second,
  int Function(Audio first, Audio second) compare,
) {
  final disc = _discNumber(first).compareTo(_discNumber(second));
  return disc != 0 ? disc : compare(first, second);
}

void _sortWithinDisc(
  List<Audio> list,
  SortOrder order,
  int Function(Audio first, Audio second) compare,
) {
  list.sort((a, b) {
    final left = order == SortOrder.ascending ? a : b;
    final right = order == SortOrder.ascending ? b : a;
    final cmp = _compareWithinDisc(left, right, compare);
    if (cmp != 0) return cmp;
    return a.title.naturalCompareTo(b.title);
  });
}

List<SortMethodDesc<Audio>> _albumSortMethods() {
  return [
    _albumTextSort(
      Symbols.title,
      '标题',
      (audio) => audio.title,
      audioTitleSortValue,
    ),
    _albumTextSort(
      Symbols.artist,
      '艺术家',
      (audio) => audio.artist,
      audioArtistSortValue,
    ),
    SortMethodDesc(
      icon: Symbols.art_track,
      name: '音轨',
      method: (list, order) => _sortWithinDisc(
        list,
        order,
        (first, second) => first.track.compareTo(second.track),
      ),
    ),
    SortMethodDesc(
      icon: Symbols.add,
      name: '创建时间',
      method: (list, order) => _sortWithinDisc(
        list,
        order,
        (first, second) => first.created.compareTo(second.created),
      ),
    ),
    SortMethodDesc(
      icon: Symbols.edit,
      name: '修改时间',
      method: (list, order) => _sortWithinDisc(
        list,
        order,
        (first, second) => first.modified.compareTo(second.modified),
      ),
    ),
    SortMethodDesc(
      icon: Symbols.timer,
      name: '时长',
      method: (list, order) {
        sortByIntegerThenNatural(
          list,
          valueOf: (audio) => audio.duration,
          tieBreakOf: audioTitleSortValue,
          descending: order == SortOrder.decending,
        );
      },
    ),
    SortMethodDesc(
      icon: Symbols.bar_chart,
      name: '播放次数',
      method: (list, order) {
        sortByIntegerThenNatural(
          list,
          valueOf: (audio) => audio.playCount,
          tieBreakOf: audioTitleSortValue,
          descending: order == SortOrder.decending,
        );
      },
    ),
  ];
}

SortMethodDesc<Audio> _albumTextSort(
  IconData icon,
  String name,
  String Function(Audio audio) valueOf,
  String Function(Audio audio) sortValueOf,
) {
  return SortMethodDesc(
    icon: icon,
    name: name,
    alphabetValueOf: valueOf,
    method: (list, order) {
      sortNaturallyBy(
        list,
        sortValueOf,
        descending: order == SortOrder.decending,
      );
    },
  );
}

class AlbumDetailPage extends StatefulWidget {
  const AlbumDetailPage({super.key, required this.album});

  final Album album;

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  final OnlineAlbumService _onlineAlbum = OnlineAlbumService.instance;

  OnlineAlbumInfo? _onlineInfo;
  List<OnlineAlbumArtwork> _artworks = const [];
  int _selectedArtwork = -1;
  bool _onlineLoading = false;
  bool _onlineDone = false;
  bool _onlinePanelClosed = false;
  int _onlineRequestId = 0;
  late Future<ImageProvider?> _primaryPic = widget.album.cover;

  @override
  void initState() {
    super.initState();
    if (AppSettings.instance.onlineAlbumInfoEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadOnlineInfo());
      });
    }
  }

  @override
  void didUpdateWidget(covariant AlbumDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.album.primaryPath != widget.album.primaryPath) {
      _onlineRequestId++;
      _onlineLoading = false;
      _onlineInfo = null;
      _artworks = const [];
      _selectedArtwork = -1;
      _onlineDone = false;
      _onlinePanelClosed = false;
      _primaryPic = widget.album.cover;
      if (AppSettings.instance.onlineAlbumInfoEnabled) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_loadOnlineInfo());
        });
      }
    }
  }

  Future<void> _loadOnlineInfo({bool force = false}) async {
    if (!AppSettings.instance.onlineAlbumInfoEnabled || _onlineLoading) return;
    final previousUrl =
        _selectedArtwork >= 0 && _selectedArtwork < _artworks.length
        ? _artworks[_selectedArtwork].url
        : null;
    final requestId = ++_onlineRequestId;
    setState(() => _onlineLoading = true);
    OnlineAlbumInfo? info;
    try {
      info = await _onlineAlbum.lookup(widget.album, force: force);
    } catch (error) {
      info = null;
      log.library.warn(
        'online_album_ui_lookup_failed',
        '在线专辑信息加载失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
    if (!mounted) return;
    if (requestId != _onlineRequestId) return;
    final artworks = info?.artworks ?? const <OnlineAlbumArtwork>[];
    var selected = -1;
    if (artworks.isNotEmpty) {
      final previousIndex = previousUrl == null
          ? -1
          : artworks.indexWhere((artwork) => artwork.url == previousUrl);
      selected = previousIndex >= 0 ? previousIndex : 0;
    }
    setState(() {
      _onlineLoading = false;
      _onlineDone = true;
      _onlineInfo = info;
      _artworks = artworks;
      _selectedArtwork = selected;
      _onlinePanelClosed = force ? false : _onlinePanelClosed;
      _primaryPic = selected >= 0
          ? _resolveArtwork(artworks[selected])
          : widget.album.cover;
    });
  }

  Future<ImageProvider?> _resolveArtwork(OnlineAlbumArtwork artwork) async {
    try {
      final provider = await _onlineAlbum.artwork(artwork.url);
      if (provider != null) return provider;
      final localCover = await widget.album.cover;
      return localCover;
    } catch (error) {
      log.library.warn(
        'online_album_artwork_ui_failed',
        '在线封面显示失败',
        fields: {'error': error.runtimeType.toString()},
      );
      return null;
    }
  }

  void _selectArtwork(int index) {
    if (index < 0 || index >= _artworks.length || index == _selectedArtwork) {
      return;
    }
    setState(() {
      _selectedArtwork = index;
      _primaryPic = _resolveArtwork(_artworks[index]);
    });
  }

  void _closeOnlinePanel() {
    setState(() => _onlinePanelClosed = true);
  }

  void _refreshOnlineInfo() {
    unawaited(_loadOnlineInfo(force: true));
  }

  Widget? get _headerTrailing {
    if (!AppSettings.instance.onlineAlbumInfoEnabled || _onlinePanelClosed) {
      return null;
    }
    if (_onlineLoading && !_onlineDone) {
      return OnlineAlbumPanel(
        info: null,
        loading: true,
        onClose: _closeOnlinePanel,
      );
    }
    if (!_onlineDone) return null;
    return OnlineAlbumPanel(
      info: _onlineInfo,
      loading: _onlineLoading,
      onRefresh: _onlineLoading ? null : _refreshOnlineInfo,
      onClose: _closeOnlinePanel,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _AlbumDetailScaffold(
      album: widget.album,
      primaryPic: _primaryPic,
      headerTrailing: _headerTrailing,
      headerCoverOverlay: _artworks.length > 1
          ? _ArtworkSwitcher(
              artworks: _artworks,
              selectedIndex: _selectedArtwork,
              onSelect: _selectArtwork,
            )
          : null,
    );
  }
}

class _AlbumDetailScaffold extends StatelessWidget {
  const _AlbumDetailScaffold({
    required this.album,
    required this.primaryPic,
    this.headerTrailing,
    this.headerCoverOverlay,
  });

  final Album album;
  final Future<ImageProvider?> primaryPic;
  final Widget? headerTrailing;
  final Widget? headerCoverOverlay;

  @override
  Widget build(BuildContext context) {
    final secondaryContent = List<Audio>.from(album.works);
    final multiSelectController = MultiSelectController<Audio>();
    final discNumbers = secondaryContent
        .map(_discNumber)
        .where((disc) => disc > 0)
        .toSet();
    final showDiscSections =
        discNumbers.length > 1 || discNumbers.any((disc) => disc > 1);
    final canSortSongs = hasEnoughItemsToSort(secondaryContent.length);
    return UniDetailPage<Album, Audio, Artist>(
      pref: AppPreference.instance.albumDetailPagePref,
      primaryContent: album,
      primaryPic: primaryPic,
      picShape: PicShape.rrect,
      title: album.name,
      subtitle: '${album.works.length} 首作品',
      heroTag: 'album:${album.primaryPath}',
      primaryPicSeed: album.cachedDetailCover,
      headerTrailing: headerTrailing,
      headerCoverOverlay: headerCoverOverlay,
      secondaryContent: secondaryContent,
      secondaryContentBuilder: (context, audio, i, ctl, view) =>
          _songTile(audio, i, secondaryContent, ctl, view, showDiscSections),
      secondaryContentSectionBuilder: showDiscSections
          ? (context, audio, i) => _discSection(audio, i, secondaryContent)
          : null,
      tertiaryContentTitle: '艺术家',
      tertiaryContent: album.artistsMap.values.toList(),
      tertiaryContentBuilder:
          (context, artist, i, multiSelectController, view) => ArtistTile(
            artist: artist,
            view: view,
            enableHero: false,
          ),
      enableShufflePlay: secondaryContent.isNotEmpty,
      enablePlayAll: secondaryContent.isNotEmpty,
      enableSortMethod: canSortSongs,
      enableSortOrder: canSortSongs,
      enableSecondaryContentViewSwitch: secondaryContent.isNotEmpty,
      enableTabs: true,
      secondaryContentTitle: '歌曲',
      tertiaryTabIcon: Symbols.artist,
      bodyOverride: secondaryContent.isEmpty ? const _EmptyAlbumBody() : null,
      multiSelectController: multiSelectController,
      multiSelectViewActions: _multiSelectActions(
        multiSelectController,
        secondaryContent,
      ),
      sortMethods: _albumSortMethods(),
    );
  }

  List<Widget> _multiSelectActions(
    MultiSelectController<Audio> multiSelectController,
    List<Audio> secondaryContent,
  ) {
    return [
      AddAllToPlaylist(multiSelectController: multiSelectController),
      MultiSelectSelectOrClearAll(
        multiSelectController: multiSelectController,
        contentList: secondaryContent,
      ),
      MultiSelectExit(multiSelectController: multiSelectController),
    ];
  }

  Widget _songTile(
    Audio audio,
    int i,
    List<Audio> playlist,
    MultiSelectController<Audio>? multiSelectController,
    ContentView view,
    bool showDiscSections,
  ) {
    final includeDisc = showDiscSections && view == ContentView.table;
    return AudioTile(
      leading: Text(_trackNumber(audio, includeDisc: includeDisc)),
      leadingWidth: includeDisc
          ? AudioTile.discLeadingWidth
          : AudioTile.defaultLeadingWidth,
      audioIndex: i,
      playlist: playlist,
      multiSelectController: multiSelectController,
    );
  }

  Widget? _discSection(Audio audio, int i, List<Audio> playlist) {
    final disc = _discNumber(audio);
    if (i > 0 && _discNumber(playlist[i - 1]) == disc) return null;
    return _DiscSectionHeader(disc: disc);
  }
}

/// 头部右侧的在线专辑信息。没有结果时保持紧凑，只显示“暂无在线信息”。
class OnlineAlbumPanel extends StatelessWidget {
  const OnlineAlbumPanel({
    super.key,
    required this.info,
    required this.loading,
    this.onRefresh,
    this.onClose,
  });

  final OnlineAlbumInfo? info;
  final bool loading;
  final VoidCallback? onRefresh;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = info;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: AppRadius.mdCircular,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Symbols.language,
                  size: 15,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                Text(
                  'MusicBrainz',
                  style: TextStyle(
                    fontSize: AppType.caption,
                    fontWeight: AppType.weightSemibold,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (loading) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: scheme.primary,
                    ),
                  ),
                ],
                const Spacer(),
                _panelButton(
                  scheme,
                  Symbols.refresh,
                  '刷新在线信息',
                  loading ? null : onRefresh,
                ),
                _panelButton(scheme, Symbols.close, '隐藏在线信息', onClose),
              ],
            ),
            const SizedBox(height: 6),
            if (loading && current == null)
              Text(
                '正在读取专辑信息…',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              )
            else if (current == null)
              Text(
                '暂无在线信息',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              )
            else ...[
              if (current.year != null ||
                  current.label != null ||
                  current.genre != null)
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (current.year != null)
                      _metaChip(scheme, '${current.year}'),
                    if (current.label != null)
                      _metaChip(scheme, current.label!),
                    if (current.genre != null)
                      _metaChip(scheme, current.genre!),
                  ],
                ),
              if (current.summary != null) ...[
                const SizedBox(height: 6),
                _ExpandableSummary(text: current.summary!),
              ],
              const SizedBox(height: 6),
              Text(
                '来源 MusicBrainz · Cover Art Archive',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.78),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _panelButton(
    ColorScheme scheme,
    IconData icon,
    String tooltip,
    VoidCallback? onPressed,
  ) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: 15),
      color: scheme.onSurfaceVariant,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 26, height: 26),
    );
  }

  Widget _metaChip(ColorScheme scheme, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppType.caption,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ExpandableSummary extends StatefulWidget {
  const _ExpandableSummary({required this.text});

  final String text;

  @override
  State<_ExpandableSummary> createState() => _ExpandableSummaryState();
}

class _ExpandableSummaryState extends State<_ExpandableSummary> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: AppType.caption,
      height: 1.35,
      color: scheme.onSurfaceVariant,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 2,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: style,
              maxLines: _expanded ? null : 2,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
            if (overflows || _expanded)
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _expanded ? '收起' : '展开',
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: scheme.primary,
                        ),
                      ),
                      Icon(
                        _expanded
                            ? Symbols.expand_less
                            : Symbols.expand_more,
                        size: 14,
                        color: scheme.primary,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 封面切换器：左右按钮循环切换全部图片，缩略图直接选中。
class _ArtworkSwitcher extends StatefulWidget {
  const _ArtworkSwitcher({
    required this.artworks,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<OnlineAlbumArtwork> artworks;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  State<_ArtworkSwitcher> createState() => _ArtworkSwitcherState();
}

class _ArtworkSwitcherState extends State<_ArtworkSwitcher> {
  final Map<String, Future<ImageProvider?>> _thumbnails = {};

  @override
  void initState() {
    super.initState();
    _primeThumbnails();
  }

  @override
  void didUpdateWidget(covariant _ArtworkSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    _primeThumbnails();
  }

  void _primeThumbnails() {
    for (final index in _visibleIndexes()) {
      final url = widget.artworks[index].url;
      if (_thumbnails.containsKey(url)) continue;
      final future = OnlineAlbumService.instance.artwork(url);
      _thumbnails[url] = future;
      unawaited(
        future.then<void>((provider) {
          if (provider == null && identical(_thumbnails[url], future)) {
            _thumbnails.remove(url);
          }
        }),
      );
    }
  }

  List<int> _visibleIndexes() {
    final total = widget.artworks.length;
    if (total <= 4) return List<int>.generate(total, (index) => index);
    final selected = widget.selectedIndex.clamp(0, total - 1).toInt();
    final start = (selected - 1).clamp(0, total - 4).toInt();
    return List<int>.generate(4, (index) => start + index);
  }

  void _move(int delta) {
    final total = widget.artworks.length;
    if (total == 0) return;
    final current = widget.selectedIndex < 0 ? 0 : widget.selectedIndex;
    widget.onSelect((current + delta + total) % total);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = widget.artworks.length;
    if (total == 0) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (total > 1)
                  _arrow(scheme, Symbols.chevron_left, () => _move(-1)),
                for (final index in _visibleIndexes())
                  _thumbnail(scheme, index),
                if (total > 1)
                  _arrow(scheme, Symbols.chevron_right, () => _move(1)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _arrow(ColorScheme scheme, IconData icon, VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 20,
          height: 22,
          child: Icon(icon, size: 15, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _thumbnail(ColorScheme scheme, int index) {
    final artwork = widget.artworks[index];
    final selected = index == widget.selectedIndex;
    return Tooltip(
      message: artwork.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => widget.onSelect(index),
          child: Container(
            width: 22,
            height: 22,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: selected ? scheme.primary : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: FutureBuilder<ImageProvider?>(
                future: _thumbnails[artwork.url],
                builder: (context, snapshot) {
                  final provider = snapshot.data;
                  if (provider == null) {
                    return Icon(
                      Symbols.album,
                      size: 13,
                      color: scheme.onSurfaceVariant,
                    );
                  }
                  return Image(
                    image: provider,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => Icon(
                      Symbols.album,
                      size: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DiscSectionHeader extends StatelessWidget {
  const _DiscSectionHeader({required this.disc});

  final int disc;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Row(
          children: [
            Icon(Symbols.album, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(
              '唱片 $disc',
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: AppType.body,
                fontWeight: AppType.weightSemibold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyAlbumBody extends StatelessWidget {
  const _EmptyAlbumBody();

  @override
  Widget build(BuildContext context) {
    return const QuietEmptyState(
      icon: Symbols.album,
      title: '这个专辑还没有歌曲',
      message: '等扫描或索引更新后，这里会显示可播放内容。',
    );
  }
}
