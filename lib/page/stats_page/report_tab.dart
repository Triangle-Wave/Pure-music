import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/stacked_list_view.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/page/stats_page/charts.dart';
import 'package:pure_music/page/stats_page/stats_shared.dart';
import 'package:pure_music/services/native/playback_stats_service.dart';

/// 报告 tab：收听洞察卡 + 星期热力图 + 每周分布。
class ReportTab extends StatelessWidget {
  const ReportTab({
    super.key,
    required this.history,
    required this.hasAnyHistory,
    required this.period,
  });

  final PlayHistoryStats? history;
  final bool hasAnyHistory;
  final StatsPeriod period;

  @override
  Widget build(BuildContext context) {
    final history = this.history;
    if (history == null || history.total == 0) {
      return SmoothScrollListView(
        padding: const EdgeInsets.only(bottom: Spacing.bottomNav + Spacing.sm),
        children: [
          statsMessage(
            context,
            icon: Symbols.insights,
            text: hasAnyHistory ? '所选时间段内没有播放记录' : '播放几首歌曲后，这里会出现收听报告',
            height: 280,
          ),
        ],
      );
    }
    final hourly = toIntList(history.hourly);
    final weekdayHourly = toIntList(history.weekdayHourly);
    return SmoothScrollListView(
      padding: const EdgeInsets.only(bottom: Spacing.bottomNav + Spacing.sm),
      children: [
        statsSectionTitle(context, title: '收听报告', subtitle: period.rangeLabel),
        statsBlock(
          statsCard(
            context,
            child: buildMetricGrid(
              context,
              columnsFor: (width) {
                if (period.mode == StatsPeriodMode.day) {
                  return width >= 560 ? 2 : 1;
                }
                return width >= 1000
                    ? 3
                    : width >= 560
                    ? 2
                    : 1;
              },
              tiles: (width) =>
                  _insights(context, history, hourly, weekdayHourly, width),
            ),
          ),
          top: 0,
        ),
        if (period.mode == StatsPeriodMode.day)
          statsBlock(
            statsSplitRow(
              context,
              minWidth: 900,
              leadingFlex: 3,
              trailingFlex: 2,
              leading: _daySegmentsCard(context, hourly),
              trailing: _dayTimelineCard(context, history, hourly),
            ),
            top: Spacing.lg,
          )
        else
          statsBlock(
            statsSplitRow(
              context,
              minWidth: 900,
              leadingFlex: 2,
              trailingFlex: 1,
              leading: _heatmapCard(context, weekdayHourly),
              trailing: _weekdayCard(context, history.total, weekdayHourly),
            ),
            top: Spacing.lg,
          ),
      ],
    );
  }

