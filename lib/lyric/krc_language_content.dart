import 'package:pure_music/lyric/metadata_detector.dart';

/// KRC `[language:...]` 帧中一个条目的用途。
enum KrcLanguageRole { romanization, translation }

/// `[language:...]` 帧解析结果，按歌词行序号索引。
class KrcLanguageContent {
  const KrcLanguageContent({
    required this.translations,
    required this.romanizations,
    required this.lineCount,
  });

  final Map<int, String> translations;
  final Map<int, List<String>> romanizations;

  /// 所有条目中最大的行数，用于判断行序号能否直接与主歌词对齐。
  final int lineCount;
}

const KrcLanguageContent emptyKrcLanguageContent = KrcLanguageContent(
  translations: <int, String>{},
  romanizations: <int, List<String>>{},
  lineCount: 0,
);

/// 判定每个条目的用途。
///
/// 条目带 `type` 时沿用既有约定：0 为罗马音，1 为翻译，其他值忽略。
/// 条目缺少 `type` 时按内容识别：以拉丁字母或假名为主视为罗马音，
/// 以汉字为主视为翻译；仍无法区分时按 KRC 常见顺序先注音后翻译。
List<KrcLanguageRole?> resolveKrcLanguageRoles(
  List<Map<String, dynamic>?> entries,
) {
  final roles = <KrcLanguageRole?>[];
  final assigned = <KrcLanguageRole>{};
  for (final entry in entries) {
    if (entry == null) {
      roles.add(null);
      continue;
    }
    final role = _roleOf(entry, assigned);
    if (role != null) assigned.add(role);
    roles.add(role);
  }
  return roles;
}

/// 解析 `[language:...]` 帧的 `content` 数组。
KrcLanguageContent parseKrcLanguageContent(dynamic content) {
  if (content is! List) return emptyKrcLanguageContent;

  final entries = <Map<String, dynamic>?>[];
  for (final item in content) {
    entries.add(item is Map ? Map<String, dynamic>.from(item) : null);
  }
  final roles = resolveKrcLanguageRoles(entries);

  final translations = <int, String>{};
  final romanizations = <int, List<String>>{};
  var lineCount = 0;

  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final role = roles[i];
    if (entry == null || role == null) continue;
    final lyricContent = entry['lyricContent'];
    if (lyricContent is! List) continue;
    if (lyricContent.length > lineCount) lineCount = lyricContent.length;

    for (var lineIndex = 0; lineIndex < lyricContent.length; lineIndex++) {
      final line = lyricContent[lineIndex];
      if (line is! List) continue;
      if (role == KrcLanguageRole.translation) {
        final text = line.isEmpty
            ? ''
            : (line.first?.toString() ?? '').trim();
        if (text.isEmpty || isLyricMetadataText(text)) continue;
        translations[lineIndex] = text;
      } else {
        final tokens = <String>[];
        for (final token in line) {
          final text = (token?.toString() ?? '').trim();
          if (text.isNotEmpty) tokens.add(text);
        }
        if (tokens.isNotEmpty) romanizations[lineIndex] = tokens;
      }
    }
  }

  return KrcLanguageContent(
    translations: translations,
    romanizations: romanizations,
    lineCount: lineCount,
  );
}

KrcLanguageRole? _roleOf(
  Map<String, dynamic> entry,
  Set<KrcLanguageRole> assigned,
) {
  if (entry.containsKey('type') && entry['type'] != null) {
    return _explicitRole(entry['type']);
  }

  final detected = _detectRole(entry['lyricContent']);
  if (detected != null && !assigned.contains(detected)) return detected;
  if (!assigned.contains(KrcLanguageRole.romanization)) {
    return KrcLanguageRole.romanization;
  }
  if (!assigned.contains(KrcLanguageRole.translation)) {
    return KrcLanguageRole.translation;
  }
  return null;
}

KrcLanguageRole? _explicitRole(dynamic rawType) {
  final type = rawType is int ? rawType : int.tryParse(rawType.toString());
  return switch (type) {
    0 => KrcLanguageRole.romanization,
    1 => KrcLanguageRole.translation,
    _ => null,
  };
}

KrcLanguageRole? _detectRole(dynamic lyricContent) {
  if (lyricContent is! List) return null;

  var han = 0;
  var phonetic = 0;
  for (final line in lyricContent) {
    if (line is! List) continue;
    for (final token in line) {
      final text = token?.toString() ?? '';
      for (final rune in text.runes) {
        if (_isHan(rune)) {
          han++;
        } else if (_isKana(rune) || _isLatin(rune)) {
          phonetic++;
        }
      }
    }
  }

  if (phonetic == 0) {
    return han == 0 ? null : KrcLanguageRole.translation;
  }
  if (han == 0) return KrcLanguageRole.romanization;
  return phonetic >= han
      ? KrcLanguageRole.romanization
      : KrcLanguageRole.translation;
}

bool _isHan(int rune) =>
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    (rune >= 0x4E00 && rune <= 0x9FFF) ||
    (rune >= 0xF900 && rune <= 0xFAFF) ||
    (rune >= 0x20000 && rune <= 0x2FA1F);

bool _isKana(int rune) =>
    (rune >= 0x3040 && rune <= 0x30FF) || (rune >= 0x31F0 && rune <= 0x31FF);

bool _isLatin(int rune) =>
    (rune >= 0x0041 && rune <= 0x005A) ||
    (rune >= 0x0061 && rune <= 0x007A) ||
    (rune >= 0x00C0 && rune <= 0x024F);
