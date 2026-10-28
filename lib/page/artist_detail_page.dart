import 'dart:async';

import 'package:pure_music/component/online_candidate_dialog.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/audio_sort.dart';
import 'package:pure_music/component/album_tile.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/page/uni_detail_page.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:pure_music/services/online_album/online_album_models.dart';
import 'package:pure_music/services/online_album/online_artist_image_service.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// 用户显式选择的在线头像优先；否则本地封面优先，本地没有图时使用在线
/// 头像，失败返回 null 走占位图。
Future<ImageProvider?> _artistPicture(Artist artist) async {
  try {
    final preferred = await OnlineArtistImageService.instance
        .preferredImageFor(artist.name);
    if (preferred != null) return preferred;
  } catch (error) {
    log.library.warn(
      'artist_detail_preferred_picture_failed',
      '艺术家在线头像选择读取失败',
      fields: {'error': error.runtimeType.toString()},
    );
  }
  try {
    final local = await artist.picture;
    if (local != null) return local;
  } catch (error) {
    log.library.warn(
      'artist_detail_local_picture_failed',
      '艺术家本地封面读取失败',
      fields: {'error': error.runtimeType.toString()},
    );
  }
  try {
    final online = await OnlineArtistImageService.instance.imageFor(
      artist.name,
    );
    return online;
  } catch (error) {
    log.library.warn(
      'artist_detail_online_picture_failed',
      '艺术家在线头像读取失败',
      fields: {'error': error.runtimeType.toString()},
    );
    return null;
  }
}

class ArtistDetailPage extends StatefulWidget {
  const ArtistDetailPage({super.key, required this.artist});

