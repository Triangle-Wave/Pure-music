import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/library/album_artwork.dart';

/// 大图边长上限（物理像素）。
const int _maxViewerImageSide = 2048;

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
  if (artworks.isEmpty) return Future<void>.value();
  final index = initialIndex.clamp(0, artworks.length - 1).toInt();
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black,
    builder: (context) => _AlbumArtworkViewerDialog(
      artworks: List<AlbumArtwork>.unmodifiable(artworks),
      initialIndex: index,
      loader: loader,
    ),
  );
}

class _AlbumArtworkViewerDialog extends StatefulWidget {
  const _AlbumArtworkViewerDialog({
    required this.artworks,
    required this.initialIndex,
    required this.loader,
  });

  final List<AlbumArtwork> artworks;
  final int initialIndex;
  final Future<ImageProvider?> Function(
    AlbumArtwork artwork,
    int width,
    int height,
  ) loader;

  @override
  State<_AlbumArtworkViewerDialog> createState() =>
      _AlbumArtworkViewerDialogState();
}

class _AlbumArtworkViewerDialogState extends State<_AlbumArtworkViewerDialog> {
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
    final total = widget.artworks.length;
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
    final width = (size.width * devicePixelRatio)
        .round()
        .clamp(1, _maxViewerImageSide)
        .toInt();
    final height = (size.height * devicePixelRatio)
        .round()
        .clamp(1, _maxViewerImageSide)
        .toInt();
    final current = widget.artworks[_index];
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
                  itemCount: widget.artworks.length,
                  onPageChanged: (index) {
                    if (!mounted) return;
                    setState(() => _index = index);
                  },
                  itemBuilder: (context, index) => _ArtworkPage(
                    key: ValueKey(widget.artworks[index].key),
                    artwork: widget.artworks[index],
                    width: width,
                    height: height,
                    loader: widget.loader,
                  ),
                ),
                if (widget.artworks.length > 1) ...[
                  _arrow(forward: false),
                  _arrow(forward: true),
                ],
                _topBar(current),
                _bottomBar(),
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

  Widget _topBar(AlbumArtwork artwork) {
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
                  artwork.label,
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
            '第 ${_index + 1} / ${widget.artworks.length} 张',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      ),
    );
  }
}

class _ArtworkPage extends StatefulWidget {
  const _ArtworkPage({
    super.key,
    required this.artwork,
    required this.width,
    required this.height,
    required this.loader,
  });

  final AlbumArtwork artwork;

  /// 目标物理像素尺寸。
  final int width;
  final int height;

  final Future<ImageProvider?> Function(
    AlbumArtwork artwork,
    int width,
    int height,
  ) loader;

  @override
  State<_ArtworkPage> createState() => _ArtworkPageState();
}

class _ArtworkPageState extends State<_ArtworkPage> {
  late Future<ImageProvider?> _image;

  @override
  void initState() {
    super.initState();
    _image = _load();
  }

  @override
  void didUpdateWidget(covariant _ArtworkPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artwork.key != widget.artwork.key ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height) {
      _image = _load();
    }
  }

  Future<ImageProvider?> _load() {
    try {
      return widget
          .loader(widget.artwork, widget.width, widget.height)
          .then<ImageProvider?>(
            (provider) => provider,
            onError: (Object error, StackTrace stackTrace) => null,
          );
    } catch (error) {
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
          const Icon(Symbols.album, size: 56, color: Colors.white54),
          const SizedBox(height: 10),
          Text(
            widget.artwork.label,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
