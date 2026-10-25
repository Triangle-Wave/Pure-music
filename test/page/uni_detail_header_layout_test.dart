import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/album_detail_page.dart';
import 'package:pure_music/page/uni_detail_header_layout.dart';
import 'package:pure_music/page/uni_detail_page.dart';
import 'package:pure_music/services/online_album/online_album_models.dart';

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

  testWidgets('977 宽专辑头部把在线专辑面板放到标题下方且正文仍有空间', (tester) async {
    tester.view.physicalSize = const Size(977, 756);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const albumTitle = 'AQUAPLUS VOCAL COLLECTION';
    const summary = '收录多首游戏与动画主题曲的精选专辑，在线信息摘要用于验证面板不会把头部高度撑开。';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 977,
            height: 756,
            child: Column(
              children: [
                UniDetailPageHeader(
                  pic: Future<ImageProvider?>.value(null),
                  picShape: PicShape.rrect,
                  title: albumTitle,
                  subtitle: '14 首作品',
                  actions: const [
                    SizedBox(
                      key: ValueKey('play-action'),
                      width: 96,
                      height: 40,
                    ),
                  ],
                  trailingSideMinWidth: 1100,
                  headerTrailing: const OnlineAlbumPanel(
                    info: OnlineAlbumInfo(
                      releaseGroupId: 'release-group',
                      title: albumTitle,
                      year: 2013,
                      label: 'F.I.X. RECORDS',
                      genre: 'Soundtrack',
                      summary: summary,
                      trackCount: 14,
                      source: 'MusicBrainz',
                    ),
                    loading: false,
                  ),
                ),
                const Expanded(
                  child: SizedBox(key: ValueKey('detail-body')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);

    final titleFinder = find.text(albumTitle);
    final title = tester.renderObject<RenderParagraph>(titleFinder);
    expect(title.didExceedMaxLines, isFalse);

    final panelRect = tester.getRect(find.byType(OnlineAlbumPanel));
    expect(
      panelRect.top,
      greaterThanOrEqualTo(tester.getRect(titleFinder).bottom),
    );
    expect(
      panelRect.width,
      lessThanOrEqualTo(UniDetailHeaderLayout.stackedMaxTrailingWidth),
    );
    expect(
      panelRect.height,
      lessThanOrEqualTo(UniDetailHeaderLayout.stackedMaxTrailingHeight),
    );

    // 头部只占一小部分高度，tab 栏与曲目列表所在的正文区仍然可见。
    final bodyRect = tester.getRect(find.byKey(const ValueKey('detail-body')));
    expect(bodyRect.height, greaterThan(300));
  });

  testWidgets('1280 宽专辑头部把在线面板放在标题右侧且正文仍有空间', (tester) async {
    tester.view.physicalSize = const Size(1280, 756);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const albumTitle = 'AQUAPLUS VOCAL COLLECTION';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1280,
            height: 756,
            child: Column(
              children: [
                UniDetailPageHeader(
                  pic: Future<ImageProvider?>.value(null),
                  picShape: PicShape.rrect,
                  title: albumTitle,
                  subtitle: '14 首作品',
                  actions: const [
                    SizedBox(width: 96, height: 40),
                  ],
                  trailingSideMinWidth: 1100,
                  headerTrailing: const SizedBox(
                    key: ValueKey('online-panel'),
                    width: 200,
                    height: 72,
                  ),
                ),
                const Expanded(
                  child: SizedBox(key: ValueKey('detail-body')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);

    final titleFinder = find.text(albumTitle);
    final titleRect = tester.getRect(titleFinder);
    // 标题区没有被右侧面板吞掉宽度。
    expect(titleRect.width, greaterThan(300));

    final panelRect = tester.getRect(find.byKey(const ValueKey('online-panel')));
    expect(panelRect.left, greaterThan(titleRect.right));
    expect(
      tester.getRect(find.byKey(const ValueKey('detail-body'))).height,
      greaterThan(300),
    );
  });

  testWidgets('200 宽侧栏内在线专辑面板保持限高且不溢出', (tester) async {

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: OnlineAlbumPanel(
                info: OnlineAlbumInfo(
                  releaseGroupId: 'release-group',
                  title: 'AQUAPLUS VOCAL COLLECTION',
                  year: 2013,
                  label: 'F.I.X. RECORDS',
                  genre: 'Soundtrack',
                  summary:
                      '收录多首游戏与动画主题曲的精选专辑，在线信息摘要用于验证面板不会把头部高度撑开。',
                  trackCount: 14,
                  source: 'MusicBrainz',
                ),
                loading: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byType(OnlineAlbumPanel)).height,
      lessThanOrEqualTo(UniDetailHeaderLayout.stackedMaxTrailingHeight),
    );
  });
}