  final Artist artist;

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<ArtistDetailPage> {
  final OnlineArtistImageService _online = OnlineArtistImageService.instance;

  OnlineArtistCandidateCache? _candidateCache;
  OnlineQueryStatus? _onlineStatus;
  bool _onlineLoading = false;
  int _onlineRequestId = 0;
  late Future<ImageProvider?> _primaryPic;

  @override
  void initState() {
    super.initState();
    _primaryPic = _artistPicture(widget.artist);
    if (AppSettings.instance.onlineArtistImageEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadOnlineCandidates());
      });
    }
  }

  @override
  void didUpdateWidget(covariant ArtistDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artist.identityPath != widget.artist.identityPath) {
      _onlineRequestId++;
      _onlineLoading = false;
      _candidateCache = null;
      _onlineStatus = null;
      _primaryPic = _artistPicture(widget.artist);
      if (AppSettings.instance.onlineArtistImageEnabled) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_loadOnlineCandidates());
        });
      }
    }
  }

  Future<void> _loadOnlineCandidates({bool force = false}) async {
    if (!AppSettings.instance.onlineArtistImageEnabled || _onlineLoading) {
      return;
    }
    final requestId = ++_onlineRequestId;
    setState(() => _onlineLoading = true);
    if (force) {
      await _online.invalidateImage(widget.artist.name);
      if (!mounted || requestId != _onlineRequestId) return;
    }
    OnlineArtistCandidateCache? cache;
    try {
      cache = await _online.loadCandidates(widget.artist.name, force: force);
    } catch (error) {
      cache = _candidateCache;
      log.library.warn(
        'artist_detail_online_candidates_failed',
        '艺术家在线候选加载失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
    if (!mounted || requestId != _onlineRequestId) return;
    setState(() {
      _onlineLoading = false;
      _candidateCache = cache;
      _onlineStatus = _online.queryStatusFor(widget.artist.name);
      if (force) _primaryPic = _artistPicture(widget.artist);
    });
  }

  Future<void> _chooseCandidate() async {
    if (!AppSettings.instance.onlineArtistImageEnabled) return;
    var cache = _candidateCache;
    if (cache == null) {
      try {
        cache = await _online.loadCandidates(widget.artist.name);
      } catch (error) {
        log.library.warn(
          'artist_detail_candidates_read_failed',
          '艺术家在线候选读取失败',
          fields: {'error': error.runtimeType.toString()},
        );
      }
    }
    if (!mounted) return;
    final options = <OnlineCandidateOption>[
      for (final candidate
          in cache?.candidates ?? const <OnlineArtistCandidate>[])
        OnlineCandidateOption(
          id: candidate.id,
          source: candidate.source,
          title: candidate.name,
          subtitle: candidate.albumCount == null
              ? null
              : '${candidate.albumCount} 张专辑',
          imageUrl: candidate.imageUrl,
          score: candidate.score * 100,
        ),
    ];
    final choice = await showOnlineCandidateDialog(
      context,
      title: '选择艺术家头像',
      options: options,
      selectedId: cache?.selectedCandidateId ?? cache?.activeCandidate?.id,
      disabled: cache?.disabled ?? false,
      artworkLoader: _online.artwork,
    );
    if (choice == null || !mounted) return;
    await _applyChoice(choice);
  }

  Future<void> _applyChoice(OnlineCandidateChoice choice) async {
    final requestId = ++_onlineRequestId;
    setState(() => _onlineLoading = true);
    OnlineArtistCandidateCache? cache;
    try {
      cache = switch (choice.action) {
        OnlineCandidateAction.auto => await _online.updateSelection(
          widget.artist.name,
        ),
        OnlineCandidateAction.disable => await _online.updateSelection(
          widget.artist.name,
          disabled: true,
        ),
        OnlineCandidateAction.select => await _online.updateSelection(
          widget.artist.name,
          candidateId: choice.candidateId,
        ),
      };
    } catch (error) {
      cache = _candidateCache;
      log.library.warn(
        'artist_detail_selection_failed',
        '艺术家在线头像选择失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
    cache ??= _candidateCache;
    if (!mounted || requestId != _onlineRequestId) return;
    setState(() {
      _onlineLoading = false;
      _candidateCache = cache;
      _primaryPic = _artistPicture(widget.artist);
    });
  }

  Widget? get _headerTrailing {
    if (!AppSettings.instance.onlineArtistImageEnabled) return null;
    final cache = _candidateCache;
    return _ArtistOnlinePanel(
      source: cache?.activeCandidate?.source,
      candidateCount: cache?.candidates.length ?? 0,
      disabled: cache?.disabled ?? false,
      status: _onlineStatus,
      loading: _onlineLoading,
      onChoose: _chooseCandidate,
      onRefresh: _onlineLoading
          ? null
          : () => unawaited(_loadOnlineCandidates(force: true)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final artist = widget.artist;
    final secondaryContent = List<Audio>.from(artist.works);
    final multiSelectController = MultiSelectController<Audio>();

    final canSortSongs = hasEnoughItemsToSort(secondaryContent.length);

    return UniDetailPage<Artist, Audio, Album>(
      pref: AppPreference.instance.artistDetailPagePref,
      primaryContent: artist,
      primaryPic: _primaryPic,
      picShape: PicShape.oval,
      title: artist.name,
      subtitle: '${artist.works.length} 首作品',
      heroTag: 'artist:${artist.identityPath}',
      primaryPicSeed: artist.cachedDetailPicture,
      headerTrailing: _headerTrailing,
      // 正文宽度不足时把在线头像面板移到标题下方，优先保证标题与操作区。
      headerTrailingSideMinWidth: 1100,
      secondaryContent: secondaryContent,
      secondaryContentBuilder: (context, audio, i, multiSelectController, _) =>
          AudioTile(
            audioIndex: i,
            playlist: secondaryContent,
            multiSelectController: multiSelectController,
          ),
      tertiaryContentTitle: '专辑',
      tertiaryContent: artist.albumsMap.values.toList(),
      tertiaryContentBuilder:
          (context, album, i, multiSelectController, view) => AlbumTile(
            album: album,
            view: view,
            enableHero: false,
          ),
      enablePlayAll: secondaryContent.isNotEmpty,
      enableShufflePlay: secondaryContent.isNotEmpty,
      enableSortMethod: canSortSongs,
      enableSortOrder: canSortSongs,
      enableSecondaryContentViewSwitch: secondaryContent.isNotEmpty,
      enableTabs: true,
      secondaryContentTitle: '歌曲',
      tertiaryTabIcon: Symbols.album,
      bodyOverride: secondaryContent.isEmpty ? const _EmptyArtistBody() : null,
      multiSelectController: multiSelectController,
      multiSelectViewActions: [
        AddAllToPlaylist(multiSelectController: multiSelectController),
        MultiSelectSelectOrClearAll(
          multiSelectController: multiSelectController,
          contentList: secondaryContent,
        ),
        MultiSelectExit(multiSelectController: multiSelectController),
      ],
      sortMethods: _artistSortMethods(),
    );
  }
}

/// 艺术家详情页头部右侧的在线头像面板。
class _ArtistOnlinePanel extends StatelessWidget {
  const _ArtistOnlinePanel({
    required this.source,
    required this.candidateCount,
    required this.disabled,
    required this.loading,
    required this.onChoose,
    required this.onRefresh,
    this.status,
  });

  final String? source;
  final int candidateCount;
  final bool disabled;
  final bool loading;
  final OnlineQueryStatus? status;
  final VoidCallback? onChoose;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460, maxHeight: 112),
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
                    Symbols.account_box,
                    size: 15,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      disabled
                          ? '在线头像（已隐藏）'
                          : (source ?? '在线艺术家头像'),
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
                    '选择头像来源',
                    loading ? null : onChoose,
                  ),
                  _panelButton(
                    scheme,
                    Symbols.refresh,
                    '刷新在线头像',
                    loading ? null : onRefresh,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _statusText(),
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
      ),
    );
  }

  String _statusText() {
    if (disabled) return '在线头像已隐藏，使用本地图片或占位图。';
    if (loading) return '正在读取在线艺术家头像…';
    return switch (status) {
      OnlineQueryStatus.failed => '在线源请求失败，可点刷新重试',
      OnlineQueryStatus.noMatch => '没有匹配的艺术家头像，可点刷新重试',
      _ => candidateCount > 1
          ? '$candidateCount 个候选，可手动切换来源。'
          : '仅使用最佳匹配的头像来源。',
    };
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

SortMethodDesc<Audio> _artistStringSort({
  required IconData icon,
  required String name,
  required String Function(Audio) keyOf,
  required String Function(Audio) sortValueOf,
}) {
  return SortMethodDesc(
    icon: icon,
    name: name,
    alphabetValueOf: keyOf,
    method: (list, order) {
      sortNaturallyBy(
        list,
        sortValueOf,
        descending: order == SortOrder.decending,
      );
    },
  );
}

SortMethodDesc<Audio> _artistIntSort({
  required IconData icon,
  required String name,
  required int Function(Audio) valueOf,
}) {
  return SortMethodDesc(
    icon: icon,
    name: name,
    method: (list, order) {
      sortByIntegerThenNatural(
        list,
        valueOf: valueOf,
        tieBreakOf: audioTitleSortValue,
        descending: order == SortOrder.decending,
      );
    },
  );
}

List<SortMethodDesc<Audio>> _artistSortMethods() {
  return [
    _artistStringSort(
      icon: Symbols.title,
      name: '标题',
      keyOf: (audio) => audio.title,
      sortValueOf: audioTitleSortValue,
    ),
    _artistStringSort(
      icon: Symbols.album,
      name: '专辑',
      keyOf: (audio) => audio.album,
      sortValueOf: audioAlbumSortValue,
    ),
    _artistIntSort(
      icon: Symbols.add,
      name: '创建时间',
      valueOf: (audio) => audio.created,
    ),
    _artistIntSort(
      icon: Symbols.edit,
      name: '修改时间',
      valueOf: (audio) => audio.modified,
    ),
    _artistIntSort(
      icon: Symbols.timer,
      name: '时长',
      valueOf: (audio) => audio.duration,
    ),
    _artistIntSort(
      icon: Symbols.bar_chart,
      name: '播放次数',
      valueOf: (audio) => audio.playCount,
    ),
  ];
}

class _EmptyArtistBody extends StatelessWidget {
  const _EmptyArtistBody();

  @override
  Widget build(BuildContext context) {
    return const QuietEmptyState(
      icon: Symbols.artist,
      title: '这个艺术家还没有歌曲',
      message: '等扫描或索引更新后，这里会显示可播放内容。',
    );
  }
}
