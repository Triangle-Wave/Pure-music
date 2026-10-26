import 'dart:convert';

import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/lyric/krc_language_content.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/metadata_detector.dart';
import 'package:pure_music/lyric/roman_word_mapper.dart';
import 'package:pure_music/core/settings.dart';
import 'dart:math';

class Krc extends Lyric {
  Krc(super.lines, [super.source = LyricFormat.local, super.rawText]);

  /// 判断是否为元数据行（作曲、作词、编曲、和声、混音等）
  /// 支持中文、英文、日文、韩文等多种语言的元数据标签
  static bool _isMetadataLine(String text) {
    return isLyricMetadataText(text);
  }

  static Krc fromKrcText(String krc, {bool? keepMetadata}) {
    final shouldKeepMetadata =
        keepMetadata ?? AppSettings.instance.keepLyricMetadata;
    final List<KrcLine> lines = [];
    final List<int> sourceLineIndexes = [];
    var karaokeLineCount = 0;
    String? languageFrame;

    final splited = krc.split('\n');

    int? offsetInMilliseconds;
    final offsetPattern = RegExp(r'\[\s*offset\s*:\s*([+-]?\d+)\s*\]');
    for (final line in splited) {
      final matched = offsetPattern.firstMatch(line);
      if (matched == null) continue;
      offsetInMilliseconds = int.tryParse(matched.group(1) ?? '');
      break;
    }
    final offset = offsetInMilliseconds ?? 0;

    for (final item in splited) {
      if (languageFrame == null) {
        final bracketStart = item.indexOf('[');
        final bracketEnd = item.indexOf(']');
        if (bracketStart == -1 ||
            bracketEnd == -1 ||
            bracketEnd <= bracketStart) {
          continue;
        }
        final tag = item.substring(bracketStart + 1, bracketEnd);
        var splitedTag = tag.split(':');
        final tagName = splitedTag.firstOrNull;
        if (tagName?.contains('language') == true && splitedTag.length > 1) {
          languageFrame = splitedTag[1];
        }
      }

      final krcLine = KrcLine.fromLine(item, null, offset);

      if (krcLine == null) continue;

      final sourceLineIndex = karaokeLineCount++;

      // 过滤主歌词中的元数据行（作曲、作词等）
      final lineContent = krcLine.words.map((w) => w.content).join();
      if (lineContent.isNotEmpty &&
          !shouldKeepMetadata &&
          _isMetadataLine(lineContent)) {
        continue;
      }

      lines.add(krcLine);
      sourceLineIndexes.add(sourceLineIndex);
    }

    if (languageFrame != null) {
      final language = _parseLanguageFrame(languageFrame);
      final alignedByLine = language.lineCount == karaokeLineCount;
      final translationList = language.translations.values.toList(
        growable: false,
      );
      final romanizationList = language.romanizations.values.toList(
        growable: false,
      );
      var translationCursor = 0;
      var romanizationCursor = 0;

      for (var i = 0; i < lines.length; i++) {
        if (lines[i].words.isEmpty) continue;
        final sourceLineIndex = sourceLineIndexes[i];

        String? translation;
        if (alignedByLine) {
          translation = language.translations[sourceLineIndex];
        } else if (translationCursor < translationList.length) {
          translation = translationList[translationCursor++];
        }
        if (translation != null && translation.isNotEmpty) {
          lines[i].translation = translation;
        }

        List<String>? tokens;
        if (alignedByLine) {
          tokens = language.romanizations[sourceLineIndex];
        } else if (romanizationCursor < romanizationList.length) {
          tokens = romanizationList[romanizationCursor++];
        }
        if (tokens == null || tokens.isEmpty) continue;

        lines[i].romanLyric = tokens.join();
        lines[i].romanWords = mapRomanWords(
          romanText: tokens.join(' '),
          words: lines[i].words,
          lineStart: lines[i].start,
          lineLength: lines[i].length,
        );
      }
    }

    // 添加空白
    final List<KrcLine> fommatedLines = [];
    final firstLine = lines.firstOrNull;
    if (firstLine != null && firstLine.start > const Duration(seconds: 5)) {
      fommatedLines.add(KrcLine(Duration.zero, firstLine.start, []));
    }
    for (int i = 0; i < lines.length - 1; ++i) {
      fommatedLines.add(lines[i]);
      final transitionStart = lines[i].start + lines[i].length;
      final transitionLength = lines[i + 1].start - transitionStart;
      if (transitionLength > const Duration(seconds: 5)) {
        fommatedLines.add(KrcLine(transitionStart, transitionLength, []));
      }
    }
    final lastLine = lines.lastOrNull;
    if (lastLine != null) {
      fommatedLines.add(lastLine);
    }

    return Krc(fommatedLines, LyricFormat.local, krc);
  }

  /// 解码 `[language:...]` 帧；帧损坏时按无翻译无注音处理。
  static KrcLanguageContent _parseLanguageFrame(String frame) {
    try {
      final decoded = json.decode(utf8.decode(base64.decode(frame)));
      if (decoded is! Map<String, dynamic>) return emptyKrcLanguageContent;
      return parseKrcLanguageContent(decoded['content']);
    } catch (error, trace) {
      log.lyric.warn(
        'lyric.parse',
        'KRC language 帧解析失败',
        error: error,
        stackTrace: trace,
      );
      return emptyKrcLanguageContent;
    }
  }

  @override
  String toString() {
    return (lines as List<SyncLyricLine>).toString();
  }
}

class KrcLine extends SyncLyricLine {
  KrcLine(super.start, super.length, super.words, [super.translation]);

  static final RegExp _headerRe = RegExp(r'^\[(\d+),(\d+)\]');

  static KrcLine? fromLine(String line, [String? translation, int offset = 0]) {
    // 只接受 KRC 行头，避免把 [ti:...]、[language:...] 等标签当成歌词行。
    if (!_headerRe.hasMatch(line)) return null;

    final splitedLine = line.split(']');
    final from = splitedLine[0].indexOf('[') + 1;
    final splitedTime = splitedLine[0].substring(from).split(',');

    if (splitedTime.length != 2) return null;

    final Duration start = Duration(
      milliseconds: max((int.tryParse(splitedTime[0]) ?? 0) - offset, 0),
    );
    final Duration length = Duration(
      milliseconds: int.tryParse(splitedTime[1]) ?? 0,
    );

    final splitedContent = splitedLine[1].split('<');
    final List<KrcWord> words = [];
    for (final item in splitedContent) {
      final qrcWord = KrcWord.fromWord(item, start, offset);

      if (qrcWord == null) continue;

      words.add(qrcWord);
    }

    return KrcLine(start, length, words, translation);
  }
}

class KrcWord extends SyncLyricWord {
  KrcWord(super.start, super.length, super.content);

  static KrcWord? fromWord(String word, Duration lineStart, [int offset = 0]) {
    final splitedWord = word.split('>');
    if (splitedWord.length != 2) return null;

    final splitedTime = splitedWord[0].split(',');

    if (splitedTime.length < 2) return null;

    final Duration start = Duration(
          milliseconds: max((int.tryParse(splitedTime[0]) ?? 0) - offset, 0),
        ) +
        lineStart;
    final Duration length = Duration(
      milliseconds: int.tryParse(splitedTime[1]) ?? 0,
    );

    final content = splitedWord[1];

    return KrcWord(start, length, content);
  }
}
