import 'dart:collection';

import 'package:pure_music/lyric/lyric.dart';

/// 假名到罗马音的本地转写，用于为缺少罗马音的日文歌词生成显示文本。
///
/// 规则接近 Hepburn 式：拗音合写、促音双写、片假名长音重复前一元音。
/// 汉字没有词典无法取得读音，转写时按字符跳过；假名占比过低的行整体放弃。
/// 生成结果只用于显示，不写回歌词文件。
class JapaneseRomanizer {
  JapaneseRomanizer._();

  static const int _cacheCapacity = 2048;

  /// 行文本缓存，重新应用设置或重复加载同一首歌时不再逐字转换。
  static final LinkedHashMap<String, String> _cache =
      LinkedHashMap<String, String>();

  /// 判断一行原文是否值得生成罗马音。
  ///
  /// 只认纯假名行：汉字没有词典取不到读音，跳过汉字会留下残缺音节，
  /// 因此含汉字的行整体放弃；中文、英文、韩文没有假名，同样不转写。
  static bool isJapaneseLine(String text) {
    var kana = 0;
    var kanji = 0;
    for (final rune in text.runes) {
      if (_isKanaRune(rune)) {
        kana++;
      } else if (_isKanjiRune(rune)) {
        kanji++;
      }
    }
    if (kana < 2) return false;
    return kanji == 0;
  }

  /// 把假名文本转写为罗马音，汉字与非假名字符跳过。
  ///
  /// 结果按下标缓存，纯函数语义，可直接用于测试。
  static String romanizeText(String text) {
    if (text.isEmpty) return '';
    final cached = _cache.remove(text);
    if (cached != null) {
      _cache[text] = cached;
      return cached;
    }
    final converted = _romanizeUncached(text);
    _cache[text] = converted;
    if (_cache.length > _cacheCapacity) {
      _cache.remove(_cache.keys.first);
    }
    return converted;
  }

  /// 按主词生成与逐字高亮对齐的罗马音。
  ///
  /// 每个 token 继承对应主词的起始时间与时长，token 文本按顺序出现在整行
  /// 罗马音中，渲染层可按顺序定位并逐字着色。
  static ({String text, List<SyncLyricWord> words})? buildRomanLine({
    required List<SyncLyricWord> words,
    required Duration lineStart,
    required Duration lineLength,
  }) {
    if (words.isEmpty) return null;
    final source = words.map((word) => word.content).join();
    if (!isJapaneseLine(source)) return null;

    final tokens = <SyncLyricWord>[];
    for (final word in words) {
      final roman = romanizeText(word.content).trim();
      if (!_containsLatinLetter(roman)) continue;
      tokens.add(SyncLyricWord(word.start, word.length, roman));
    }
    if (tokens.isEmpty) return null;

    _fillZeroDurations(tokens, lineStart, lineLength);
    final text = tokens.map((token) => token.content).join(' ');
    return (text: text, words: tokens);
  }

  static String _romanizeUncached(String text) {
    final buffer = StringBuffer();
    var pendingGeminate = false;
    var pendingSpace = false;
    String? lastVowel;

    for (var i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      final char = text[i];

      if (_isWhitespace(code)) {
        pendingSpace = buffer.isNotEmpty;
        pendingGeminate = false;
        continue;
      }

      final normalized = String.fromCharCode(_katakanaToHiragana(code));

      if (normalized == 'ー') {
        if (lastVowel != null) {
          _writeToken(buffer, lastVowel, pendingSpace);
          pendingSpace = false;
        }
        continue;
      }

      if (normalized == 'っ') {
        pendingGeminate = true;
        continue;
      }

      String? syllable;
      var consumed = 1;
      if (i + 1 < text.length) {
        final nextCode = text.codeUnitAt(i + 1);
        final next = String.fromCharCode(_katakanaToHiragana(nextCode));
        final pair = '$normalized$next';
        syllable = _youonRomaji[pair];
        if (syllable != null) consumed = 2;
      }
      syllable ??= _basicRomaji[normalized];

      if (syllable == null) {
        if (_isLatinOrDigit(code)) {
          _writeToken(buffer, char, pendingSpace);
          pendingSpace = false;
        } else if (_isKeptPunctuation(code)) {
          _writeToken(buffer, char, pendingSpace);
          pendingSpace = false;
        }
        pendingGeminate = false;
        lastVowel = null;
        continue;
      }

      if (pendingGeminate) {
        buffer.write(_geminatePrefix(syllable));
        pendingGeminate = false;
      }
      _writeToken(buffer, syllable, pendingSpace);
      pendingSpace = false;
      lastVowel = _lastVowelOf(syllable);
      if (consumed == 2) i++;
    }

    return buffer.toString();
  }