  List<Widget> _insights(
    BuildContext context,
    PlayHistoryStats history,
    List<int> hourly,
    List<int> weekdayHourly,
    double width,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final daily = history.daily;
    final activeDays = daily.length;
    final average = activeDays > 0 ? history.total ~/ activeDays : 0;
    var peakDay = '';
    var peakDayCount = 0;
    for (final day in daily) {
      if (day.count > peakDayCount) {
        peakDayCount = day.count;
        peakDay = day.day;
      }
    }
    final peakDate = peakDay.isEmpty ? null : DateTime.tryParse(peakDay);
    final lateNight = lateNightPlays(hourly);
    final lateShare = history.total > 0
        ? (lateNight * 100 / history.total).round()
        : 0;
    final peakHour = peakHourOf(hourly);
    final peakHourLabel =
        '${peakHour.toString().padLeft(2, '0')}:00 – '
        '${(peakHour + 1).toString().padLeft(2, '0')}:00';
    if (period.mode == StatsPeriodMode.day) {
      final activeHours = hourly.where((value) => value > 0).length;
      return [
        _insightTile(
          context,
          width: width,
          icon: Symbols.play_circle,
          color: scheme.primary,
          label: '当天播放',
          value: '${formatCount(history.total)} 次',
        ),
        _insightTile(
          context,
          width: width,
          icon: Symbols.schedule,
          color: scheme.secondary,
          label: '高峰时段',
          value: peakHourLabel,
        ),
        _insightTile(
          context,
          width: width,
          icon: Symbols.dark_mode,
          color: scheme.onSurfaceVariant,
          label: '深夜播放（22–6 点）',
          value: '$lateNight 次 · $lateShare%',
        ),
        _insightTile(
          context,
          width: width,
          icon: Symbols.timelapse,
          color: scheme.tertiary,
          label: '活跃小时',
          value: '$activeHours / 24 小时',
        ),
      ];
    }
    final peakWeekday = peakWeekdayOf(weekdayHourly);
    final weekdayTotalsList = weekdayTotals(weekdayHourly);
    return [
      _insightTile(
        context,
        width: width,
        icon: Symbols.calendar_month,
        color: scheme.primary,
        label: '最长连续收听',
        value: '${longestStreakDays(daily)} 天',
      ),
      _insightTile(
        context,
        width: width,
        icon: Symbols.today,
        color: scheme.tertiary,
        label: '最活跃的一天',
        value: peakDate == null
            ? '-'
            : '${peakDate.month}月${peakDate.day}日 · $peakDayCount 次',
      ),
      _insightTile(
        context,
        width: width,
        icon: Symbols.schedule,
        color: scheme.secondary,
        label: '高峰时段',
        value: peakHourLabel,
      ),
      _insightTile(
        context,
        width: width,
        icon: Symbols.dark_mode,
        color: scheme.onSurfaceVariant,
        label: '深夜播放（22–6 点）',
        value: '$lateNight 次 · $lateShare%',
      ),
      _insightTile(
        context,
        width: width,
        icon: Symbols.date_range,
        color: scheme.tertiary,
        label: '最常听的星期',
        value:
            '${weekdayLabel(peakWeekday)} · ${formatCount(weekdayTotalsList[peakWeekday])} 次',
      ),
      _insightTile(
        context,
        width: width,
        icon: Symbols.trending_up,
        color: scheme.primary,
        label: '活跃日均播放',
        value: '$average 次 / 天',
      ),
    ];
  }

