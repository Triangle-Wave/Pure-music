import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/core/paths.dart' as app_paths;

/// 从详情页跳转到另一详情页时替换当前页，避免返回栈层层叠加。
///
/// 从列表页、播放页等非详情页进入详情页仍走 push，返回时回到进入前的位置。
void pushDetailPage<T>(BuildContext context, String route, {T? extra}) {
  final state = GoRouterState.of(context);
  final onDetailPage =
      _detailLocations.contains(state.matchedLocation) ||
      _detailLocations.contains(state.uri.path);
  if (onDetailPage) {
    context.pushReplacement(route, extra: extra);
  } else {
    context.push(route, extra: extra);
  }
}

const Set<String> _detailLocations = {
  app_paths.ARTIST_DETAIL_PAGE,
  app_paths.ALBUM_DETAIL_PAGE,
  app_paths.AUDIO_DETAIL_PAGE,
  app_paths.STATS_ARTIST_DETAIL_PAGE,
  app_paths.STATS_ALBUM_DETAIL_PAGE,
};
