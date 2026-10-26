import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/karaok_parser.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_loader.dart';

void main() {
  group('embedded lyric format detection', () {
    test('detects VTT with or without a BOM', () {
      expect(isVttLyricText('WEBVTT\n'), isTrue);
      expect(isVttLyricText('\uFEFFWEBVTT\n'), isTrue);
    });

    test('does not classify other lyric formats as VTT', () {
      expect(isVttLyricText('[00:00.000] LRC'), isFalse);
      expect(isVttLyricText('<tt></tt>'), isFalse);
    });
  });

  group('selected lyric file loading', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pure_music_lyric_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('loads the selected supported file directly', () async {
      final selected = File(
        '${tempDir.path}${Platform.pathSeparator}other.lrc',
      );
      await selected.writeAsString('[00:01.00]Selected lyric');

      final lyric = await loadLyricFromFile(selected.path);

      expect(lyric, isNotNull);
      expect(lyric!.lines, isNotEmpty);
    });

    test('does not fall back when the selected file is missing', () async {
      final lyric = await loadLyricFromFile(
        '${tempDir.path}${Platform.pathSeparator}missing.lrc',
      );

      expect(lyric, isNull);
    });

    test('rejects unsupported file extensions', () async {
      final selected = File(
        '${tempDir.path}${Platform.pathSeparator}lyric.txt',
      );
      await selected.writeAsString('[00:01.00]Selected lyric');

      final lyric = await loadLyricFromFile(selected.path);

      expect(lyric, isNull);
    });
  });

  test('loads translation embedded in a local KRC file', () {
    final language = base64Encode(
      utf8.encode(
        jsonEncode({
          'content': [
            {
              'type': 1,
              'lyricContent': [
                ['第一译'],
                ['第二译'],
              ],
            },
          ],
        }),
      ),
    );
    final lyric = parseExternalLyricText(
      '[language:$language]\n'
          '[0,1000]<0,1000,0>第一行\n'
          '[1000,1000]<0,1000,0>第二行',
      '.krc',
    );

    expect(lyric, isNotNull);
    expect(lyric!.lines[0].translation, '第一译');
    expect(lyric.lines[1].translation, '第二译');
  });

  test('matches every LRC timestamp on a translation line', () {
    final lyric = parseKaraokToPureLyric(
      '.krc',
      '[1000,1000]<0,1000,0>第一行\n'
          '[2000,1000]<0,1000,0>第二行',
      transContent: '[00:01.00][00:02.00]重复译',
    );

    expect(lyric, isNotNull);
    expect(lyric!.lines[0].translation, '重复译');
    expect(lyric.lines[1].translation, '重复译');
  });

  test('accepts LRC timestamps without a fractional part', () {
    final lyric = parseKaraokToPureLyric(
      '.krc',
      '[1000,1000]<0,1000,0>第一行',
      transContent: '[00:01]译文',
    );

    expect(lyric, isNotNull);
    expect(lyric!.lines.single.translation, '译文');
  });

  test('restores romanization embedded in a local KRC file', () {
    final language = base64Encode(
      utf8.encode(
        jsonEncode({
          'content': [
            {
              'type': 0,
              'lyricContent': [
                ['ki', 'mi'],
              ],
            },
            {
              'type': 1,
              'lyricContent': [
                ['你的'],
              ],
            },
          ],
        }),
      ),
    );
    final lyric = parseExternalLyricText(
      '[language:$language]\n'
          '[1000,1000]<0,500,0>君<500,500,0>の',
      '.krc',
    );

    expect(lyric, isNotNull);
    final line = lyric!.lines.single as SyncLyricLine;
    expect(line.romanLyric, 'ki mi');
    expect(line.romanWords, hasLength(2));
    expect(line.translation, '你的');
  });

  test('restores romanization when language entries have no type', () {
    final language = base64Encode(
      utf8.encode(
        jsonEncode({
          'content': [
            {
              'lyricContent': [
                ['ki', 'mi'],
              ],
            },
            {
              'lyricContent': [
                ['你的'],
              ],
            },
          ],
        }),
      ),
    );
    final lyric = parseExternalLyricText(
      '[language:$language]\n'
          '[1000,1000]<0,500,0>君<500,500,0>の',
      '.krc',
    );

    expect(lyric, isNotNull);
    final line = lyric!.lines.single as SyncLyricLine;
    expect(line.romanLyric, 'ki mi');
    expect(line.romanWords, hasLength(2));
    expect(line.translation, '你的');
  });
}
