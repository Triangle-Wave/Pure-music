import 'dart:math' as math;

/// 达到该分数才认为找到了可信的在线专辑，避免把同名合辑当成目标专辑。
const double minimumOnlineAlbumScore = 60;

/// 艺术家名称视为同一人的最低相似度。
const double minimumArtistNameScore = 0.86;

String normalizeForMatch(String value) {
  var text = value.toLowerCase();
  text = text.replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ');
  text = text.replaceAll(
    RegExp('[^a-z0-9\\u4e00-\\u9fff\\u3040-\\u30ff\\uac00-\\ud7af]+'),
    ' ',
  );
  return text.trim().replaceAll(RegExp(r'\s+'), ' ');
}

double albumTitleSimilarity(String left, String right) {
  final a = normalizeForMatch(left);
  final b = normalizeForMatch(right);
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  final shorter = a.length <= b.length ? a : b;
  final longer = a.length <= b.length ? b : a;
  if (shorter.length >= 4 && longer.contains(shorter)) {
    return 0.82 + 0.18 * (shorter.length / longer.length);
  }
  final distance = levenshteinDistance(a, b);
  final maxLength = a.length >= b.length ? a.length : b.length;
  return (1 - distance / maxLength).clamp(0.0, 1.0).toDouble();
}

double albumArtistSimilarity(String artist, List<String> candidates) {
  if (normalizeForMatch(artist).isEmpty) return 0;
  var best = 0.0;
  for (final candidate in candidates) {
    final score = albumTitleSimilarity(artist, candidate);
    if (score > best) best = score;
  }
  return best;
}

/// 把多艺术家字段拆成单个名字；支持 `/`、`、`、`,`、`&`、`;` 与 feat/ft。
List<String> splitArtistTokens(String raw) {
  final result = <String>[];
  for (final part in raw.split(
    RegExp(r'\s*(?:/|、|,|&|;|；|\bfeat\.?\b|\bft\.?\b)\s*',
        caseSensitive: false),
  )) {
    final trimmed = part.trim();
    if (trimmed.isNotEmpty) result.add(trimmed);
  }
  return result;
}

/// 艺术家名及用户配置的别名。别名方向为“原始写法 -> 规范写法”，
/// 这里同时展开两个方向，保证本地名是规范写法时也能找到原始写法。
List<String> artistNameVariants(
  String artist,
  Map<String, String> aliases,
) {
  final variants = <String>[];
  final seen = <String>{};

  void add(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    final key = normalizeForMatch(trimmed);
    if (key.isEmpty || !seen.add(key)) return;
    variants.add(trimmed);
  }

  for (final token in splitArtistTokens(artist)) {
    add(token);
    final mapped = aliases[token];
    if (mapped != null) {
      for (final alias in splitArtistTokens(mapped)) {
        add(alias);
      }
    }
  }
  final artistKey = normalizeForMatch(artist);
  for (final entry in aliases.entries) {
    if (normalizeForMatch(entry.value) != artistKey) continue;
    for (final alias in splitArtistTokens(entry.key)) {
      add(alias);
    }
  }
  return variants;
}

/// 查询名与候选艺术家名的匹配分：规范化相等为 1，包含为 0.92，
/// 其余退回编辑距离相似度。
double artistNameSimilarity(
  String query,
  String candidate, {
  Map<String, String> aliases = const {},
}) {
  final queryVariants = artistNameVariants(query, aliases);
  final candidateNames = splitArtistTokens(candidate);
  if (queryVariants.isEmpty || candidateNames.isEmpty) return 0;
  var best = 0.0;
  for (final variant in queryVariants) {
    final a = normalizeForMatch(variant);
    if (a.isEmpty) continue;
    for (final name in candidateNames) {
      final b = normalizeForMatch(name);
      if (b.isEmpty) continue;
      double score;
      if (a == b) {
        score = 1;
      } else if (a.contains(b) || b.contains(a)) {
        score = 0.92;
      } else {
        final maxLength = a.length >= b.length ? a.length : b.length;
        score = (1 - levenshteinDistance(a, b) / maxLength)
            .clamp(0.0, 1.0)
            .toDouble();
      }
      if (score > best) best = score;
    }
  }
  return best;
}

int levenshteinDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var previous = List<int>.generate(b.length + 1, (index) => index);
  for (var i = 0; i < a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0);
    current[0] = i + 1;
    final codeUnit = a.codeUnitAt(i);
    for (var j = 0; j < b.length; j++) {
      final cost = codeUnit == b.codeUnitAt(j) ? 0 : 1;
      final insert = current[j] + 1;
      final delete = previous[j + 1] + 1;
      final replace = previous[j] + cost;
      current[j + 1] = math.min(insert, math.min(delete, replace));
    }
    previous = current;
  }
  return previous[b.length];
}