  static void _writeToken(StringBuffer buffer, String token, bool needsSpace) {
    if (needsSpace && buffer.isNotEmpty) buffer.write(' ');
    buffer.write(token);
  }

  static void _fillZeroDurations(
    List<SyncLyricWord> tokens,
    Duration lineStart,
    Duration lineLength,
  ) {
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      if (token.length > Duration.zero) continue;
      final nextStart = i + 1 < tokens.length
          ? tokens[i + 1].start
          : lineStart + lineLength;
      final length = nextStart - token.start;
      if (length > Duration.zero) token.length = length;
    }
  }

  static String _geminatePrefix(String syllable) {
    if (syllable.startsWith('ch')) return 't';
    final first = syllable[0];
    if ('aeioun'.contains(first)) return '';
    return first;
  }

  static String? _lastVowelOf(String syllable) {
    for (var i = syllable.length - 1; i >= 0; i--) {
      final char = syllable[i];
      if (char == 'a' ||
          char == 'i' ||
          char == 'u' ||
          char == 'e' ||
          char == 'o') {
        return char;
      }
    }
    return null;
  }

  static bool _containsLatinLetter(String text) {
    return text.runes.any(
      (rune) =>
          (rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A),
    );
  }

  static int _katakanaToHiragana(int code) {
    if (code >= 0x30A1 && code <= 0x30F6) return code - 0x60;
    return code;
  }

  static bool _isKanaRune(int rune) {
    return (rune >= 0x3041 && rune <= 0x3096) ||
        (rune >= 0x30A1 && rune <= 0x30FA);
  }

  static bool _isKanjiRune(int rune) {
    return (rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0xF900 && rune <= 0xFAFF);
  }

  static bool _isWhitespace(int code) {
    return code == 0x20 ||
        code == 0x09 ||
        code == 0x0A ||
        code == 0x0D ||
        code == 0x3000;
  }

  static bool _isLatinOrDigit(int code) {
    return (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x5A) ||
        (code >= 0x61 && code <= 0x7A);
  }

  static bool _isKeptPunctuation(int code) {
    return code == 0x3001 || // 、
        code == 0x3002 || // 。
        code == 0xFF0C || // ，
        code == 0xFF01 || // ！
        code == 0xFF1F || // ？
        code == 0x300C || // 「
        code == 0x300D || // 」
        code == 0x300E || // 『
        code == 0x300F || // 』
        code == 0x0021 ||
        code == 0x003F ||
        code == 0x002C ||
        code == 0x002E ||
        code == 0x0027 ||
        code == 0x0022 ||
        code == 0x2026; // …
  }
}

const Map<String, String> _basicRomaji = {
  'あ': 'a', 'い': 'i', 'う': 'u', 'え': 'e', 'お': 'o',
  'か': 'ka', 'き': 'ki', 'く': 'ku', 'け': 'ke', 'こ': 'ko',
  'が': 'ga', 'ぎ': 'gi', 'ぐ': 'gu', 'げ': 'ge', 'ご': 'go',
  'さ': 'sa', 'し': 'shi', 'す': 'su', 'せ': 'se', 'そ': 'so',
  'ざ': 'za', 'じ': 'ji', 'ず': 'zu', 'ぜ': 'ze', 'ぞ': 'zo',
  'た': 'ta', 'ち': 'chi', 'つ': 'tsu', 'て': 'te', 'と': 'to',
  'だ': 'da', 'ぢ': 'ji', 'づ': 'zu', 'で': 'de', 'ど': 'do',
  'な': 'na', 'に': 'ni', 'ぬ': 'nu', 'ね': 'ne', 'の': 'no',
  'は': 'ha', 'ひ': 'hi', 'ふ': 'fu', 'へ': 'he', 'ほ': 'ho',
  'ば': 'ba', 'び': 'bi', 'ぶ': 'bu', 'べ': 'be', 'ぼ': 'bo',
  'ぱ': 'pa', 'ぴ': 'pi', 'ぷ': 'pu', 'ぺ': 'pe', 'ぽ': 'po',
  'ま': 'ma', 'み': 'mi', 'む': 'mu', 'め': 'me', 'も': 'mo',
  'や': 'ya', 'ゆ': 'yu', 'よ': 'yo',
  'ら': 'ra', 'り': 'ri', 'る': 'ru', 'れ': 're', 'ろ': 'ro',
  'わ': 'wa', 'ゐ': 'i', 'ゑ': 'e', 'を': 'o', 'ん': 'n',
  'ゔ': 'vu', 'ゎ': 'wa', 'ゕ': 'ka', 'ゖ': 'ke',
  'ぁ': 'a', 'ぃ': 'i', 'ぅ': 'u', 'ぇ': 'e', 'ぉ': 'o',
  'ゃ': 'ya', 'ゅ': 'yu', 'ょ': 'yo',
};

