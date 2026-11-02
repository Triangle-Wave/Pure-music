/// 曲库集合（歌手、专辑等）详情页的跳转目标。
sealed class CollectionLinkTarget<T> {
  const CollectionLinkTarget();
}

/// 没有可用的跳转目标，入口保持禁用。
class CollectionLinkUnavailable<T> extends CollectionLinkTarget<T> {
  const CollectionLinkUnavailable();
}

/// 唯一目标，点击后直接进入详情页。
class CollectionLinkSingle<T> extends CollectionLinkTarget<T> {
  const CollectionLinkSingle(this.value);

  final T value;
}

/// 多个候选，点击后弹出菜单选择。
class CollectionLinkMultiple<T> extends CollectionLinkTarget<T> {
  const CollectionLinkMultiple(this.options);

  final List<CollectionLinkOption<T>> options;
}

/// 菜单候选：[label] 是标签里的原始名字，[value] 为空表示该名字不在曲库中。
class CollectionLinkOption<T> {
  const CollectionLinkOption({required this.label, required this.value});

  final String label;
  final T? value;
}

/// 按名字解析集合详情页的跳转目标。
///
/// 名字先去掉首尾空白、空串与重复项；只剩一个名字且能在 [collection]
/// 中查到目标时返回单目标，多个名字中至少一个能查到目标时返回菜单候选，
/// 其余情况返回不可用。
CollectionLinkTarget<T> resolveCollectionLinkTarget<T>(
  List<String> names,
  Map<String, T> collection,
) {
  final uniqueNames = <String>[];
  for (final rawName in names) {
    final name = rawName.trim();
    if (name.isEmpty || uniqueNames.contains(name)) continue;
    uniqueNames.add(name);
  }
  if (uniqueNames.isEmpty) return CollectionLinkUnavailable<T>();
  if (uniqueNames.length == 1) {
    final value = collection[uniqueNames.first];
    return value == null
        ? CollectionLinkUnavailable<T>()
        : CollectionLinkSingle<T>(value);
  }
  final options = [
    for (final name in uniqueNames)
      CollectionLinkOption<T>(label: name, value: collection[name]),
  ];
  return options.any((option) => option.value != null)
      ? CollectionLinkMultiple<T>(options)
      : CollectionLinkUnavailable<T>();
}
