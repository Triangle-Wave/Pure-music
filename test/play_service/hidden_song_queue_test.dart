import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/playback_service.dart';

Audio _audio(String path) =>
    Audio(path, '', '', null, 0, 1, null, null, path, 0, 0, null);

void main() {
  test('removing the current hidden song selects the following queue item', () {
    final current = _audio('current.mp3');
    final next = _audio('next.mp3');
    final result = PlaybackService.filterHiddenQueue(
      playlist: [current, next],
      backup: [current, next],
      currentIndex: 0,
      hiddenPaths: {current.path},
    );

    expect(result.currentRemoved, isTrue);
    expect(result.playlist.map((audio) => audio.path), ['next.mp3']);
    expect(result.backup.map((audio) => audio.path), ['next.mp3']);
    expect(result.currentIndex, 0);
  });

  test('removing the only current hidden song clears the queue index', () {
    final current = _audio('current.mp3');
    final result = PlaybackService.filterHiddenQueue(
      playlist: [current],
      backup: [current],
      currentIndex: 0,
      hiddenPaths: {current.path},
    );

    expect(result.currentRemoved, isTrue);
    expect(result.playlist, isEmpty);
    expect(result.backup, isEmpty);
    expect(result.currentIndex, isNull);
  });
}