const Map<String, String> _youonRomaji = {
  'きゃ': 'kya', 'きゅ': 'kyu', 'きょ': 'kyo',
  'ぎゃ': 'gya', 'ぎゅ': 'gyu', 'ぎょ': 'gyo',
  'しゃ': 'sha', 'しゅ': 'shu', 'しょ': 'sho',
  'じゃ': 'ja', 'じゅ': 'ju', 'じょ': 'jo',
  'ちゃ': 'cha', 'ちゅ': 'chu', 'ちょ': 'cho',
  'ぢゃ': 'ja', 'ぢゅ': 'ju', 'ぢょ': 'jo',
  'にゃ': 'nya', 'にゅ': 'nyu', 'にょ': 'nyo',
  'ひゃ': 'hya', 'ひゅ': 'hyu', 'ひょ': 'hyo',
  'びゃ': 'bya', 'びゅ': 'byu', 'びょ': 'byo',
  'ぴゃ': 'pya', 'ぴゅ': 'pyu', 'ぴょ': 'pyo',
  'みゃ': 'mya', 'みゅ': 'myu', 'みょ': 'myo',
  'りゃ': 'rya', 'りゅ': 'ryu', 'りょ': 'ryo',
  'ふぁ': 'fa', 'ふぃ': 'fi', 'ふぇ': 'fe', 'ふぉ': 'fo',
  'てぃ': 'ti', 'でぃ': 'di', 'とぅ': 'tu', 'どぅ': 'du',
  'うぃ': 'wi', 'うぇ': 'we', 'うぉ': 'wo',
  'しぇ': 'she', 'じぇ': 'je', 'ちぇ': 'che',
  'ゔぁ': 'va', 'ゔぃ': 'vi', 'ゔぇ': 've', 'ゔぉ': 'vo',
  'くぁ': 'kwa', 'くぃ': 'kwi', 'くぇ': 'kwe', 'くぉ': 'kwo',
  'ぐぁ': 'gwa', 'ぐぃ': 'gwi', 'ぐぇ': 'gwe', 'ぐぉ': 'gwo',
};

/// 为缺少罗马音的日文同步歌词行补全显示用罗马音。
void applyAutoRomanization(Lyric lyric) {
  for (final line in lyric.lines) {
    // 元数据行按纯文本绘制，生成罗马音不会被使用。
    if (line.isMetadata) continue;
    if (line is! SyncLyricLine) continue;
    if (line.autoRomanized) continue;
    final existing = line.romanLyric;
    if (existing != null && existing.trim().isNotEmpty) continue;
    final built = JapaneseRomanizer.buildRomanLine(
      words: line.words,
      lineStart: line.start,
      lineLength: line.length,
    );
    if (built == null) continue;
    line.romanLyric = built.text;
    line.romanWords = built.words;
    line.autoRomanized = true;
  }
}

/// 移除本地生成的罗马音，保留歌词文件自带的罗马音。
void revertAutoRomanization(Lyric lyric) {
  for (final line in lyric.lines) {
    if (!line.autoRomanized) continue;
    line
      ..romanLyric = null
      ..romanWords = null
      ..autoRomanized = false;
  }
}
