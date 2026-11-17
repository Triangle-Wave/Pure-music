import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pure_music/component/badge_raster_cache.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';

/// 列表数据只有采样率、位深与码率：采样率高于 CD 的 44.1 kHz 即为 Hi-Res，
/// 44.1 kHz 则需要位深不低于 24 bit；DSD 本身即高解析，一律算 Hi-Res。
bool isHiResAudio(Audio audio) {
  if (isDsdAudio(audio)) return true;
  final rate = audio.sampleRate;
  if (rate == null) return false;
  if (rate > 44100) return true;
  final depth = audio.bitDepth;
  return rate == 44100 && depth != null && depth >= 24;
}

/// DSD 判定：SACD 虚拟轨、DSF/DFF 来源、DSD 采样率或 DSD 源文件路径
/// 任一命中即为 DSD；`by` 记录标签来源，SACD ISO 解析出的轨道标记为 sacd。
bool isDsdAudio(Audio audio) {
  if (audio.isSacdTrack) return true;

  final by = audio.by?.toLowerCase();
  if (by == 'dsf' || by == 'dff' || by == 'sacd') return true;

  final sampleRate = audio.sampleRate;
  if (sampleRate != null && sampleRate >= 2822400) return true;

  final lowerPath = audio.path.toLowerCase();
  if (lowerPath.contains('::sacd=')) return true;

  // CUE/SACD 虚拟轨路径带 `::track=` 等段信息，取合成段之前的源文件部分。
  final separator = lowerPath.indexOf('::');
  final sourcePath = separator < 0
      ? lowerPath
      : lowerPath.substring(0, separator);
  return sourcePath.endsWith('.dsf') || sourcePath.endsWith('.dff');
}

/// DSD 徽标官方矢量宽高比。
const double dsdBadgeWidthRatio = 500 / 253.76521;

/// 徽标组紧凑布局的间距口径：DSD 宽 + 徽标间距 6 + Hi-Res 宽 + 尾距 8。
int compactBadgeGroupMaxWidthValueFor(double height) =>
    (height * dsdBadgeWidthRatio + 6 + height + 8).ceil();

/// 紧凑布局下徽标组可占用的最大宽度；超出时整体等比缩小，剩余宽度留给标题。
/// 数值随当前徽标尺寸设置动态计算，20px 时为 74。
double get compactBadgeGroupMaxWidth =>
    compactBadgeGroupMaxWidthValueFor(AppSettings.instance.hiResBadgeSizePx)
        .toDouble();

/// 供测试和引用页按显式高度计算紧凑布局上限。
double compactBadgeGroupMaxWidthFor(double height) =>
    compactBadgeGroupMaxWidthValueFor(height).toDouble();

/// 预渲染位图徽标：首次使用时把 SVG 栅格化并全局缓存，滚动时只做位图 blit。
/// 加载中或栅格化失败时按同尺寸占位，不影响列表布局。
class _RasterBadge extends StatelessWidget {
  const _RasterBadge({
    required this.assetName,
    required this.label,
    required this.widthRatio,
  });

  final String assetName;
  final String label;
  final double widthRatio;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.badgeSizeNotifier,
      builder: (context, _) {
        final badgeHeight = AppSettings.instance.hiResBadgeSizePx;
        final badgeWidth = badgeHeight * widthRatio;
        final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
        final pixelSize = badgeRasterPixelSize(
          logicalSize: badgeHeight,
          devicePixelRatio: dpr,
          widthRatio: widthRatio,
        );
        // rasterizeBadge 是带首次填充的缓存查找，同一 key 返回同一个 Future。
        final future = rasterizeBadge(assetName: assetName, size: pixelSize);
        return Semantics(
          label: label,
          image: true,
          child: FutureBuilder<ui.Image?>(
            future: future,
            builder: (_, snapshot) {
              final image = snapshot.data;
              if (image == null) {
                return SizedBox(width: badgeWidth, height: badgeHeight);
              }
              return RawImage(
                image: image,
                width: badgeWidth,
                height: badgeHeight,
                fit: BoxFit.contain,
              );
            },
          ),
        );
      },
    );
  }
}

/// Hi-Res 金色方形矢量标签：高度跟随徽标尺寸设置，宽度与高度一致。
class HiResBadge extends StatelessWidget {
  const HiResBadge({super.key});

  /// 当前显示高度，跟随全局徽标尺寸设置。
  static double get height => AppSettings.instance.hiResBadgeSizePx;
  static double get width => height;

  static const String _asset = 'assets/images/hi_res_audio_logo.svg';

  @override
  Widget build(BuildContext context) {
    return const _RasterBadge(
      assetName: _asset,
      label: 'Hi-Res',
      widthRatio: 1.0,
    );
  }
}

/// DSD 黑色矢量标签：高度跟随徽标尺寸设置，宽度按官方 SVG 500×253.76521 比例。
class DsdBadge extends StatelessWidget {
  const DsdBadge({super.key});

  /// 当前显示高度，跟随全局徽标尺寸设置。
  static double get height => AppSettings.instance.hiResBadgeSizePx;
  static double get width => height * dsdBadgeWidthRatio;

  static const String _asset = 'assets/images/dsd_logo.svg';

  @override
  Widget build(BuildContext context) {
    return const _RasterBadge(
      assetName: _asset,
      label: 'DSD',
      widthRatio: dsdBadgeWidthRatio,
    );
  }
}
