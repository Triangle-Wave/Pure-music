import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/paths.dart' as app_paths;

/// 从详情页跳转到另一详情页时替换当前页，避免返回栈层层叠加。
///
/// 从列表页、播放页等非详情页进入详情页仍走 push，返回时回到进入前的位置。
///
/// 当前位置从 [GoRouter.state] 读取，该状态由路由委托的匹配列表生成，
/// 在对话框等非页面子树中同样可用。
void pushDetailPage<T>(BuildContext context, String route, {T? extra}) {
  var hasRouter = false;
  String? matchedLocation;
  String? uriPath;
  try {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      hasRouter = true;
      final state = router.state;
      matchedLocation = state.matchedLocation;
      uriPath = state.uri.path;
    }
  } catch (error, trace) {
    log.app.warn(
      'detail_navigation_location_failed',
      '读取当前路由位置失败，按非详情页使用 push 跳转',
      fields: {'route': route, 'error': error.runtimeType.toString()},
      error: error,
      stackTrace: trace,
    );
    hasRouter = false;
    matchedLocation = null;
    uriPath = null;
  }
  if (shouldReplaceDetailPage(
    hasRouter: hasRouter,
    matchedLocation: matchedLocation,
    uriPath: uriPath,
  )) {
    context.pushReplacement(route, extra: extra);
  } else {
    context.push(route, extra: extra);
  }
}

/// 是否位于集合详情页，供跳转决策与对话框避让共用。
bool isDetailLocation(String? location) =>
    location != null && _detailLocations.contains(location);

/// 从路由匹配列表读取当前实际位置。
///
/// [RouteMatchList.uri] 不反映 imperative 跳转，取栈顶匹配的 matchedLocation
/// 才能反映 push 后的真实位置；空匹配列表返回 null。
String? currentMatchedLocation(RouteMatchList configuration) =>
    configuration.lastOrNull?.matchedLocation;

/// 由当前路由位置判断详情页跳转应采用替换还是入栈。
///
/// 取不到 router 或 state 读取异常时，[pushDetailPage] 降级为 push，
/// 保证跳转不被位置判断阻断。
bool shouldReplaceDetailPage({
  required bool hasRouter,
  required String? matchedLocation,
  required String? uriPath,
}) {
  if (!hasRouter) return false;
  return _detailLocations.contains(matchedLocation) ||
      _detailLocations.contains(uriPath);
}

const Set<String> _detailLocations = {
  app_paths.ARTIST_DETAIL_PAGE,
  app_paths.ALBUM_DETAIL_PAGE,
  app_paths.AUDIO_DETAIL_PAGE,
  app_paths.STATS_ARTIST_DETAIL_PAGE,
  app_paths.STATS_ALBUM_DETAIL_PAGE,
};
