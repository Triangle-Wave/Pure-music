import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/library/album_artwork.dart';

/// 大图边长上限（物理像素）。
const int _maxViewerImageSide = 2048;

/// 打开多图查看器。
///
/// [loader] 按目标物理像素尺寸读取图片；返回值或解码失败时页面显示占位，
/// 不会把异常抛到界面。空列表直接返回，不创建对话框。单张图片不显示切换
/// 箭头；[showCounter] 为空时底部计数也按图片数量决定。
Future<void> showImageGalleryViewer<T>(
  BuildContext context, {
  required List<T> items,
  required int initialIndex,
  required Object Function(T item) keyOf,
  required String Function(T item) labelOf,
  required Future<ImageProvider?> Function(
    T item,
    int width,
    int height,
  ) loader,
  IconData placeholderIcon = Symbols.album,
  bool? showCounter,
}) {
  if (items.isEmpty) return Future<void>.value();
  final index = initialIndex.clamp(0, items.length - 1).toInt();
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black,
    builder: (context) => _ImageViewerDialog<T>(
      items: List<T>.unmodifiable(items),
      initialIndex: index,
      keyOf: keyOf,
      labelOf: labelOf,
      loader: loader,
      placeholderIcon: placeholderIcon,
      showCounter: showCounter ?? items.length > 1,
    ),
  );
}

/// 打开单张图片查看器。
Future<void> showSingleImageViewer(
  BuildContext context, {
  required Future<ImageProvider?> Function(int width, int height) loader,
  String? title,
  IconData placeholderIcon = Symbols.album,
}) {
  return showImageGalleryViewer<int>(
    context,
    items: const <int>[0],
    initialIndex: 0,
    keyOf: (item) => item,
    labelOf: (_) => title ?? '',
    loader: (_, width, height) => loader(width, height),
    placeholderIcon: placeholderIcon,
  );
}

/// 打开专辑图片查看器。
///
/// [loader] 按目标物理像素尺寸读取图片；返回值或解码失败时页面显示占位，
/// 不会把异常抛到界面。空列表直接返回，不创建对话框。
Future<void> showAlbumArtworkViewer(
  BuildContext context, {
  required List<AlbumArtwork> artworks,
  required int initialIndex,
  required Future<ImageProvider?> Function(
    AlbumArtwork artwork,
    int width,
    int height,
  ) loader,
}) {
  return showImageGalleryViewer<AlbumArtwork>(
    context,
    items: artworks,
    initialIndex: initialIndex,
    keyOf: (artwork) => artwork.key,
    labelOf: (artwork) => artwork.label,
    loader: loader,
    showCounter: true,
  );
}

class _ImageViewerDialog<T> extends StatefulWidget {
  const _ImageViewerDialog({
    required this.items,
    required this.initialIndex,
    required this.keyOf,
    required this.labelOf,
    required this.loader,
    required this.placeholderIcon,
    required this.showCounter,
  });

  final List<T> items;
  final int initialIndex;
  final Object Function(T item) keyOf;
  final String Function(T item) labelOf;
  final Future<ImageProvider?> Function(T item, int width, int height) loader;
  final IconData placeholderIcon;
  final bool showCounter;

  @override
  State<_ImageViewerDialog<T>> createState() => _ImageViewerDialogState<T>();
}

