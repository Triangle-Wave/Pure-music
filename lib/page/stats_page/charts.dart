import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/page/stats_page/stats_shared.dart';

/// 带悬停读数和入场动画的竖直柱状图。
///
/// [labels] 为底部稀疏标签，空串留白；[tooltips] 为悬停说明。
class BarSeriesChart extends StatefulWidget {
  const BarSeriesChart({
    super.key,
    required this.values,
    required this.labels,
    this.tooltips = const [],
    this.height = defaultHeight,
    this.emptyHint = '暂无播放记录',
  });

  static const double defaultHeight = 168;

  static double _captionRowHeightOf(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(AppType.caption) + Spacing.sm;

  static double totalHeightOf(BuildContext context, double plotHeight) =>
      plotHeight + _captionRowHeightOf(context) * 2 + Spacing.xs;

  final List<int> values;
  final List<String> labels;
  final List<String> tooltips;
  final double height;
  final String emptyHint;

  @override
  State<BarSeriesChart> createState() => _BarSeriesChartState();
}

class _BarSeriesChartState extends State<BarSeriesChart> {
  int? _hovered;

  @override
  void didUpdateWidget(BarSeriesChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.values.length != widget.values.length ||
        !listEquals(oldWidget.values, widget.values)) {
      _hovered = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final values = widget.values;
    final total = values.fold<int>(0, (sum, value) => sum + value);
    final maxValue = values.fold<int>(0, math.max);
    final hovered = _hovered != null && _hovered! < values.length
        ? _hovered
        : null;
    final hoveredValue = hovered == null ? 0 : values[hovered];
    final hoveredTip = hovered != null && hovered < widget.tooltips.length
        ? widget.tooltips[hovered]
        : '';
    final captionRowHeight = BarSeriesChart._captionRowHeightOf(context);
    return SizedBox(
      width: double.infinity,
      height: widget.height + captionRowHeight * 2 + Spacing.xs,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: captionRowHeight,
            child: Row(
              children: [
                if (hovered == null)
                  Expanded(
                    child: Text(
                      total == 0 ? widget.emptyHint : '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      hoveredTip,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: Spacing.sm),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      hovered == null
                          ? '总计 ${formatCount(total)} 次'
                          : '${formatCount(hoveredValue)} 次',
                      style: TextStyle(
                        fontSize: AppType.caption,
                        fontWeight: hovered == null
                            ? AppType.weightRegular
                            : AppType.weightSemibold,
                        color: hovered == null
                            ? scheme.onSurfaceVariant
                            : scheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Spacing.xs),
          SizedBox(
            height: widget.height,
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          height: 1,
                          color: scheme.outlineVariant.withValues(alpha: 0.6),
                        ),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < values.length; i++)
                            Expanded(
                              child: MouseRegion(
                                onEnter: (_) => setState(() => _hovered = i),
                                onExit: (_) => setState(() => _hovered = null),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: hovered == i
                                        ? scheme.primary.withValues(alpha: 0.06)
                                        : Colors.transparent,
                                    borderRadius: AppRadius.xsCircular,
                                  ),
                                  padding: EdgeInsets.symmetric(
                                    horizontal: values.length > 20 ? 1 : 2,
                                  ),
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      final barWidth = math.min(
                                        28.0,
                                        constraints.maxWidth * 0.68,
                                      );
                                      final ratio = maxValue <= 0
                                          ? 0.02
                                          : math.max(
                                              values[i] / maxValue,
                                              0.02,
                                            );
                                      final empty = values[i] == 0;
                                      final color = empty
                                          ? scheme.primary.withValues(
                                              alpha: 0.15,
                                            )
                                          : hovered == i
                                          ? scheme.primary
                                          : values[i] == maxValue
                                          ? scheme.primary
                                          : scheme.primary.withValues(
                                              alpha: 0.45,
                                            );
                                      return Align(
                                        alignment: Alignment.bottomCenter,
                                        child: TweenAnimationBuilder<double>(
                                          tween: Tween(
                                            begin: 0,
                                            end: constraints.maxHeight * ratio,
                                          ),
                                          duration: MotionDuration.medium,
                                          curve: MotionCurve.entrance,
                                          builder: (context, barHeight, _) {
                                            return Container(
                                              width: barWidth,
                                              height: barHeight,
                                              decoration: BoxDecoration(
                                                color: color,
                                                borderRadius:
                                                    const BorderRadius.vertical(
                                                      top: Radius.circular(3),
                                                    ),
                                              ),
                                            );
                                          },
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: captionRowHeight,
                  child: Row(
                    children: [
                      for (var i = 0; i < values.length; i++)
                        Expanded(
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                i < widget.labels.length
                                    ? widget.labels[i]
                                    : '',
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: AppType.microlabel,
                                  fontWeight: hovered == i
                                      ? AppType.weightSemibold
                                      : AppType.weightRegular,
                                  color: hovered == i
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 24 小时收听节律柱状图。
class RhythmChart extends StatelessWidget {
  const RhythmChart({
    super.key,
    required this.hourly,
    this.height = defaultHeight,
  });

  static const double defaultHeight = 150;

  final List<int> hourly;
  final double height;

  @override
  Widget build(BuildContext context) {
    final labels = <String>[
      for (var hour = 0; hour < hourly.length; hour++)
        hour % 6 == 0 ? hour.toString().padLeft(2, '0') : '',
    ];
    final tooltips = <String>[
      for (var hour = 0; hour < hourly.length; hour++)
        '${hour.toString().padLeft(2, '0')}:00 – '
            '${((hour + 1) % 24).toString().padLeft(2, '0')}:00',
    ];
    return BarSeriesChart(
      values: List<int>.of(hourly),
      labels: labels,
      tooltips: tooltips,
      height: height,
      emptyHint: '暂无播放记录',
    );
  }
}

enum _HeatmapTextAlign { verticalCenter, horizontalCenter }

/// 星期 × 小时热力图：行=周一…周日，列=0–23 时。
class WeekHeatmap extends StatelessWidget {
  const WeekHeatmap({super.key, required this.weekdayHourly});

  final List<int> weekdayHourly;

  /// 展示顺序（周一在前），索引 0=周日。
  static const _rowWeekdays = [1, 2, 3, 4, 5, 6, 0];
  static const _rowLabels = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const labelColumn = 22.0;
    const topLabels = 18.0;
    const gap = 3.0;
    const cellHeight = 16.0;
    final height = topLabels + _rowWeekdays.length * (cellHeight + gap);
    return SizedBox(
      width: double.infinity,
      height: height,
      child: CustomPaint(
        painter: _HeatmapPainter(
          weekdayHourly: weekdayHourly,
          rowWeekdays: _rowWeekdays,
          rowLabels: _rowLabels,
          labelColumn: labelColumn,
          topLabels: topLabels,
          gap: gap,
          cellHeight: cellHeight,
          cellColor: scheme.primary,
          emptyColor: scheme.surfaceContainerHighest,
          labelColor: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  const _HeatmapPainter({
    required this.weekdayHourly,
    required this.rowWeekdays,
    required this.rowLabels,
    required this.labelColumn,
    required this.topLabels,
    required this.gap,
    required this.cellHeight,
    required this.cellColor,
    required this.emptyColor,
    required this.labelColor,
  });

  final List<int> weekdayHourly;
  final List<int> rowWeekdays;
  final List<String> rowLabels;
  final double labelColumn;
  final double topLabels;
  final double gap;
  final double cellHeight;
  final Color cellColor;
  final Color emptyColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (weekdayHourly.isEmpty) return;
    final cellWidth = (size.width - labelColumn - gap * 23) / 24;
    if (cellWidth <= 0) return;
    var max = 1;
    for (final value in weekdayHourly) {
      if (value > max) max = value;
    }

    for (var row = 0; row < rowWeekdays.length; row++) {
      final weekday = rowWeekdays[row];
      final y = topLabels + row * (cellHeight + gap);
      _paintText(
        canvas,
        rowLabels[row],
        Offset(0, y + cellHeight / 2),
        align: _HeatmapTextAlign.verticalCenter,
      );
      for (var hour = 0; hour < 24; hour++) {
        final index = weekday * 24 + hour;
        final value = index < weekdayHourly.length ? weekdayHourly[index] : 0;
        final rect = Rect.fromLTWH(
          labelColumn + hour * (cellWidth + gap),
          y,
          cellWidth,
          cellHeight,
        );
        final intensity = math.pow(value / max, 0.6).toDouble();
        final paint = Paint()
          ..color = value > 0
              ? cellColor.withValues(alpha: 0.1 + 0.85 * intensity)
              : emptyColor.withValues(alpha: 0.35);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)),
          paint,
        );
      }
    }

    for (final hour in const [0, 6, 12, 18]) {
      final x = labelColumn + hour * (cellWidth + gap);
      _paintText(
        canvas,
        '$hour',
        Offset(x + cellWidth / 2, topLabels / 2),
        align: _HeatmapTextAlign.horizontalCenter,
      );
    }
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset anchor, {
    required _HeatmapTextAlign align,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: AppType.microlabel, color: labelColor),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final offset = switch (align) {
      _HeatmapTextAlign.verticalCenter => Offset(
        0,
        anchor.dy - painter.height / 2,
      ),
      _HeatmapTextAlign.horizontalCenter => Offset(
        anchor.dx - painter.width / 2,
        anchor.dy - painter.height / 2,
      ),
    };
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(_HeatmapPainter oldDelegate) =>
      oldDelegate.weekdayHourly != weekdayHourly ||
      oldDelegate.cellColor != cellColor;
}

/// 每周收听分布（周一到周日横向条）。
class WeekdayBars extends StatelessWidget {
  const WeekdayBars({super.key, required this.weekdayHourly});

  final List<int> weekdayHourly;

  static const _order = [1, 2, 3, 4, 5, 6, 0];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final totals = weekdayTotals(weekdayHourly);
    final max = totals.fold<int>(0, math.max);
    return Column(
      children: [
        for (final weekday in _order)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.sm),
            child: Row(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 40, maxWidth: 64),
                  child: Text(
                    weekdayLabel(weekday),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: ClipRRect(
                    borderRadius: AppRadius.xsCircular,
                    child: LinearProgressIndicator(
                      value: max > 0 ? totals[weekday] / max : 0,
                      minHeight: 8,
                      backgroundColor: scheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        scheme.primary.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 60,
                    maxWidth: 120,
                  ),
                  child: Text(
                    '${formatCount(totals[weekday])} 次',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: AppType.caption,
                      fontWeight: AppType.weightMedium,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
