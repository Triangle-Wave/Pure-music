import 'package:pure_music/core/zh_converter.dart';

final RegExp _searchWhitespacePattern = RegExp(r'\s+');

/// 按既有规则归一化搜索词：trim、去除内部空白。
String normalizedSearchQuery(String value) =>
    value.trim().replaceAll(_searchWhitespacePattern, '');

/// 搜索文本统一归一化：在 [normalizedSearchQuery] 基础上转小写并转为简体。
/// 查询词与所有被匹配文本都走这里，确保简繁互通与大小写不敏感。
String normalizeSearchText(String value) =>
    ZhConverter.toSimple(normalizedSearchQuery(value).toLowerCase());

bool canSubmitChangedSearchQuery({
  required String currentQuery,
  required String nextQuery,
}) {
  final normalizedCurrent = normalizedSearchQuery(currentQuery);
  final normalizedNext = normalizedSearchQuery(nextQuery);
  return normalizedNext.isNotEmpty && normalizedNext != normalizedCurrent;
}

bool canShowSearchClearAction(String value) =>
    normalizedSearchQuery(value).isNotEmpty;