class _ImageViewerDialogState<T> extends State<_ImageViewerDialog<T>> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final total = widget.items.length;
    if (total <= 1) return;
    final target = (_index + delta) % total;
    final page = target < 0 ? target + total : target;
    if (!_controller.hasClients) {
      setState(() => _index = page);
      return;
    }
    unawaited(
      _controller.animateToPage(
        page,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _close() {
    unawaited(Navigator.of(context).maybePop());
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    // 解码目标取窗口宽高：图片按目标框等比缩放，宽图与竖图都能拿到长边
    // 足够的解码尺寸，contain 放大时不丢细节；正方形封面自然落到最短边。
    final width = (size.width * devicePixelRatio)
        .round()
        .clamp(1, _maxViewerImageSide)
        .toInt();
    final height = (size.height * devicePixelRatio)
        .round()
        .clamp(1, _maxViewerImageSide)
        .toInt();
    final current = widget.items[_index];
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): _close,
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
        },
        child: Focus(
          autofocus: true,
          child: SizedBox.expand(
            child: Stack(
              fit: StackFit.expand,
              children: [
                PageView.builder(
                  controller: _controller,
                  itemCount: widget.items.length,
                  onPageChanged: (index) {
                    if (!mounted) return;
                    setState(() => _index = index);
                  },
                  itemBuilder: (context, index) {
                    final item = widget.items[index];
                    return _ArtworkPage<T>(
                      key: ValueKey<Object>(widget.keyOf(item)),
                      item: item,
                      label: widget.labelOf(item),
                      width: width,
                      height: height,
                      loader: widget.loader,
                      placeholderIcon: widget.placeholderIcon,
                    );
                  },
                ),
                if (widget.items.length > 1) ...[
                  _arrow(forward: false),
                  _arrow(forward: true),
                ],
                _topBar(current),
                if (widget.showCounter) _bottomBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _arrow({required bool forward}) {
    return Align(
      alignment: forward ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: IconButton(
          onPressed: () => _go(forward ? 1 : -1),
          tooltip: forward ? '下一张' : '上一张',
          icon: Icon(
            forward ? Symbols.chevron_right : Symbols.chevron_left,
            size: 28,
          ),
          style: IconButton.styleFrom(
            backgroundColor: Colors.black.withValues(alpha: 0.42),
            foregroundColor: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _topBar(T item) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.labelOf(item),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _close,
                tooltip: '关闭',
                icon: const Icon(Symbols.close),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.16),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            '第 ${_index + 1} / ${widget.items.length} 张',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      ),
    );
  }
}

class _ArtworkPage<T> extends StatefulWidget {
  const _ArtworkPage({
    super.key,
    required this.item,
    required this.label,
    required this.width,
    required this.height,
    required this.loader,
    required this.placeholderIcon,
  });

  final T item;

  /// 顶栏标题与占位文案。
  final String label;

  /// 目标物理像素尺寸。
  final int width;
  final int height;

  final Future<ImageProvider?> Function(T item, int width, int height) loader;

  final IconData placeholderIcon;

  @override
  State<_ArtworkPage<T>> createState() => _ArtworkPageState<T>();
}

class _ArtworkPageState<T> extends State<_ArtworkPage<T>> {
  late Future<ImageProvider?> _image;

  @override
  void initState() {
    super.initState();
    _image = _load();
  }

  @override
  void didUpdateWidget(covariant _ArtworkPage<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.label != widget.label ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height) {
      _image = _load();
    }
  }

  Future<ImageProvider?> _load() {
    try {
      return widget
          .loader(widget.item, widget.width, widget.height)
          .then<ImageProvider?>(
            (provider) => provider,
            onError: (Object error, StackTrace stackTrace) {
              log.app.debug(
                'album_artwork_viewer_load_failed',
                '图片查看器加载失败，显示占位',
                error: error,
                stackTrace: stackTrace,
              );
              return null;
            },
          );
    } catch (error, stackTrace) {
      log.app.debug(
        'album_artwork_viewer_load_failed',
        '图片查看器加载失败，显示占位',
        error: error,
        stackTrace: stackTrace,
      );
      return Future<ImageProvider?>.value();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ImageProvider?>(
      future: _image,
      builder: (context, snapshot) {
        final provider = snapshot.data;
        final failed =
            snapshot.hasError ||
            (snapshot.connectionState == ConnectionState.done &&
                provider == null);
        if (failed) return _placeholder();
        if (provider == null) {
          return const Center(
            child: SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(strokeWidth: 2.6),
            ),
          );
        }
        return InteractiveViewer(
          minScale: 0.8,
          maxScale: 4,
          child: SizedBox.expand(
            child: Image(
              image: provider,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _placeholder(),
            ),
          ),
        );
      },
    );
  }

  Widget _placeholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(widget.placeholderIcon, size: 56, color: Colors.white54),
          const SizedBox(height: 10),
          Text(
            widget.label,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
