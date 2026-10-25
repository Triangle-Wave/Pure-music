import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/uni_detail_header_layout.dart';
import 'package:pure_music/page/uni_detail_page.dart';

Widget _headerHarness({required Widget child}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 977, child: child),
      ),
    ),
  );
}

void main() {
  group('UniDetailHeaderLayout', () {
    test('977 宽内容区在 artist 阈值下把面板移到标题下方', () {
      final layout = UniDetailHeaderLayout.resolve(
        maxWidth: 977,
        horizontalInset: 16,
        coverSize: 200,
        gap: 16,
        hasTrailing: true,
        trailingSideMinWidth: 1100,
      );

      expect(layout.trailingPlacement, DetailHeaderTrailingPlacement.stacked);
      expect(
        layout.infoWidth,
        greaterThanOrEqualTo(UniDetailHeaderLayout.minInfoWidth),
      );
    });

    test('977 宽内容区在通用阈值下标题区仍保留可读宽度', () {
      final layout = UniDetailHeaderLayout.resolve(
        maxWidth: 977,
        horizontalInset: 16,
        coverSize: 200,
        gap: 16,
        hasTrailing: true,
      );

      expect(layout.showSideTrailing, isTrue);
      expect(
        layout.infoWidth,
        greaterThanOrEqualTo(UniDetailHeaderLayout.minInfoWidth),
      );
      expect(layout.infoWidth, greaterThan(300));
    });

    test('极窄宽度隐藏面板而不是继续压缩标题区', () {
      final layout = UniDetailHeaderLayout.resolve(
        maxWidth: 420,
        horizontalInset: 12,
        coverSize: 156,
        gap: 12,
        hasTrailing: true,
      );

      expect(layout.showTrailing, isFalse);
      expect(layout.infoWidth, lessThan(UniDetailHeaderLayout.minInfoWidth));
    });
  });

  testWidgets('977 宽 artist 头部完整显示标题且播放按钮在封面右侧', (tester) async {
    tester.view.physicalSize = const Size(1280, 756);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _headerHarness(
        child: UniDetailPageHeader(
          pic: Future<ImageProvider?>.value(null),
          picShape: PicShape.oval,
          title: '李荣浩',
          subtitle: '1 首作品',
          actions: const [
            SizedBox(
              key: ValueKey('play-action'),
              width: 96,
              height: 40,
            ),
          ],
          trailingSideMinWidth: 1100,
          headerTrailing: const SizedBox(
            key: ValueKey('online-panel'),
            width: 200,
            height: 72,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final titleFinder = find.text('李荣浩');
    final title = tester.renderObject<RenderParagraph>(titleFinder);
    // 标题没有触发截断，说明三字标题宽度完整。
    expect(title.didExceedMaxLines, isFalse);
    expect(title.size.width, greaterThan(64.0));

    final coverRect = tester.getRect(
      find.byKey(const ValueKey('detail-header-cover')),
    );
    final actionRect = tester.getRect(
      find.byKey(const ValueKey('play-action')),
    );
    expect(actionRect.left, greaterThan(coverRect.right));
    expect(actionRect.top, lessThan(coverRect.bottom));
    expect(actionRect.width, 96);

    final panelRect = tester.getRect(
      find.byKey(const ValueKey('online-panel')),
    );
    expect(
      panelRect.top,
      greaterThanOrEqualTo(tester.getRect(titleFinder).bottom),
    );
    expect(
      panelRect.width,
      lessThanOrEqualTo(UniDetailHeaderLayout.stackedMaxTrailingWidth),
    );
  });
}
