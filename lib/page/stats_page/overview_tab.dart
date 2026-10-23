import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/stacked_list_view.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/native/rust/api/library_db.dart' as rust_library_db;
import 'package:pure_music/page/stats_page/charts.dart';
import 'package:pure_music/page/stats_page/stats_shared.dart';

/// 概览 tab：指标、听歌趋势、收听节律。榜单在另外三个栏目。
class OverviewTab extends StatelessWidget {
  const OverviewTab({
    super.key,
    required this.totalPlays,
    required this.playedTracks,
    required this.totalTracks,
    required this.artistCount,
    required this.albumCount,
    required this.estimatedListen,
    required this.history,
    required this.hasAnyHistory,
    required this.period,
  });

  final int totalPlays;
  final int playedTracks;
  final int totalTracks;
  final int artistCount;
  final int albumCount;
  final int estimatedListen;
  final rust_library_db.PlayHistoryStats? history;
  final bool hasAnyHistory;
  final StatsPeriod period;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final history = this.history;
    final hasHistory = history != null && history.total > 0;
    return SmoothScrollListView(
      padding: const EdgeInsets.only(bottom: Spacing.bottomNav + Spacing.sm),
      children: [
        statsBlock(
          statsCard(
            context,
            child: buildMetricGrid(
              context,
              tiles: (width) => [
                buildMetricTile(
                  context,
                  width: width,
                  icon: Symbols.play_arrow,
                  color: scheme.primary,
                  label: '累计播放',
                  value: formatCount(totalPlays),
                ),
                buildMetricTile(
                  context,
                  width: width,
                  icon: Symbols.library_music,
                  color: scheme.tertiary,
                  label: '听过的曲目',
                  value: '$playedTracks / $totalTracks',
                ),
                buildMetricTile(
                  context,
                  width: width,
                  icon: Symbols.album,
                  color: scheme.secondary,
                  label: '艺术家 / 专辑',
                  value: '$artistCount / $albumCount',
                ),
                buildMetricTile(
                  context,
                  width: width,
                  icon: Symbols.schedule,
                  color: scheme.onSurfaceVariant,
                  label: '预估收听',
                  value: formatDuration(estimatedListen),
                ),
              ],
            ),
          ),
          top: Spacing.sm,
        ),
        statsBlock(
          statsSplitRow(
            context,
            minWidth: 820,
            leading: _trendCard(context, history, hasHistory, hasAnyHistory),
            trailing: _rhythmCard(context, history, hasHistory, hasAnyHistory),
          ),
        ),
      ],
    );
  }

  Widget _trendCard(
    BuildContext context,
    rust_library_db.PlayHistoryStats? history,
    bool hasHistory,
    bool hasAnyHistory,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final points = history == null
        ? const <TrendPoint>[]
        : buildPeriodTrend(period, history);
    return statsCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '听歌趋势',
            style: TextStyle(
              fontSize: AppType.sectionTitle,
              fontWeight: AppType.weightSemibold,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: Spacing.md),
          if (!hasHistory || history == null || points.isEmpty)
            statsMessage(
              context,
              icon: Symbols.show_chart,
              text: hasAnyHistory ? '所选时间段内没有播放记录' : '播放几首歌曲后，这里会出现趋势',
              height: BarSeriesChart.totalHeightOf(
                context,
                BarSeriesChart.defaultHeight,
              ),
            )
          else
            BarSeriesChart(
              values: [for (final point in points) point.value],
              labels: [for (final point in points) point.label],
              tooltips: [for (final point in points) point.fullLabel],
            ),
        ],
      ),
    );
  }

  Widget _rhythmCard(
    BuildContext context,
    rust_library_db.PlayHistoryStats? history,
    bool hasHistory,
    bool hasAnyHistory,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final hourly = history == null ? const <int>[] : toIntList(history.hourly);
    final peakHour = hourly.isEmpty ? null : peakHourOf(hourly);
    return statsCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '收听节律',
                style: TextStyle(
                  fontSize: AppType.sectionTitle,
                  fontWeight: AppType.weightSemibold,
                  color: scheme.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                peakHour == null
                    ? '按小时统计'
                    : '高峰 ${peakHour.toString().padLeft(2, '0')}:00',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          if (!hasHistory || history == null)
            statsMessage(
              context,
              icon: Symbols.schedule,
              text: hasAnyHistory ? '所选时间段内没有播放记录' : '播放几首歌曲后，这里会出现节律分布',
              height: BarSeriesChart.totalHeightOf(
                context,
                RhythmChart.defaultHeight,
              ),
            )
          else
            RhythmChart(hourly: hourly),
        ],
      ),
    );
  }
}
