import 'dart:async';

import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_candidate_dialog.dart';
import 'package:pure_music/component/scroll_aware_future_builder.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/menu_styles.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/services/online_album/online_album_models.dart';
import 'package:pure_music/services/online_album/online_artist_image_service.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/paths.dart' as app_paths;

/// 诊断埋点：性能工具累计 ArtistTile 构建耗时；未安装观察者时零开销。
int artistTileBuildMicros = 0;

class ArtistTile extends StatefulWidget {
  const ArtistTile({
    super.key,
    required this.artist,
    this.multiSelectController,
    this.view = ContentView.list,
    this.enableHero = true,
  });

  final Artist artist;
  final MultiSelectController<Artist>? multiSelectController;
  final ContentView view;

  /// 详情页三级标签里禁用 Hero，避免与详情页头部的 Hero 标签冲突。
  final bool enableHero;

  @override
  State<ArtistTile> createState() => _ArtistTileState();
}

class _ArtistTileState extends State<ArtistTile> {
  int _onlineRevision = 0;

  String get _currentCoverIdentity =>
      '${widget.artist.primaryPath}|48|$_onlineRevision|'
      '${OnlineArtistImageService.instance.selectionRevision}|'
      '${AppSettings.instance.onlineArtistImageEnabled}';

  @override
  Widget build(BuildContext context) {
    final buildStopwatch = Stopwatch()..start();
    try {
      return _build(context);
    } finally {
      buildStopwatch.stop();
      artistTileBuildMicros += buildStopwatch.elapsed.inMicroseconds;
    }
  }

