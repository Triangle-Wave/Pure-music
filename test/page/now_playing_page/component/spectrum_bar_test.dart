import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/component/spectrum_bar.dart';

void main() {
  test('clearing a paused spectrum frame returns it to baseline', () {
    final values = Float32List.fromList([0.8, 0.4, 0.2]);

    clearSpectrumFrameForTesting(values);

    expect(values, orderedEquals([0.0, 0.0, 0.0]));
  });
}
