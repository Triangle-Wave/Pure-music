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
import 'package:pure_music/component/online_candidate_dialog.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/page/uni_detail_header_layout.dart';
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

  OnlineAlbumCandidateCache? _candidateCache;
  OnlineAlbumInfo? _onlineInfo;
  List<OnlineAlbumArtwork> _artworks = const [];
  int _selectedArtwork = -1;
  bool _onlineLoading = false;
  bool _onlineDone = false;
  bool _onlinePanelClosed = false;
  int _onlineRequestId = 0;
  late Future<ImageProvider?> _primaryPic;

  bool get _onlineDisabled => _candidateCache?.disabled ?? false;

  @override
  void initState() {
    super.initState();
    _primaryPic = _localCover();
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
      _candidateCache = null;
      _artworks = const [];
      _selectedArtwork = -1;
      _onlineDone = false;
      _onlinePanelClosed = false;
      _primaryPic = _localCover();
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
    if (force && previousUrl != null) {
      await _onlineAlbum.invalidateArtwork(previousUrl);
      if (!mounted || requestId != _onlineRequestId) return;
    }
    OnlineAlbumCandidateCache? cache;
    try {
      cache = await _onlineAlbum.loadCandidates(
        widget.album,
        force: force,
      );
    } catch (error) {
      cache = _candidateCache;
      log.library.warn(
        'online_album_ui_lookup_failed',
        '在线专辑信息加载失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
    if (!mounted || requestId != _onlineRequestId) return;
    await _applyCandidateCache(
      cache,
      previousUrl: previousUrl,
      requestId: requestId,
    );
  }

  Future<void> _applyCandidateCache(
    OnlineAlbumCandidateCache? cache, {
    String? previousUrl,
    int? requestId,
  }) async {
    final info = cache?.info;
    final artworks = info?.artworks ?? const <OnlineAlbumArtwork>[];
    // 显式选择候选时直接展示其封面；否则保持本地封面优先，本地没有
    // 封面时才使用在线图。
    final explicit = cache?.hasExplicitSelection ?? false;
    var selected = previousUrl != null
        ? artworks.indexWhere((artwork) => artwork.url == previousUrl)
        : -1;
    if (selected < 0 && explicit && artworks.isNotEmpty) {
      selected = 0;
    }
    if (selected < 0 && !explicit && artworks.isNotEmpty) {
      final localCover = await _localCover();
      if (!mounted || (requestId != null && requestId != _onlineRequestId)) {
        return;
      }
      if (localCover == null) selected = 0;
    }
    final cover = selected >= 0
        ? await _resolveArtwork(artworks[selected])
        : await _localCover();
    if (!mounted || (requestId != null && requestId != _onlineRequestId)) {
      return;
    }
    setState(() {
      _onlineLoading = false;
      _onlineDone = true;
      _candidateCache = cache;
      _onlineInfo = info;
      _artworks = artworks;
      _selectedArtwork = selected;
      _primaryPic = Future<ImageProvider?>.value(cover);
    });
  }

  Future<void> _chooseCandidate() async {
    if (!AppSettings.instance.onlineAlbumInfoEnabled) return;
    var cache = _candidateCache;
    if (cache == null) {
      try {
        cache = await _onlineAlbum.loadCandidates(widget.album);
      } catch (error) {
        log.library.warn(
          'online_album_candidates_ui_failed',
          '在线专辑候选读取失败',
          fields: {'error': error.runtimeType.toString()},
        );
      }
    }
    if (!mounted) return;
    final options = <OnlineCandidateOption>[
      for (final candidate
          in cache?.candidates ?? const <OnlineAlbumCandidate>[])
        OnlineCandidateOption(
          id: candidate.id,
          source: candidate.source,
          title: candidate.title,
          subtitle: [
            if (candidate.artist.trim().isNotEmpty) candidate.artist,
            if (candidate.year != null) '${candidate.year}',
            if (candidate.trackCount != null) '${candidate.trackCount} 首',
          ].join(' · '),
          imageUrl: candidate.imageUrl,
          score: candidate.score,
        ),
    ];
    final choice = await showOnlineCandidateDialog(
      context,
      title: '选择专辑来源',
      options: options,
      selectedId: cache?.selectedCandidateId ?? cache?.activeCandidate?.id,
      disabled: cache?.disabled ?? false,
      artworkLoader: _onlineAlbum.artwork,
    );
    if (choice == null || !mounted) return;
    await _applyCandidateChoice(choice);
  }

  Future<void> _applyCandidateChoice(OnlineCandidateChoice choice) async {
    final requestId = ++_onlineRequestId;
    setState(() => _onlineLoading = true);
    OnlineAlbumCandidateCache? cache;
    try {
      cache = switch (choice.action) {
        OnlineCandidateAction.auto => await _onlineAlbum.updateSelection(
          widget.album,
        ),
        OnlineCandidateAction.disable => await _onlineAlbum.updateSelection(
          widget.album,
          disabled: true,
        ),
        OnlineCandidateAction.select => await _onlineAlbum.updateSelection(
          widget.album,
          candidateId: choice.candidateId,
        ),
      };
    } catch (error) {
      cache = _candidateCache;
      log.library.warn(
        'online_album_selection_failed',
        '在线专辑候选选择失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
    cache ??= _candidateCache;
    if (!mounted || requestId != _onlineRequestId) return;
    await _applyCandidateCache(cache, requestId: requestId);
  }

  Future<ImageProvider?> _resolveArtwork(OnlineAlbumArtwork artwork) async {
    try {
      final provider = await _onlineAlbum.artwork(artwork.url);
      if (provider != null) return provider;
      return _localCover();
    } catch (error) {
      log.library.warn(
        'online_album_artwork_ui_failed',
        '在线封面显示失败',
        fields: {'error': error.runtimeType.toString()},
      );
      return _localCover();
    }
  }

  /// 本地专辑封面读取失败时降级为空，避免 Future 错误进入界面。
  Future<ImageProvider?> _localCover() async {
    try {
      final cover = await widget.album.cover;
      return cover;
    } catch (error) {
      log.library.warn(
        'album_local_cover_failed',
        '本地专辑封面读取失败',
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
        disabled: _onlineDisabled,
        onChoose: _chooseCandidate,
        onClose: _closeOnlinePanel,
      );
    }
    if (!_onlineDone) return null;
    return OnlineAlbumPanel(
      info: _onlineInfo,
      loading: _onlineLoading,
      disabled: _onlineDisabled,
      onChoose: _chooseCandidate,
      onRefresh: _onlineLoading ? null : _refreshOnlineInfo,
      onClose: _closeOnlinePanel,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _AlbumDetailScaffold(
      album: widget.album,
      primaryPic: _primaryPic,
      primaryPicFallback: widget.album.cachedDetailCover,
      headerTrailing: _headerTrailing,
      headerCoverOverlay: _artworks.isNotEmpty
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
    this.primaryPicFallback,
    this.headerTrailing,
    this.headerCoverOverlay,
  });

  final Album album;
  final Future<ImageProvider?> primaryPic;
  final ImageProvider? primaryPicFallback;
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
      primaryPicFallback: primaryPicFallback,
      picShape: PicShape.rrect,
      title: album.name,
      subtitle: '${album.works.length} 首作品',
      heroTag: 'album:${album.primaryPath}',
      primaryPicSeed: album.cachedDetailCover,
      headerTrailing: headerTrailing,
      // 在线专辑面板比在线头像面板内容多，右侧摆放需要更宽的空间；977 宽
      // 内容区下改放到标题下方，避免挤压标题、操作区与正文高度。
      headerTrailingSideMinWidth: 1100,
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
    this.disabled = false,
    this.onRefresh,
    this.onChoose,
    this.onClose,
  });

  final OnlineAlbumInfo? info;
  final bool loading;
  final bool disabled;
  final VoidCallback? onRefresh;
  final VoidCallback? onChoose;
  final VoidCallback? onClose;

  /// 面板最大宽度，与头部 stacked 摆放的可用宽度一致。
  static const double _maxWidth = 460.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = info;
    final summary = current?.summary;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: _maxWidth,
        maxHeight: UniDetailHeaderLayout.stackedMaxTrailingHeight,
      ),
      child: DecoratedBox(
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
                  Expanded(
                    child: Text(
                      current?.sourceLabel ??
                          (disabled ? '在线专辑（已隐藏）' : '在线专辑'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        fontWeight: AppType.weightSemibold,
                        color: scheme.onSurfaceVariant,
                      ),
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
                  _panelButton(
                    scheme,
                    Symbols.tune,
                    '选择来源',
                    loading ? null : onChoose,
                  ),
                  _panelButton(
                    scheme,
                    Symbols.refresh,
                    '刷新在线信息',
                    loading ? null : onRefresh,
                  ),
                  _panelButton(scheme, Symbols.close, '隐藏在线信息', onClose),
                ],
              ),
              const SizedBox(height: 4),
              _captionLine(scheme, _statusText(current)),
              if (summary != null && !disabled) ...[
                const SizedBox(height: 2),
                Tooltip(
                  message: summary,
                  child: _captionLine(scheme, summary),
                ),
              ],
              if (current != null && !disabled) ...[
                const SizedBox(height: 2),
                _captionLine(scheme, '来源 ${current.sourceLabel}'),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 面板正文固定为单行，避免长文案把头部高度撑开。
  String _statusText(OnlineAlbumInfo? current) {
    if (disabled) return '在线信息已隐藏，封面使用本地图片；可通过“选择来源”恢复。';
    if (current == null) {
      return loading ? '正在读取专辑信息…' : '暂无在线信息';
    }
    final parts = <String>[
      if (current.year != null) '${current.year}',
      if (current.label != null) current.label!,
      if (current.genre != null) current.genre!,
      if (current.trackCount != null) '${current.trackCount} 首',
    ];
    return parts.isEmpty ? '来源 ${current.sourceLabel}' : parts.join(' · ');
  }

  Widget _captionLine(ColorScheme scheme, String text) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: AppType.caption,
        color: scheme.onSurfaceVariant,
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
    // 未选中在线封面时，右箭头从第一张开始，左箭头从最后一张开始。
    final current = widget.selectedIndex;
    final start = current < 0 ? (delta > 0 ? -1 : 0) : current;
    widget.onSelect((start + delta + total) % total);
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
                  final target = (22 * MediaQuery.devicePixelRatioOf(context))
                      .round();
                  return Image(
                    image: ResizeImage(
                      provider,
                      width: target,
                      height: target,
                      allowUpscaling: false,
                    ),
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
