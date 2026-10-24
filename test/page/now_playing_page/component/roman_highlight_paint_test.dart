import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_painter_params.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';

SyncLyricLine _line({List<SyncLyricWord>? romanWords}) {
  return SyncLyricLine(
    Duration.zero,
    const Duration(seconds: 2),
    [
      SyncLyricWord(
        Duration.zero,
        const Duration(seconds: 1),
        '君',
      ),
      SyncLyricWord(
        const Duration(seconds: 1),
        const Duration(seconds: 1),
        'の',
      ),
    ],
    null,
    'kimi no',
    romanWords,
  );
}

LyricsLinePainter _painter(SyncLyricLine line, {double timeMs = 500}) {
  return LyricsLinePainter(
    params: LyricPainterParams(
      line: line,
      currentTimeMs: timeMs,
      blurSigma: 0,
      config: const LyricRenderConfig(
        textAlign: LyricTextAlign.left,
        baseFontSize: 32,
        translationBaseFontSize: 20,
        showTranslation: false,
        showRoman: true,
        fontWeight: 600,
        enableBlur: false,
        liftStyle: LyricLiftStyle.vertical,
        liftPeak: 2,
      ),
      isMainLine: true,
      isHighlightActive: true,
      isMainVocalActive: true,
      accelerateTailHighlight: false,
      useMaterialYouColor: false,
      opacity: 1,
      lineMedianWordDuration: Duration.zero,
    ),
    scheme: const ColorScheme.dark(),
  );
}

void main() {
  test('romanWords 为空时整行单色绘制不抛异常', () {
    final painter = _painter(_line());
    expect(
      () => painter.paint(Canvas(PictureRecorder()), const Size(400, 160)),
      returnsNormally,
    );
  });

  test('romanWords 存在时逐字绘制不抛异常', () {
    final painter = _painter(
      _line(
        romanWords: [
          SyncLyricWord(
            Duration.zero,
            const Duration(seconds: 1),
            'kimi',
          ),
          SyncLyricWord(
            const Duration(seconds: 1),
            const Duration(seconds: 1),
            'no',
          ),
        ],
      ),
    );
    expect(
      () => painter.paint(Canvas(PictureRecorder()), const Size(400, 160)),
      returnsNormally,
    );
  });
}
