import 'package:flutter/material.dart';

enum ScreenType {
  /// width <= 640
  small,

  /// 640 < width < 1100
  medium,

  /// width >= 1100
  large,
}

class ResponsiveBuilder extends StatelessWidget {
  const ResponsiveBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, ScreenType screenType) builder;

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);

    if (screenSize.width <= 640) {
      return builder(context, ScreenType.small);
    } else if (screenSize.width > 640 && screenSize.width < 1100) {
      return builder(context, ScreenType.medium);
    } else {
      return builder(context, ScreenType.large);
    }
  }
}

class ResponsiveBuilder2 extends StatelessWidget {
  const ResponsiveBuilder2({
    super.key,
    required this.builder,
    this.largeMinWidth = 928.0,
  });

  final Widget Function(BuildContext context, ScreenType screenType) builder;

  /// 宽度超过该值时使用 [ScreenType.large]。
  final double largeMinWidth;

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);

    if (screenSize.width <= largeMinWidth) {
      return builder(context, ScreenType.small);
    } else {
      return builder(context, ScreenType.large);
    }
  }
}