  Widget _daySegmentsCard(BuildContext context, List<int> hourly) {
    final scheme = Theme.of(context).colorScheme;
    final total = hourly.fold<int>(0, (sum, value) => sum + value);
    const segments = <(String, int, int)>[
      ('凌晨', 0, 6),
      ('上午', 6, 12),
      ('下午', 12, 18),
      ('晚间', 18, 24),
    ];
    return statsCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Spacing.sm,
            runSpacing: Spacing.xs,
            children: [
              Text(
                '时段构成',
                style: TextStyle(
                  fontSize: AppType.sectionTitle,
                  fontWeight: AppType.weightSemibold,
                  color: scheme.onSurface,
                ),
              ),
              Text(
                '${formatCount(total)} 次',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0) const SizedBox(height: Spacing.md),
            _daySegmentRow(context, segments[i], hourly, total, i),
          ],
        ],
      ),
    );
  }

  Widget _daySegmentRow(
    BuildContext context,
    (String, int, int) segment,
    List<int> hourly,
    int total,
    int index,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final (label, start, end) = segment;
    var count = 0;
    for (var hour = start; hour < end && hour < hourly.length; hour++) {
      count += hourly[hour];
    }
    final percent = total > 0 ? (count * 100 / total).round() : 0;
    final fraction = total > 0 ? count / total : 0.0;
    final color = switch (index) {
      0 => scheme.onSurfaceVariant,
      1 => scheme.primary,
      2 => scheme.secondary,
      _ => scheme.tertiary,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              flex: 2,
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurface,
                ),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              flex: 3,
              child: Text(
                '$count 次 · $percent%',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 6,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: scheme.surfaceContainerHighest),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: fraction,
                  child: ColoredBox(color: color),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _dayTimelineCard(
    BuildContext context,
    PlayHistoryStats history,
    List<int> hourly,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final firstAt = history.firstAt.toInt();
    final lastAt = history.lastAt.toInt();
    final spanSeconds = lastAt > firstAt ? lastAt - firstAt : 0;
    final activeHours = hourly.where((value) => value > 0).length;
    final total = history.total.toInt();
    final average = activeHours > 0
        ? (total / activeHours).toStringAsFixed(1)
        : '-';
    final streak = _longestActiveHours(hourly);
    return statsCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Spacing.sm,
            runSpacing: Spacing.xs,
            children: [
              Text(
                '当天记录',
                style: TextStyle(
                  fontSize: AppType.sectionTitle,
                  fontWeight: AppType.weightSemibold,
                  color: scheme.onSurface,
                ),
              ),
              Text(
                '按播放记录',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          _dayInfoRow(
            context,
            Symbols.play_circle,
            '首次记录',
            _clockLabel(firstAt),
          ),
          const SizedBox(height: Spacing.sm),
          _dayInfoRow(context, Symbols.schedule, '最后记录', _clockLabel(lastAt)),
          const SizedBox(height: Spacing.sm),
          _dayInfoRow(
            context,
            Symbols.timelapse,
            '收听跨度',
            _spanLabel(spanSeconds),
          ),
          const SizedBox(height: Spacing.sm),
          _dayInfoRow(
            context,
            Symbols.trending_up,
            '最长连续活跃',
            streak > 0 ? '$streak 小时' : '-',
          ),
          const SizedBox(height: Spacing.sm),
          _dayInfoRow(
            context,
            Symbols.date_range,
            '活跃小时均播',
            average == '-' ? '-' : '$average 次',
          ),
        ],
      ),
    );
  }

  Widget _dayInfoRow(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: Text(
            label,
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
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: AppType.body,
              fontWeight: AppType.weightSemibold,
              color: scheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }

  String _clockLabel(int epochSeconds) {
    if (epochSeconds <= 0) return '-';
    final time = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _spanLabel(int seconds) {
    if (seconds <= 0) return '不足 1 分钟';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours == 0) return '$minutes 分钟';
    if (minutes == 0) return '$hours 小时';
    return '$hours 小时 $minutes 分';
  }

  int _longestActiveHours(List<int> hourly) {
    var longest = 0;
    var run = 0;
    for (final value in hourly) {
      if (value > 0) {
        run++;
        if (run > longest) longest = run;
      } else {
        run = 0;
      }
    }
    return longest;
  }

  Widget _insightTile(
    BuildContext context, {
    required double width,
    required IconData icon,
    required Color color,
    required String label,
    required String value,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: AppRadius.smCircular,
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: AppRadius.smCircular,
            ),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.subtitle,
                    fontWeight: AppType.weightSemibold,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _heatmapCard(BuildContext context, List<int> weekdayHourly) {
    final scheme = Theme.of(context).colorScheme;
    return statsCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Spacing.sm,
            runSpacing: Spacing.xs,
            children: [
              Text(
                '收听热力',
                style: TextStyle(
                  fontSize: AppType.sectionTitle,
                  fontWeight: AppType.weightSemibold,
                  color: scheme.onSurface,
                ),
              ),
              Text(
                '星期 × 小时',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          WeekHeatmap(weekdayHourly: weekdayHourly),
        ],
      ),
    );
  }

  Widget _weekdayCard(
    BuildContext context,
    int total,
    List<int> weekdayHourly,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return statsCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Spacing.sm,
            runSpacing: Spacing.xs,
            children: [
              Text(
                '星期分布',
                style: TextStyle(
                  fontSize: AppType.sectionTitle,
                  fontWeight: AppType.weightSemibold,
                  color: scheme.onSurface,
                ),
              ),
              Text(
                '${formatCount(total)} 次',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          WeekdayBars(weekdayHourly: weekdayHourly),
        ],
      ),
    );
  }
}
