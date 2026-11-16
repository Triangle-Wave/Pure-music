import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart' show SvgAssetLoader, vg;
import 'package:pure_music/core/log/app_log.dart';

/// 徽标栅格化后的目标像素尺寸。
class BadgeRasterSize {
  const BadgeRasterSize({required this.width, required this.height});

  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is BadgeRasterSize &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'BadgeRasterSize(${width}x$height)';
}

/// 显示逻辑尺寸乘设备像素比后向上取整；长方形徽标按 SVG 宽高比计算宽度。
BadgeRasterSize badgeRasterPixelSize({
  required double logicalSize,
  required double devicePixelRatio,
  double widthRatio = 1.0,
}) {
  final height = (logicalSize * devicePixelRatio).ceil();
  final width = (logicalSize * widthRatio * devicePixelRatio).ceil();
  return BadgeRasterSize(width: width, height: height);
}

/// 缓存键由 asset 路径与目标像素尺寸组成。
String badgeRasterCacheKey(
  String assetName,
  int pixelWidth,
  int pixelHeight,
) => '$assetName@${pixelWidth}x$pixelHeight';

final Map<String, Future<ui.Image?>> _badgeRasterCache =
    <String, Future<ui.Image?>>{};

/// 首次调用把 SVG 栅格化为位图，后续按 asset 与像素尺寸复用同一个 Future。
Future<ui.Image?> rasterizeBadge({
  required String assetName,
  required BadgeRasterSize size,
}) {
  final key = badgeRasterCacheKey(assetName, size.width, size.height);
  return _badgeRasterCache.putIfAbsent(
    key,
    () => _rasterizeBadge(assetName, size),
  );
}

Future<ui.Image?> _rasterizeBadge(String assetName, BadgeRasterSize size) async {
  ui.Picture? sourcePicture;
  ui.Picture? scaledPicture;
  try {
    final info = await vg.loadPicture(SvgAssetLoader(assetName), null);
    sourcePicture = info.picture;
    if (info.size.width <= 0 || info.size.height <= 0) {
      throw StateError('invalid svg size ${info.size}');
    }
    // 按目标高度取单一等比因子，保持 SVG 宽高比，不被缓存宽度的取整拉伸。
    final scaleFactor = size.height / info.size.height;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.scale(scaleFactor, scaleFactor);
    canvas.drawPicture(info.picture);
    scaledPicture = recorder.endRecording();
    return await scaledPicture.toImage(size.width, size.height);
  } catch (error, stackTrace) {
    log.app.warn(
      'badge-raster',
      '徽标栅格化失败: $assetName ${size.width}x${size.height}',
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  } finally {
    scaledPicture?.dispose();
    sourcePicture?.dispose();
  }
}
