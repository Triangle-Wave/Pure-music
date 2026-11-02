import 'package:pure_music/core/artist_name_splitter.dart';

/// 按显示名归组：别名映射里所有指向同一显示名的原始名。
Map<String, List<String>> groupArtistAliases(Map<String, String> aliases) {
  final normalized = normalizedArtistAliases(aliases);
  final groups = <String, List<String>>{};
  for (final entry in normalized.entries) {
    final members = groups[entry.value];
    if (members == null) {
      groups[entry.value] = <String>[entry.key];
    } else {
      members.add(entry.key);
    }
  }
  return groups;
}

/// 某个显示名下的成员原始名，按映射顺序返回，不含显示名自身。
List<String> artistGroupMembers(
  String displayName,
  Map<String, String> aliases,
) {
  final target = displayName.trim();
  if (target.isEmpty) return const <String>[];
  return groupArtistAliases(aliases)[target] ?? const <String>[];
}

/// 搜索歌手时用的全部名字：显示名加成员原始名。
List<String> artistSearchNames(
  String displayName,
  Map<String, String> aliases,
) {
  return <String>[displayName, ...artistGroupMembers(displayName, aliases)];
}

/// 计算一次「关联歌手」编辑后的完整映射。
///
/// [currentName] 是当前显示名，[displayName] 是编辑后的显示名，
/// [selectedNames] 是编辑后该组的完整成员集合（不含显示名）。
/// 被并入的歌手如果自身也是一个显示名，其整组一起归入新显示名；
/// 从选择中移除的成员恢复独立。显示名自身永远不写映射。
Map<String, String> applyArtistGroupLink({
  required String currentName,
  required String displayName,
  required Iterable<String> selectedNames,
  required Map<String, String> aliases,
}) {
  final current = currentName.trim();
  final target = displayName.trim();
  final previous = normalizedArtistAliases(aliases);
  if (target.isEmpty) return previous;

  final members = <String>{};
  for (final name in selectedNames) {
    final trimmed = name.trim();
    if (trimmed.isNotEmpty && trimmed != target) members.add(trimmed);
  }
  if (current.isNotEmpty && current != target) members.add(current);

  final result = <String, String>{};
  for (final entry in previous.entries) {
    if (entry.key == target) continue;
    if (members.contains(entry.key)) {
      result[entry.key] = target;
      continue;
    }
    if (entry.value == current) {
      // 从当前组移除的成员恢复独立。
      continue;
    }
    if (members.contains(entry.value)) {
      // 被选中的歌手本身是另一个组的显示名，整组一起归入目标。
      result[entry.key] = target;
      continue;
    }
    result[entry.key] = entry.value;
  }
  for (final name in members) {
    result[name] = target;
  }
  return normalizedArtistAliases(result);
}
