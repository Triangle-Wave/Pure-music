import 'package:pure_music/library/union_search_result.dart';

/// 混合搜索结果按类型拆成三组，组内顺序沿用传入的混排结果。
class SearchItemGroup {
  const SearchItemGroup({
    required this.kind,
    required this.title,
    required this.items,
  });

  final UnionSearchItemKind kind;
  final String title;
  final List<UnionSearchItem> items;
}

/// 按歌曲、歌手、专辑顺序分组；空组不返回。
/// 数据层仍返回单个混排列表，分组只在展示层完成。
List<SearchItemGroup> groupSearchItems(List<UnionSearchItem> items) {
  final byKind = <UnionSearchItemKind, List<UnionSearchItem>>{};
  for (final item in items) {
    (byKind[item.kind] ??= <UnionSearchItem>[]).add(item);
  }
  const ordered = <UnionSearchItemKind>[
    UnionSearchItemKind.music,
    UnionSearchItemKind.artist,
    UnionSearchItemKind.album,
  ];
  const titles = <UnionSearchItemKind, String>{
    UnionSearchItemKind.music: '歌曲',
    UnionSearchItemKind.artist: '歌手',
    UnionSearchItemKind.album: '专辑',
  };
  final groups = <SearchItemGroup>[];
  for (final kind in ordered) {
    final group = byKind[kind];
    if (group == null || group.isEmpty) continue;
    groups.add(
      SearchItemGroup(
        kind: kind,
        title: '${titles[kind]} · ${group.length}',
        items: List<UnionSearchItem>.unmodifiable(group),
      ),
    );
  }
  return List<SearchItemGroup>.unmodifiable(groups);
}
