import 'dart:async';

import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/library/album_artwork.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/audio_sort.dart';
import 'package:pure_music/component/artist_tile.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/online_candidate_dialog.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/page/album_artwork_viewer.dart';
import 'package:pure_music/page/uni_detail_header_layout.dart';
import 'package:pure_music/page/uni_detail_page.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:pure_music/services/online_album/online_album_service.dart';
import 'package:pure_music/widget/album_artwork_switcher.dart';
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

  /// 对话框打开时展示的候选缓存，用于判断搜索是否返回了新结果。
  OnlineAlbumCandidateCache? _dialogCache;
  OnlineAlbumInfo? _onlineInfo;
  OnlineQueryStatus? _onlineStatus;
  List<AlbumArtwork> _localArtworks = const [];
  List<AlbumArtwork> _onlineMain = const [];
  List<AlbumArtwork> _artworks = const [];
  List<AlbumArtwork> _onlineSupplement = const [];
  String? _supplementKey;
  bool _explicitOnline = false;
  int _localRequestId = 0;
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
    unawaited(_loadLocalArtworks());
    if (AppSettings.instance.onlineAlbumInfoEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadOnlineInfo());
      });
    }
  }

  @override
  void didUpdateWidget(covariant AlbumDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.album.identityPath != widget.album.identityPath) {
      _onlineRequestId++;
      _onlineLoading = false;
      _onlineInfo = null;
      _onlineStatus = null;
      _candidateCache = null;
      _dialogCache = null;
      _localArtworks = const [];
      _onlineMain = const [];
      _artworks = const [];
      _onlineSupplement = const [];
      _supplementKey = null;
      _explicitOnline = false;
      _localRequestId++;
      _selectedArtwork = -1;
      _onlineDone = false;
      _onlinePanelClosed = false;
      _primaryPic = _localCover();
      unawaited(_loadLocalArtworks());
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
    if (force) _supplementKey = null;
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

  /// 读取本地图片并立即生效，不等待在线信息。
  Future<void> _loadLocalArtworks() async {
    final requestId = ++_localRequestId;
    try {
      final local = await widget.album.artworks;
      if (!mounted || requestId != _localRequestId) return;
      final previousKey = _selectedKey();
      final rebuilt = _composeArtworks(local);
      var selected = previousKey == null
          ? -1
          : rebuilt.indexWhere((artwork) => artwork.key == previousKey);
      if (selected < 0) selected = _preferredFrontIndex(rebuilt);
      final nextKey = selected >= 0 ? rebuilt[selected].key : null;
      ImageProvider? cover;
      if (nextKey != null && nextKey != previousKey) {
        cover = await _resolveArtwork(rebuilt[selected]);
        if (!mounted || requestId != _localRequestId) return;
      }
      setState(() {
        _localArtworks = List<AlbumArtwork>.unmodifiable(local);
        _rebuildArtworks();
        final index = nextKey == null
            ? _preferredFrontIndex(_artworks)
            : _artworks.indexWhere((artwork) => artwork.key == nextKey);
        final finalIndex = index >= 0
            ? index
            : _preferredFrontIndex(_artworks);
        _selectedArtwork = finalIndex;
        if (finalIndex < 0) return;
        final finalKey = _artworks[finalIndex].key;
        if (finalKey == previousKey) return;
        _primaryPic = finalKey == nextKey
            ? Future<ImageProvider?>.value(cover)
            : _resolveArtwork(_artworks[finalIndex]);
      });
    } catch (error) {
      log.library.warn(
        'album_local_artworks_failed',
        '本地专辑图片加载失败',
        fields: {
          'album': widget.album.identityPath,
          'error': error.runtimeType.toString(),
        },
      );
      if (!mounted || requestId != _localRequestId) return;
      setState(() => _primaryPic = _localCover());
    }
  }

  String? _selectedKey() {
    return _selectedArtwork >= 0 && _selectedArtwork < _artworks.length
        ? _artworks[_selectedArtwork].key
        : null;
  }

  /// 合并三份来源；显式选择在线候选且在线提供封面时，在线封面替换本地封面。
  List<AlbumArtwork> _composeArtworks(List<AlbumArtwork> local) {
    final onlineHasFront =
        _onlineMain.any(
          (artwork) => artwork.role == AlbumArtworkRole.front,
        ) ||
        _onlineSupplement.any(
          (artwork) => artwork.role == AlbumArtworkRole.front,
        );
    final base = _explicitOnline && onlineHasFront
        ? local.where((artwork) => artwork.role != AlbumArtworkRole.front)
        : local;
    return mergeArtworks(<AlbumArtwork>[
      ...base,
      ..._onlineMain,
      ..._onlineSupplement,
    ]);
  }

  /// 用三份来源重建展示列表；每次只更新一份来源后调用。
  void _rebuildArtworks() {
    _artworks = _composeArtworks(_localArtworks);
  }

  /// 当前补充图片是否仍属于 [candidateId]；候选变化时旧补充图必须丢弃。
  List<AlbumArtwork> _supplementFor(String? candidateId) {
    return candidateId != null && candidateId == _supplementKey
        ? _onlineSupplement
        : const <AlbumArtwork>[];
  }

  /// 优先本地文件夹封面，其次任意封面，最后退回列表第 0 项。
  int _preferredFrontIndex(List<AlbumArtwork> artworks) {
    if (artworks.isEmpty) return -1;
    var index = artworks.indexWhere(
      (artwork) =>
          artwork.role == AlbumArtworkRole.front &&
          artwork.source == AlbumArtworkSource.folderFile,
    );
    if (index >= 0) return index;
    index = artworks.indexWhere(
      (artwork) => artwork.role == AlbumArtworkRole.front,
    );
    return index >= 0 ? index : 0;
  }

  bool _needsOnlineSupplements(List<AlbumArtwork> artworks) {
    bool missing(AlbumArtworkRole role) {
      return !artworks.any((artwork) => artwork.role == role);
    }

    return missing(AlbumArtworkRole.back) ||
        missing(AlbumArtworkRole.disc) ||
        missing(AlbumArtworkRole.booklet);
  }

  AlbumArtworkRole _roleOfOnline(String role) {
    return switch (role.trim().toLowerCase()) {
      'front' => AlbumArtworkRole.front,
      'back' => AlbumArtworkRole.back,
      'disc' => AlbumArtworkRole.disc,
      'booklet' => AlbumArtworkRole.booklet,
      _ => AlbumArtworkRole.other,
    };
  }

  Future<void> _applyCandidateCache(
    OnlineAlbumCandidateCache? cache, {
    String? previousUrl,
    int? requestId,
  }) async {
    final info = cache?.info;
    final onlineArtworks = info?.artworks ?? const <OnlineAlbumArtwork>[];
    // 显式选择候选时直接展示其封面；否则保持本地封面优先，本地没有
    // 封面时才使用在线图。
    final explicit = cache?.hasExplicitSelection ?? false;
    final candidate = cache?.activeCandidate;
    final candidateId = candidate?.id.trim();
    final supplement = _supplementFor(candidateId);

    final mapped = <AlbumArtwork>[
      for (final artwork in onlineArtworks)
        AlbumArtwork(
          role: _roleOfOnline(artwork.role),
          source: AlbumArtworkSource.online,
          label: artwork.label,
          url: artwork.url,
          largeUrl: artwork.largeUrl,
        ),
    ];
    // 查询失败时保留上一轮已展示的在线图，避免界面闪回本地封面。
    final previousOnline = cache == null ? _onlineMain : const <AlbumArtwork>[];
    final merged = mergeArtworks(<AlbumArtwork>[
      ..._localArtworks,
      ...supplement,
      ...previousOnline,
      ...mapped,
    ]);

    final currentKey = _selectedKey();
    var selected = -1;
    if (previousUrl != null) {
      selected = merged.indexWhere(
        (artwork) =>
            artwork.source == AlbumArtworkSource.online &&
            artwork.url == previousUrl,
      );
    }
    if (selected < 0 && explicit) {
      selected = merged.indexWhere(
        (artwork) =>
            artwork.source == AlbumArtworkSource.online &&
            artwork.role == AlbumArtworkRole.front,
      );
    }
    if (selected < 0 && currentKey != null) {
      selected = merged.indexWhere((artwork) => artwork.key == currentKey);
    }
    if (selected < 0) selected = _preferredFrontIndex(merged);
    final selectedKey = selected >= 0 ? merged[selected].key : null;

    final cover = selected >= 0
        ? await _resolveArtwork(merged[selected])
        : await _localCover();
    if (!mounted || (requestId != null && requestId != _onlineRequestId)) {
      return;
    }
    setState(() {
      _onlineLoading = false;
      _onlineDone = true;
      _candidateCache = cache;
      _onlineInfo = info;
      _onlineStatus = _onlineAlbum.queryStatusFor(widget.album);
      _explicitOnline = explicit;
      _onlineMain = cache == null ? _onlineMain : mapped;
      if (candidateId == null || candidateId != _supplementKey) {
        _onlineSupplement = const [];
        _supplementKey = null;
      }
      _rebuildArtworks();

      final index = selectedKey == null
          ? -1
          : _artworks.indexWhere((artwork) => artwork.key == selectedKey);
      final finalIndex = index >= 0
          ? index
          : _preferredFrontIndex(_artworks);
      _selectedArtwork = finalIndex;
      if (finalIndex < 0) {
        _primaryPic = Future<ImageProvider?>.value(cover);
      } else if (_artworks[finalIndex].key == selectedKey) {
        _primaryPic = Future<ImageProvider?>.value(cover);
      } else {
        _primaryPic = _resolveArtwork(_artworks[finalIndex]);
      }
    });

    if (candidate != null && _needsOnlineSupplements(_artworks)) {
      unawaited(_loadSupplements(candidate));
    }
  }

  /// 补查在线封底、碟片与内页，结果只并入图片列表，不替换当前选中图。
  Future<void> _loadSupplements(OnlineAlbumCandidate candidate) async {
    final key = candidate.id.trim();
    if (key.isEmpty || _supplementKey == key) return;
    _supplementKey = key;

    List<AlbumArtwork> mapped = const [];
    try {
      final extra = await _onlineAlbum.fetchSupplementArtworks(candidate);
      mapped = <AlbumArtwork>[
        for (final artwork in extra)
          AlbumArtwork(
            role: _roleOfOnline(artwork.role),
            source: AlbumArtworkSource.online,
            label: artwork.label,
            url: artwork.url,
            largeUrl: artwork.largeUrl,
          ),
      ];
    } catch (error) {
      log.library.warn(
        'online_album_supplement_ui_failed',
        '在线专辑补充图片加载失败',
        fields: {
          'candidate': candidate.source,
          'error': error.runtimeType.toString(),
        },
      );
      if (_supplementKey == key) _supplementKey = null;
      return;
    }
    if (!mounted || _supplementKey != key) return;
    if (mapped.isEmpty) {
      // 成功但没有补充图时允许下次进入页面重试，避免网络短暂失败后永久缺失。
      _supplementKey = null;
      return;
    }

    final currentKey = _selectedKey();
    final supplement = mergeArtworks(<AlbumArtwork>[
      ..._onlineSupplement,
      ...mapped,
    ]);

    setState(() {
      _onlineSupplement = supplement;
      _rebuildArtworks();
      var index = currentKey == null
          ? -1
          : _artworks.indexWhere((artwork) => artwork.key == currentKey);
      if (index < 0) index = _preferredFrontIndex(_artworks);
      if (index < 0) return;
      _selectedArtwork = index;
      if (_artworks[index].key != currentKey) {
        _primaryPic = _resolveArtwork(_artworks[index]);
      }
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
    _dialogCache = cache;
    final choice = await showOnlineCandidateDialog(
      context,
      title: '选择专辑来源',
      options: _candidateOptions(cache),
      selectedId: cache?.selectedCandidateId ?? cache?.activeCandidate?.id,
      disabled: cache?.disabled ?? false,
      artworkLoader: _onlineAlbum.artwork,
      initialQuery: _initialQuery(cache),
      defaultQuery: _defaultQuery,
      searchHint: '专辑名、艺术家或任意关键词',
      search: _searchCandidates,
    );
    if (choice == null || !mounted) return;
    await _applyCandidateChoice(choice);
  }

  /// 实体默认搜索词：专辑名与艺术家各自去掉首尾空白后拼接，只保留非空项；
  /// 两者都为空时返回空串。
  String get _defaultQuery {
    final title = widget.album.name.trim();
    final artist = albumArtistFor(widget.album).trim();
    return <String>[
      if (title.isNotEmpty) title,
      if (artist.isNotEmpty) artist,
    ].join(' ');
  }

  /// 对话框初始搜索词：优先回显缓存里用户上次使用的词，否则用默认词。
  String _initialQuery(OnlineAlbumCandidateCache? cache) {
    final saved = cache?.searchQuery?.trim();
    if (saved != null && saved.isNotEmpty) return saved;
    return _defaultQuery;
  }

  List<OnlineCandidateOption> _candidateOptions(
    OnlineAlbumCandidateCache? cache,
  ) {
    return <OnlineCandidateOption>[
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
  }

  /// 按用户提交的词重新搜索。
  ///
  /// 词等于默认词时走服务的默认分字段查询（`query: null`）；服务层拒绝该词
  /// （失败或无结果）时返回空列表，页面状态、候选缓存与主图保持不动，由对话
  /// 框保留原列表并提示。本次搜索占用新的请求号，尚未完成的页面加载不得覆盖
  /// 搜索结果。
  Future<List<OnlineCandidateOption>> _searchCandidates(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <OnlineCandidateOption>[];
    final isDefaultQuery = trimmed == _defaultQuery;
    final previous = _dialogCache ?? _candidateCache;
    final previousUrl =
        _selectedArtwork >= 0 && _selectedArtwork < _artworks.length
        ? _artworks[_selectedArtwork].url
        : null;
    final hadPendingLoad = _onlineLoading;
    final requestId = ++_onlineRequestId;
    try {
      final cache = await _onlineAlbum.loadCandidates(
        widget.album,
        query: isDefaultQuery ? null : trimmed,
        force: true,
      );
      if (!mounted || requestId != _onlineRequestId) {
        return const <OnlineCandidateOption>[];
      }
      final accepted = isDefaultQuery
          ? cache != null &&
                _onlineAlbum.queryStatusFor(widget.album) !=
                    OnlineQueryStatus.failed &&
                !identical(cache, previous) &&
                (previous == null || cache.savedAt != previous.savedAt)
          : cache?.searchQuery?.trim() == trimmed;
      if (!accepted || cache == null) {
        _settleSearch(requestId, hadPendingLoad: hadPendingLoad);
        return const <OnlineCandidateOption>[];
      }
      _dialogCache = cache;
      await _applyCandidateCache(
        cache,
        previousUrl: previousUrl,
        requestId: requestId,
      );
      if (!mounted || requestId != _onlineRequestId) {
        return const <OnlineCandidateOption>[];
      }
      return _candidateOptions(cache);
    } catch (error) {
      log.library.warn(
        'online_album_candidates_search_failed',
        '在线专辑候选搜索失败',
        fields: {'error': error.runtimeType.toString()},
      );
      _settleSearch(requestId, hadPendingLoad: hadPendingLoad);
      return const <OnlineCandidateOption>[];
    }
  }

  /// 搜索没有产生可展示的结果时结束它占用的请求号：复位加载标记，并在本次
  /// 搜索作废了尚未完成的页面加载时按服务层当前查询状态收尾，避免界面停在
  /// 永久的加载态。
  void _settleSearch(int requestId, {required bool hadPendingLoad}) {
    if (!mounted || requestId != _onlineRequestId) return;
    setState(() {
      _onlineLoading = false;
      if (hadPendingLoad && !_onlineDone) {
        _onlineStatus = _onlineAlbum.queryStatusFor(widget.album);
        _onlineDone = true;
      }
    });
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

  /// 读取一张专辑图片作为主图；来源之间互不覆盖，失败统一回退本地封面。
  Future<ImageProvider?> _resolveArtwork(AlbumArtwork artwork) async {
    try {
      if (artwork.source == AlbumArtworkSource.online) {
        final provider = await _onlineAlbum.artwork(artwork.url ?? '');
        return provider ?? await _localCover();
      }
      final path = artwork.path;
      if (path == null || path.isEmpty) return _localCover();
      final provider = await CoverImageCache.instance.getArtwork(
        path: path,
        pictureIndex: artwork.pictureIndex,
        modified: artwork.modified,
        width: 600,
        height: 600,
      );
      return provider ?? await _localCover();
    } catch (error) {
      log.library.warn(
        'album_artwork_ui_failed',
        '专辑图片显示失败',
        fields: {
          'source': artwork.source.name,
          'error': error.runtimeType.toString(),
        },
      );
      return _localCover();
    }
  }

  Future<ImageProvider?> _thumbnailOf(AlbumArtwork artwork, int size) async {
    try {
      if (artwork.source == AlbumArtworkSource.online) {
        return _onlineAlbum.artwork(artwork.url ?? '');
      }
      final path = artwork.path;
      if (path == null || path.isEmpty) return null;
      return CoverImageCache.instance.getArtwork(
        path: path,
        pictureIndex: artwork.pictureIndex,
        modified: artwork.modified,
        width: size,
        height: size,
      );
    } catch (error) {
      log.library.warn(
        'album_artwork_thumbnail_failed',
        '专辑缩略图加载失败',
        fields: {
          'source': artwork.source.name,
          'error': error.runtimeType.toString(),
        },
      );
      return null;
    }
  }

  /// 查看器大图：在线图优先用 largeUrl，本地图按目标尺寸解码。
  Future<ImageProvider?> _loadArtworkAtSize(
    AlbumArtwork artwork,
    int width,
    int height,
  ) async {
    try {
      if (artwork.source == AlbumArtworkSource.online) {
        final provider = await _onlineAlbum.artwork(
          artwork.largeUrl ?? artwork.url ?? '',
        );
        return provider ?? await _localCover();
      }
      final path = artwork.path;
      if (path == null || path.isEmpty) return _localCover();
      // 查看器传入的是物理像素，缓存层会再乘一次设备像素比，这里先换算回逻辑像素。
      final ratio = MediaQuery.devicePixelRatioOf(context);
      final maxLogical = (2048 / ratio).ceil().clamp(1, 2048).toInt();
      final logicalWidth = (width / ratio).round().clamp(1, maxLogical).toInt();
      final logicalHeight = (height / ratio).round().clamp(1, maxLogical).toInt();
      final provider = await CoverImageCache.instance.getArtwork(
        path: path,
        pictureIndex: artwork.pictureIndex,
        modified: artwork.modified,
        width: logicalWidth,
        height: logicalHeight,
      );
      return provider ?? await _localCover();
    } catch (error) {
      log.library.warn(
        'album_artwork_viewer_failed',
        '专辑大图加载失败',
        fields: {
          'source': artwork.source.name,
          'error': error.runtimeType.toString(),
        },
      );
      return _localCover();
    }
  }

  void _openArtworkViewer() {
    if (_artworks.isEmpty) return;
    final index = _selectedArtwork < 0
        ? 0
        : _selectedArtwork.clamp(0, _artworks.length - 1).toInt();
    unawaited(
      showAlbumArtworkViewer(
        context,
        artworks: _artworks,
        initialIndex: index,
        loader: _loadArtworkAtSize,
      ),
    );
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
      status: _onlineStatus,
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
          ? AlbumArtworkSwitcher(
              artworks: _artworks,
              selectedIndex: _selectedArtwork,
              onSelect: _selectArtwork,
              thumbnailOf: _thumbnailOf,
            )
          : null,
      onPrimaryPicTap: _artworks.isNotEmpty ? _openArtworkViewer : null,
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
    this.onPrimaryPicTap,
  });

  final Album album;
  final Future<ImageProvider?> primaryPic;
  final ImageProvider? primaryPicFallback;
  final Widget? headerTrailing;
  final Widget? headerCoverOverlay;
  final VoidCallback? onPrimaryPicTap;

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
      heroTag: 'album:${album.identityPath}',
      primaryPicSeed: album.cachedDetailCover,
      headerTrailing: headerTrailing,
      // 在线专辑面板比在线头像面板内容多，右侧摆放需要更宽的空间；977 宽
      // 内容区下改放到标题下方，避免挤压标题、操作区与正文高度。
      headerTrailingSideMinWidth: 1100,
      headerCoverOverlay: headerCoverOverlay,
      onPrimaryPicTap: onPrimaryPicTap,
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
    this.status,
    this.onRefresh,
    this.onChoose,
    this.onClose,
  });

  final OnlineAlbumInfo? info;
  final bool loading;
  final bool disabled;
  final OnlineQueryStatus? status;
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
      if (loading) return '正在读取专辑信息…';
      return switch (status) {
        OnlineQueryStatus.failed => '在线源请求失败，可点刷新重试',
        OnlineQueryStatus.noMatch => '在线源无匹配结果，可点刷新重试',
        _ => '暂无在线信息',
      };
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
