import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// 详情页头部 trailing 面板的摆放位置。
enum DetailHeaderTrailingPlacement {
  /// 不显示 trailing 面板。
  none,

  /// 面板放在标题区右侧。
  side,

  /// 面板放在标题区下方。
  stacked,
}

/// 详情页头部的宽度预算。
///
/// 头部由「封面 + 间距 + 标题区（可选 trailing 面板）」组成。封面尺寸随
/// 折叠进度变化，因此每次布局都按实际可用宽度重新分配，保证标题区拿到
/// 可读宽度；宽度不足时把 trailing 面板移到标题下方或直接隐藏。
@immutable
class UniDetailHeaderLayout {
  const UniDetailHeaderLayout({
    required this.contentWidth,
    required this.infoWidth,
    required this.trailingWidth,
    required this.trailingPlacement,
  });

  /// 标题区在 trailing 面板之外可用的最小宽度。
  static const double minInfoWidth = 240.0;

  /// 右侧 trailing 面板的最小宽度。
  static const double minTrailingWidth = 200.0;

  /// 右侧 trailing 面板的最大宽度。
  static const double maxTrailingWidth = 300.0;

  /// 标题区与右侧 trailing 面板之间的间距。
  static const double trailingGap = 12.0;

  /// 面板移到标题下方时的最大宽度。
  static const double stackedMaxTrailingWidth = 460.0;

  /// 面板移到标题下方时的最大高度，避免把正文挤出视口。
  static const double stackedMaxTrailingHeight = 132.0;

  /// 面板移到标题下方所需的最小头部宽度。
  static const double stackedMinWidth = 620.0;

  /// 去掉左右内边距后的头部宽度。
  final double contentWidth;

  /// 标题区最终宽度。
  final double infoWidth;

  /// trailing 面板最终宽度；不显示时为 0。
  final double trailingWidth;

  final DetailHeaderTrailingPlacement trailingPlacement;

  bool get showSideTrailing =>
      trailingPlacement == DetailHeaderTrailingPlacement.side;

  bool get showStackedTrailing =>
      trailingPlacement == DetailHeaderTrailingPlacement.stacked;

  bool get showTrailing =>
      trailingPlacement != DetailHeaderTrailingPlacement.none;

  /// 按实际宽度计算布局。
  ///
  /// [trailingSideMinWidth] 用于限制右侧摆放的最小头部宽度，供二级页面按
  /// 自身需要收紧策略；不满足时面板移到标题下方。
  factory UniDetailHeaderLayout.resolve({
    required double maxWidth,
    required double horizontalInset,
    required double coverSize,
    required double gap,
    required bool hasTrailing,
    double trailingSideMinWidth = 0,
  }) {
    final contentWidth = math.max(0.0, maxWidth - horizontalInset * 2);
    final infoAreaWidth = math.max(0.0, contentWidth - coverSize - gap);
    if (!hasTrailing) {
      return UniDetailHeaderLayout(
        contentWidth: contentWidth,
        infoWidth: infoAreaWidth,
        trailingWidth: 0,
        trailingPlacement: DetailHeaderTrailingPlacement.none,
      );
    }
    final desiredTrailingWidth = math.min(
      maxTrailingWidth,
      math.max(minTrailingWidth, infoAreaWidth * 0.26),
    );
    final sideFits =
        infoAreaWidth >= minInfoWidth + trailingGap + minTrailingWidth &&
        maxWidth >= trailingSideMinWidth;
    if (sideFits) {
      final trailingWidth = math.min(
        desiredTrailingWidth,
        infoAreaWidth - minInfoWidth - trailingGap,
      );
      return UniDetailHeaderLayout(
        contentWidth: contentWidth,
        infoWidth: infoAreaWidth - trailingGap - trailingWidth,
        trailingWidth: trailingWidth,
        trailingPlacement: DetailHeaderTrailingPlacement.side,
      );
    }
    if (infoAreaWidth >= minInfoWidth && maxWidth >= stackedMinWidth) {
      return UniDetailHeaderLayout(
        contentWidth: contentWidth,
        infoWidth: infoAreaWidth,
        trailingWidth: math.min(stackedMaxTrailingWidth, infoAreaWidth),
        trailingPlacement: DetailHeaderTrailingPlacement.stacked,
      );
    }
    return UniDetailHeaderLayout(
      contentWidth: contentWidth,
      infoWidth: infoAreaWidth,
      trailingWidth: 0,
      trailingPlacement: DetailHeaderTrailingPlacement.none,
    );
  }
}
