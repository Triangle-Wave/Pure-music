import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/library/album_artwork.dart';

/// 封面切换器：左右按钮循环切换全部图片，缩略图直接选中。
///
/// 缩略图由 [thumbnailOf] 注入，组件本身不依赖任何图片来源；加载失败、返回
/// 空值或解码失败时统一显示 [Symbols.album] 占位。
class AlbumArtworkSwitcher extends StatefulWidget {
  const AlbumArtworkSwitcher({
    super.key,
    required this.artworks,
    required this.selectedIndex,
    required this.onSelect,
    required this.thumbnailOf,
  });

  final List<AlbumArtwork> artworks;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// 读取缩略图；[size] 是物理像素边长。
  final Future<ImageProvider?> Function(AlbumArtwork artwork, int size)
      thumbnailOf;

  @override
  State<AlbumArtworkSwitcher> createState() => _AlbumArtworkSwitcherState();
}

class _AlbumArtworkSwitcherState extends State<AlbumArtworkSwitcher> {
  /// 缩略图显示边长（逻辑像素）。
  static const double _thumbnailSize = 22;

  /// 缩略图占位图标边长（逻辑像素）。
  static const double _placeholderSize = 13;

  final Map<String, Future<ImageProvider?>> _thumbnails = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _primeThumbnails();
  }

  @override
  void didUpdateWidget(covariant AlbumArtworkSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    _primeThumbnails();
  }

  int get _targetSize =>
      (_thumbnailSize * MediaQuery.devicePixelRatioOf(context)).round();

  void _primeThumbnails() {
    if (!mounted) return;
    // 传给加载器的是逻辑像素，缓存层按设备像素比换算物理尺寸。
    final size = _thumbnailSize.round();
    for (final index in _visibleIndexes()) {
      final artwork = widget.artworks[index];
      final key = '${artwork.key}|$size';
      if (_thumbnails.containsKey(key)) continue;
      final future = _loadThumbnail(artwork, size);
      _thumbnails[key] = future;
      unawaited(
        future.then<void>((provider) {
          if (provider == null && identical(_thumbnails[key], future)) {
            _thumbnails.remove(key);
          }
        }),
      );
    }
  }

  Future<ImageProvider?> _loadThumbnail(AlbumArtwork artwork, int size) {
    try {
      return widget
          .thumbnailOf(artwork, size)
          .then<ImageProvider?>(
            (provider) => provider,
            onError: (Object error, StackTrace stackTrace) => null,
          );
    } catch (error) {
      return Future<ImageProvider?>.value();
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
    // 未选中图片时，右箭头从第一张开始，左箭头从最后一张开始。
    final current = widget.selectedIndex;
    final start = current < 0 ? (delta > 0 ? -1 : 0) : current;
    widget.onSelect((start + delta + total) % total);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = widget.artworks.length;
    if (total == 0) return const SizedBox.shrink();
    _primeThumbnails();
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
    final target = _targetSize;
    final future = _thumbnails['${artwork.key}|${_thumbnailSize.round()}'];
    return Tooltip(
      message: artwork.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => widget.onSelect(index),
          child: Container(
            width: _thumbnailSize,
            height: _thumbnailSize,
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
                future: future,
                builder: (context, snapshot) {
                  final provider = snapshot.data;
                  if (provider == null || snapshot.hasError) {
                    return _placeholder(scheme);
                  }
                  return Image(
                    image: ResizeImage(
                      provider,
                      width: target,
                      height: target,
                      allowUpscaling: false,
                    ),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => _placeholder(scheme),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme) {
    return Icon(
      Symbols.album,
      size: _placeholderSize,
      color: scheme.onSurfaceVariant,
    );
  }
}
