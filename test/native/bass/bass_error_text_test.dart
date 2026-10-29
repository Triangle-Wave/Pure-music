import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/bass/bass_error_text.dart';

void main() {
  test('maps common BASS stream errors to readable text', () {
    expect(bassErrorText(1), 'memory');
    expect(bassErrorText(2), 'file open');
    expect(bassErrorText(3), 'driver');
    expect(bassErrorText(6), 'format');
    expect(bassErrorText(27), 'not file');
    expect(bassErrorText(41), 'file format');
    expect(bassErrorText(44), 'codec');
  });

  test('returns unknown for unlisted error codes', () {
    expect(bassErrorText(-1), 'unknown');
    expect(bassErrorText(9999), 'unknown');
  });
}
