import 'dart:math' as math;

import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/component/cover_pointer_sheen.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/scroll_aware_future_builder.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/menu_styles.dart';
import 'package:pure_music/core/settings.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/paths.dart' as app_paths;

class AlbumTile extends StatefulWidget {
  const AlbumTile({
    super.key,
    required this.album,
    this.multiSelectController,
    this.view = ContentView.list,
    this.enableHero = true,
  });

  final Album album;
  final MultiSelectController<Album>? multiSelectController;
  final ContentView view;

  /// 详情页三级标签里禁用 Hero，避免与详情页头部的 Hero 标签冲突。
  final bool enableHero;

  @override
  State<AlbumTile> createState() => _AlbumTileState();
}

class _AlbumTileState extends State<AlbumTile> {
  int get _coverSize => widget.view == ContentView.list ? 48 : 160;
  String get _currentCoverIdentity => '${widget.album.primaryPath}|$_coverSize';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected =
        widget.multiSelectController?.selected.contains(widget.album) == true;
    final isMultiSelectView =
        widget.multiSelectController?.enableMultiSelectView == true;
    return MenuTheme(
      data: MenuThemeData(style: appMenuStyle),
      child: MenuAnchor(
        consumeOutsideTap: true,
        style: appMenuStyle,
        menuChildren: _menuChildren(context),
        builder: (context, controller, _) => DirectionalListItemEntrance(
          identity: widget.album,
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
    );
  }

  List<Widget> _menuChildren(BuildContext context) {
    final menuItemStyle = appMenuItemStyle;
    final hasWorks = widget.album.works.isNotEmpty;
    return [
      MenuItemButton(
        style: menuItemStyle,
        onPressed: hasWorks
            ? () =>
                  context.push(app_paths.ALBUM_DETAIL_PAGE, extra: widget.album)
            : null,
        leadingIcon: const Icon(Symbols.open_in_new),
        child: const Text('打开'),
      ),
      if (widget.multiSelectController != null)
        MenuItemButton(
          style: menuItemStyle,
          onPressed: () {
            widget.multiSelectController!.useMultiSelectView(true);
            widget.multiSelectController!.select(widget.album);
          },
          leadingIcon: const Icon(Symbols.select),
          child: const Text('多选'),
        ),
    ];
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
          child: Stack(
            children: [
              widget.view == ContentView.list
                  ? _listBody(scheme, isSelected, isMultiSelectView)
                  : _gridBody(scheme),
              if (isMultiSelectView && widget.view != ContentView.list)
                _gridCheckbox(isSelected),
            ],
          ),
        ),
      ),
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
      if (widget.album.works.isNotEmpty) {
        context.push(app_paths.ALBUM_DETAIL_PAGE, extra: widget.album);
      }
      return;
    }
    if (isSelected) {
      widget.multiSelectController?.unselect(widget.album);
    } else {
      widget.multiSelectController?.select(widget.album);
    }
  }

  void _onLongPress(bool isMultiSelectView) {
    if (widget.multiSelectController == null) return;
    if (isMultiSelectView) return;
    widget.multiSelectController!.useMultiSelectView(true);
    widget.multiSelectController!.select(widget.album);
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
      size: 48,
      color: scheme.onSurface,
    );
    final hasWorks = widget.album.works.isNotEmpty;
    final cachedCover = hasWorks
        ? widget.album.cachedThumbnailCover(size: _coverSize)
        : null;
    return ScrollAwareFutureBuilder<ImageProvider?>(
      identity: _currentCoverIdentity,
      initialData: cachedCover,
      future: () => hasWorks
          ? widget.album.thumbnailCover(size: _coverSize)
          : Future<ImageProvider?>.value(null),
      builder: (context, snapshot) =>
          _coverSnapshot(snapshot, scheme, placeholder),
    );
  }

  Widget _coverSnapshot(
    AsyncSnapshot<ImageProvider?> snapshot,
    ColorScheme scheme,
    Widget placeholder,
  ) {
    final borderRadius = widget.view == ContentView.list
        ? AppRadius.smCircular
        : const BorderRadius.vertical(top: Radius.circular(8.0));
    if (snapshot.data == null) {
      return snapshot.connectionState == ConnectionState.done
          ? placeholder
          : ClipRRect(
              borderRadius: borderRadius,
              child: Container(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.22),
              ),
            );
    }
    Widget image = Image(
      image: snapshot.data!,
      width: widget.view == ContentView.list ? 48.0 : null,
      height: widget.view == ContentView.list ? 48.0 : null,
      errorBuilder: (_, _, _) => placeholder,
      fit: BoxFit.cover,
      gaplessPlayback: true,
    );
    if (widget.view != ContentView.list) {
      image = CoverPointerSheen(
        enabled: AppSettings.instance.enableCoverPointerSheen,
        child: image,
      );
    }
    final clipped = ClipRRect(borderRadius: borderRadius, child: image);
    if (!widget.enableHero) return clipped;
    return Hero(
      tag: 'album:${widget.album.primaryPath}',
      child: clipped,
    );
  }

  Widget _listBody(
    ColorScheme scheme,
    bool isSelected,
    bool isMultiSelectView,
  ) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          _coverWidget(scheme),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 12.0),
              child: Text(
                widget.album.name,
                softWrap: false,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurface),
              ),
            ),
          ),
          if (isMultiSelectView)
            Checkbox(
              value: isSelected,
              onChanged: (v) => _onCheckbox(v == true),
            ),
        ],
      ),
    );
  }

  Widget _gridBody(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SizedBox(width: double.infinity, child: _coverWidget(scheme)),
        ),
        _gridTitle(scheme),
      ],
    );
  }

  Widget _gridTitle(ColorScheme scheme) {
    final hasWorks = widget.album.works.isNotEmpty;
    final artistLabel = _albumArtistLabel;
    return ScrollAwareFutureBuilder<AlbumColor?>(
      identity: '$_currentCoverIdentity|color',
      future: () => hasWorks
          ? AlbumColorCache.instance.getAlbumColor(widget.album)
          : Future<AlbumColor?>.value(null),
      builder: (context, snapshot) {
        final background = snapshot.data?.primary;
        final foreground = background == null
            ? scheme.onSurface
            : _readableForeground(background, scheme);
        final secondaryForeground = background == null
            ? scheme.onSurfaceVariant
            : foreground.withValues(alpha: 0.78);
        return Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 40.0),
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          decoration: background == null
              ? null
              : BoxDecoration(
                  color: background,
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(8.0),
                  ),
                ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.album.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground,
                  fontWeight: AppType.weightBold,
                ),
              ),
              if (artistLabel != null) ...[
                const SizedBox(height: 2.0),
                Text(
                  artistLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: secondaryForeground,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 卡片上的艺术家名，最多取两位。
  String? get _albumArtistLabel {
    final names = widget.album.artistsMap.keys
        .where((name) => name.trim().isNotEmpty)
        .take(2)
        .toList(growable: false);
    if (names.isEmpty) return null;
    return names.join(' / ');
  }

  /// 标题前景色：优先跟随主题的 onSurface；与卡片底色对比不足时按底色
  /// 亮度取黑或白，避免深底深字、浅底浅字。
  static Color _readableForeground(Color background, ColorScheme scheme) {
    if (_contrastRatio(scheme.onSurface, background) >= 4.5) {
      return scheme.onSurface;
    }
    return ThemeData.estimateBrightnessForColor(background) == Brightness.dark
        ? Colors.white
        : Colors.black;
  }

  static double _contrastRatio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final lighter = math.max(la, lb);
    final darker = math.min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
  }

  Widget _gridCheckbox(bool isSelected) {
    return Positioned(
      top: 6,
      right: 6,
      child: Material(
        type: MaterialType.transparency,
        child: Checkbox(
          value: isSelected,
          onChanged: (v) => _onCheckbox(v == true),
        ),
      ),
    );
  }

  void _onCheckbox(bool selected) {
    if (selected) {
      widget.multiSelectController?.select(widget.album);
    } else {
      widget.multiSelectController?.unselect(widget.album);
    }
  }
}
