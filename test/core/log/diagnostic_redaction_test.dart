import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/log/diagnostic_redaction.dart';

void main() {
  test('redacts windows paths with slash or backslash', () {
    expect(
      redactDiagnosticData(r'open C:\Users\a\song.flac'),
      'open [local path]',
    );
    expect(
      redactDiagnosticData('open C:/Users/a/song.flac'),
      'open [local path]',
    );
  });

  test('redacts last.fm style secrets', () {
    expect(
      redactDiagnosticData('apiKey=abc sharedSecret=xyz sessionKey=sk'),
      'apiKey=[redacted] sharedSecret=[redacted] sessionKey=[redacted]',
    );
  });

  test('redacts windows paths before structured log fields', () {
    expect(
      redactDiagnosticData(r'path=C:\a b\c.tak flags=0x20000 error=6'),
      'path=[local path] flags=0x20000 error=6',
    );
  });

  test('redacts standalone windows paths containing spaces', () {
    expect(
      redactDiagnosticData(r'G:\My Music\a b.tak'),
      '[local path]',
    );
  });

  test('keeps parenthesized error suffix after a windows path', () {
    expect(
      redactDiagnosticData(r'path=C:\x\y.flac (error 5)'),
      'path=[local path] (error 5)',
    );
  });

  test('keeps spaces, tilde and full-width characters inside a path', () {
    expect(
      redactDiagnosticData(
        r'open G:\My Music\Memories Off 6 ~T-wave~ (Audio Collection) 音频\a.tak flags=0x1',
      ),
      'open [local path] flags=0x1',
    );
  });

  test('redacts unix paths before structured log fields', () {
    expect(
      redactDiagnosticData('/Users/a/Music/a b.flac flags=0x20000 error=2'),
      '[local path] flags=0x20000 error=2',
    );
  });
}