  Widget _build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected =
        widget.multiSelectController?.selected.contains(widget.artist) == true;
    final isMultiSelectView =
        widget.multiSelectController?.enableMultiSelectView == true;
    return RepaintBoundary(
      child: MenuTheme(
        data: MenuThemeData(style: appMenuStyle),
        child: MenuAnchor(
          consumeOutsideTap: true,
          style: appMenuStyle,
          menuChildren: _menuChildren(context),
          builder: (context, controller, _) => DirectionalListItemEntrance(
            identity: widget.artist,
            child: InteractiveSurfaceMotion(
              enabled:
                  widget.view == ContentView.table &&
                  AppSettings.instance.enableInteractiveSurfaceMotion,
              child: _tileSurface(
                context,
                controller,
                scheme: scheme,
                isSelected: isSelected,
                isMultiSelectView: isMultiSelectView,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _menuChildren(BuildContext context) {
    final menuItemStyle = appMenuItemStyle;
    final hasWorks = widget.artist.works.isNotEmpty;
    return [
      MenuItemButton(
        style: menuItemStyle,
        onPressed: hasWorks
            ? () => context.push(
                app_paths.ARTIST_DETAIL_PAGE,
                extra: widget.artist,
              )
            : null,
        leadingIcon: const Icon(Symbols.open_in_new),
        child: const Text('打开'),
      ),
      if (widget.multiSelectController != null)
        MenuItemButton(
          style: menuItemStyle,
          onPressed: () {
            widget.multiSelectController!.useMultiSelectView(true);
            widget.multiSelectController!.select(widget.artist);
          },
          leadingIcon: const Icon(Symbols.select),
          child: const Text('多选'),
        ),
      if (AppSettings.instance.onlineArtistImageEnabled)
        MenuItemButton(
          style: menuItemStyle,
          onPressed: () => unawaited(_chooseOnlineImage()),
          leadingIcon: const Icon(Symbols.account_box),
          child: const Text('在线头像'),
        ),
    ];
  }

  Future<void> _chooseOnlineImage() async {
    if (!AppSettings.instance.onlineArtistImageEnabled) return;
    final service = OnlineArtistImageService.instance;
    OnlineArtistCandidateCache? cache;
    try {
      cache = await service.loadCandidates(widget.artist.name);
    } catch (error) {
      log.library.warn(
        'artist_tile_online_candidates_failed',
        '艺术家在线候选读取失败',
        fields: {'error': error.runtimeType.toString()},
      );
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
      artworkLoader: service.artwork,
    );
    if (choice == null || !mounted) return;
    try {
      switch (choice.action) {
        case OnlineCandidateAction.auto:
          await service.updateSelection(widget.artist.name);
        case OnlineCandidateAction.disable:
          await service.updateSelection(
            widget.artist.name,
            disabled: true,
          );
        case OnlineCandidateAction.select:
          await service.updateSelection(
            widget.artist.name,
            candidateId: choice.candidateId,
          );
      }
    } catch (error) {
      log.library.warn(
        'artist_tile_online_selection_failed',
        '艺术家在线头像选择失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
    if (!mounted) return;
    setState(() => _onlineRevision++);
  }

  Widget _tileSurface(
    BuildContext context,
    MenuController controller, {
    required ColorScheme scheme,
    required bool isSelected,
    required bool isMultiSelectView,
  }) {
    return AnimatedContainer(
      duration: MotionDuration.fast,
      curve: MotionCurve.standard,
      decoration: BoxDecoration(
        color: isSelected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: AppRadius.smCircular,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          hoverColor: widget.view == ContentView.list
              ? scheme.onSurface.withValues(alpha: Alpha.hover)
              : Colors.transparent,
          onTap: () =>
              _onTap(context, controller, isMultiSelectView, isSelected),
          onLongPress: () => _onLongPress(isMultiSelectView),
          onSecondaryTapDown: (details) =>
              _onSecondaryTap(controller, details, isMultiSelectView),
          borderRadius: AppRadius.smCircular,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                _coverWidget(scheme),
                Flexible(child: _nameLabel(scheme)),
                if (isMultiSelectView) _selectBox(isSelected),
              ],
            ),
          ),
        ),
      ),
    );
  }


  Widget _selectBox(bool isSelected) {
    return Checkbox(
      value: isSelected,
      onChanged: (v) {
        if (v == true) {
          widget.multiSelectController?.select(widget.artist);
        } else {
          widget.multiSelectController?.unselect(widget.artist);
        }
      },
    );
  }

  void _onTap(
    BuildContext context,
    MenuController controller,
    bool isMultiSelectView,
    bool isSelected,
  ) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    if (!isMultiSelectView) {
      if (widget.artist.works.isNotEmpty) {
        context.push(app_paths.ARTIST_DETAIL_PAGE, extra: widget.artist);
      }
      return;
    }
    if (isSelected) {
      widget.multiSelectController?.unselect(widget.artist);
    } else {
      widget.multiSelectController?.select(widget.artist);
    }
  }

  void _onLongPress(bool isMultiSelectView) {
    if (widget.multiSelectController == null) return;
    if (isMultiSelectView) return;
    widget.multiSelectController!.useMultiSelectView(true);
    widget.multiSelectController!.select(widget.artist);
  }

  void _onSecondaryTap(
    MenuController controller,
    TapDownDetails details,
    bool isMultiSelectView,
  ) {
    if (isMultiSelectView) return;
    controller.open(position: details.localPosition.translate(0, -140));
  }

  Widget _coverWidget(ColorScheme scheme) {
    final placeholder = Icon(
      Symbols.queue_music,
      color: scheme.onSurface,
      size: 48,
    );
    final hasWorks = widget.artist.works.isNotEmpty;
    final cachedCover = hasWorks
        ? widget.artist.cachedThumbnailPicture(size: 48)
        : null;
    return ScrollAwareFutureBuilder<ImageProvider?>(
      identity: _currentCoverIdentity,
      initialData: cachedCover,
      future: () => _picture(hasWorks),
      builder: (context, snapshot) {
        if (snapshot.data == null) {
          return snapshot.connectionState == ConnectionState.done
              ? placeholder
              : _coverPlaceholder(scheme);
        }
        final clipped = ClipOval(
          child: Image(
            image: snapshot.data!,
            width: 48.0,
            height: 48.0,
            errorBuilder: (_, _, _) => placeholder,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        );
        if (!widget.enableHero) return clipped;
        return Hero(
          tag: 'artist:${widget.artist.identityPath}',
          child: clipped,
        );
      },
    );
  }

  Future<ImageProvider?> _picture(bool hasWorks) async {
    try {
      final preferred = await OnlineArtistImageService.instance
          .preferredImageFor(widget.artist.name);
      if (preferred != null) return preferred;
    } catch (error) {
      log.library.warn(
        'artist_tile_preferred_picture_failed',
        '艺术家在线头像选择读取失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
    if (!hasWorks) return null;
    try {
      final local = await widget.artist.thumbnailPicture(size: 48);
      if (local != null) return local;
    } catch (error) {
      log.library.warn(
        'artist_tile_local_picture_failed',
        '艺术家本地封面读取失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
    try {
      final online = await OnlineArtistImageService.instance.imageFor(
        widget.artist.name,
      );
      return online;
    } catch (error) {
      log.library.warn(
        'artist_tile_online_picture_failed',
        '艺术家在线头像读取失败',
        fields: {'error': error.runtimeType.toString()},
      );
      return null;
    }
  }


  Widget _coverPlaceholder(ColorScheme scheme) {
    return Container(
      width: 48.0,
      height: 48.0,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.22),
        shape: BoxShape.circle,
      ),
    );
  }

  Widget _nameLabel(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(left: 12.0),
      child: Text(
        widget.artist.name,
        softWrap: widget.view == ContentView.table,
        maxLines: widget.view == ContentView.table ? 2 : 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: scheme.onSurface),
      ),
    );
  }
}
