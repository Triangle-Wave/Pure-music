import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/core/detail_navigation.dart';

RouteMatch _routeMatch(String path, String matchedLocation) {
  return RouteMatch(
    route: GoRoute(path: path, builder: (_, __) => const SizedBox.shrink()),
    matchedLocation: matchedLocation,
    pageKey: ValueKey<String>(matchedLocation),
  );
}

void main() {
  group('shouldReplaceDetailPage', () {
    test('取不到 router 时按非详情页返回 false', () {
      expect(
        shouldReplaceDetailPage(
          hasRouter: false,
          matchedLocation: null,
          uriPath: null,
        ),
        isFalse,
      );
    });

    test('matchedLocation 命中详情页时返回 true', () {
      expect(
        shouldReplaceDetailPage(
          hasRouter: true,
          matchedLocation: '/artists/detail',
          uriPath: null,
        ),
        isTrue,
      );
    });

    test('uriPath 命中详情页时返回 true', () {
      expect(
        shouldReplaceDetailPage(
          hasRouter: true,
          matchedLocation: null,
          uriPath: '/albums/detail',
        ),
        isTrue,
      );
    });

    test('普通列表页返回 false', () {
      expect(
        shouldReplaceDetailPage(
          hasRouter: true,
          matchedLocation: '/audios',
          uriPath: '/audios',
        ),
        isFalse,
      );
    });

    test('统计详情页命中时返回 true', () {
      expect(
        shouldReplaceDetailPage(
          hasRouter: true,
          matchedLocation: '/stats/artist',
          uriPath: '/stats/artist',
        ),
        isTrue,
      );
    });

    test('详情页集合外的路径返回 false', () {
      expect(
        shouldReplaceDetailPage(
          hasRouter: true,
          matchedLocation: '/playlists/detail',
          uriPath: '/playlists/detail',
        ),
        isFalse,
      );
    });
  });

  group('currentMatchedLocation', () {
    test('正常匹配列表取栈顶 matchedLocation', () {
      final list = RouteMatchList(
        matches: [
          _routeMatch('/artists', '/artists'),
          _routeMatch('detail', '/artists/detail'),
        ],
        uri: Uri.parse('/artists/detail'),
        pathParameters: const <String, String>{},
      );

      expect(currentMatchedLocation(list), '/artists/detail');
    });

    test('空配置返回 null 且不抛异常', () {
      expect(currentMatchedLocation(RouteMatchList.empty), isNull);
      expect(
        () => currentMatchedLocation(RouteMatchList.empty),
        returnsNormally,
      );
    });

    test('imperative 跳转后仍取到详情页位置', () {
      final base = RouteMatchList(
        matches: [_routeMatch('/artists', '/artists')],
        uri: Uri.parse('/artists'),
        pathParameters: const <String, String>{},
      );
      final detailMatches = RouteMatchList(
        matches: [_routeMatch('detail', '/artists/detail')],
        uri: Uri.parse('/artists/detail'),
        pathParameters: const <String, String>{},
      );
      final imperative = ImperativeRouteMatch(
        pageKey: const ValueKey<String>('detail'),
        matches: detailMatches,
        completer: Completer<Object?>(),
      );
      final pushed = base.push(imperative);

      expect(pushed.uri.path, '/artists');
      expect(currentMatchedLocation(pushed), '/artists/detail');
    });
  });
}
