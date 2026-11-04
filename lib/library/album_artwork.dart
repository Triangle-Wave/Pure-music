import 'package:flutter/foundation.dart';

/// 专辑图片的角色。
enum AlbumArtworkRole {
  /// 封面（正面）。
  front,

  /// 封底。
  back,

  /// 碟片或光盘介质图片。
  disc,

  /// 内页、插画或歌词页。
  booklet,

  /// 其他角色。
  other,
}

/// 角色的中文名与排序权重。
extension AlbumArtworkRoleInfo on AlbumArtworkRole {
  /// 角色中文名，不带序号。
  String get label => switch (this) {
    AlbumArtworkRole.front => '封面',
    AlbumArtworkRole.back => '封底',
    AlbumArtworkRole.disc => '碟片',
    AlbumArtworkRole.booklet => '内页',
    AlbumArtworkRole.other => '图片',
  };

  /// 展示顺序：封面、封底、碟片、内页、其他。
  int get order => switch (this) {
    AlbumArtworkRole.front => 0,
    AlbumArtworkRole.back => 1,
    AlbumArtworkRole.disc => 2,
    AlbumArtworkRole.booklet => 3,
    AlbumArtworkRole.other => 4,
  };
}

/// 专辑图片的来源。
enum AlbumArtworkSource {
  /// 音频所在文件夹中的图片文件。
  folderFile,

  /// 音频文件内嵌图片。
  embedded,

  /// 在线专辑图片。
  online,
}

/// 同角色多来源时的保留优先级，数值越小越优先。
extension AlbumArtworkSourcePriority on AlbumArtworkSource {
  int get priority => switch (this) {
    AlbumArtworkSource.folderFile => 0,
    AlbumArtworkSource.embedded => 1,
    AlbumArtworkSource.online => 2,
  };
}

/// 一张专辑图片的统一描述。
///
/// [path] 对文件夹图片与内嵌图片都是源文件绝对路径；内嵌图片再用
/// [pictureIndex] 区分同一文件中的不同图片。在线图片只用 [url] 与
/// [largeUrl] 定位，不携带本地路径。
@immutable
class AlbumArtwork {
  const AlbumArtwork({
    required this.role,
    required this.source,
    required this.label,
    this.path,
    this.pictureIndex,
    this.modified,
    this.url,
    this.largeUrl,
  });

  final AlbumArtworkRole role;
  final AlbumArtworkSource source;

  /// 展示名：封面、封底、碟片、内页 2、图片 3。
  final String label;

  /// 文件夹图片与内嵌图片的源文件绝对路径。
  final String? path;

  /// 内嵌图片在文件图片列表中的序号。
  final int? pictureIndex;

  /// 源文件修改时间（秒）。
  final int? modified;

  /// 在线图片的展示地址。
  final String? url;

  /// 在线图片的大图地址。
  final String? largeUrl;

  /// 源、路径与序号（或 URL）组成的唯一键，用于去重。
  String get key => switch (source) {
    AlbumArtworkSource.folderFile => 'folder|${(path ?? '').toLowerCase()}',
    AlbumArtworkSource.embedded =>
      'embedded|${(path ?? '').toLowerCase()}|#${pictureIndex ?? 0}',
    AlbumArtworkSource.online => 'online|${(url ?? '').trim()}',
  };

  AlbumArtwork withLabel(String value) {
    if (value == label) return this;
    return AlbumArtwork(
      role: role,
      source: source,
      label: value,
      path: path,
      pictureIndex: pictureIndex,
      modified: modified,
      url: url,
      largeUrl: largeUrl,
    );
  }

  @override
  String toString() => 'AlbumArtwork(${source.name}, ${role.name}, $label)';
}

/// 合并多来源图片：按 [AlbumArtwork.key] 去重，按角色排序并统一展示名。
///
/// 排序为封面、封底、碟片、内页、其他；内页与其他按序号或展示名中的数字
/// 自然序排列，序号相同时保持输入顺序。封面、封底与碟片同角色只保留优先级
/// 最高的一张（文件夹图片 > 内嵌图片 > 在线图片），内页与其他保留多张。
/// 排序只保证封面位于最前，列表第 0 项是否作为本地封面由调用方决定。
List<AlbumArtwork> mergeArtworks(Iterable<AlbumArtwork> items) {
  final seen = <String>{};
  final unique = <AlbumArtwork>[];
  for (final item in items) {
    if (seen.add(item.key)) unique.add(item);
  }

  final singles = <AlbumArtworkRole, AlbumArtwork>{};
  final multiple = <AlbumArtwork>[];
  for (final item in unique) {
    switch (item.role) {
      case AlbumArtworkRole.front:
      case AlbumArtworkRole.back:
      case AlbumArtworkRole.disc:
        final existing = singles[item.role];
        if (existing == null ||
            item.source.priority < existing.source.priority) {
          singles[item.role] = item;
        }
      case AlbumArtworkRole.booklet:
      case AlbumArtworkRole.other:
        multiple.add(item);
    }
  }

  final ordered = <AlbumArtwork>[
    for (final role in const [
      AlbumArtworkRole.front,
      AlbumArtworkRole.back,
      AlbumArtworkRole.disc,
    ])
      if (singles[role] != null) singles[role]!,
    ...multiple,
  ];

  final entries = <_ArtworkOrderEntry>[
    for (var index = 0; index < ordered.length; index++)
      _ArtworkOrderEntry(
        artwork: ordered[index],
        inputIndex: index,
        naturalOrder: _naturalOrderOf(ordered[index]),
      ),
  ];
  entries.sort((a, b) {
    final byRole = a.artwork.role.order.compareTo(b.artwork.role.order);
    if (byRole != 0) return byRole;
    final byNatural = a.naturalOrder.compareTo(b.naturalOrder);
    if (byNatural != 0) return byNatural;
    return a.inputIndex.compareTo(b.inputIndex);
  });

  var bookletCount = 0;
  var otherCount = 0;
  final result = <AlbumArtwork>[];
  for (final entry in entries) {
    final artwork = entry.artwork;
    final label = switch (artwork.role) {
      AlbumArtworkRole.front => AlbumArtworkRole.front.label,
      AlbumArtworkRole.back => AlbumArtworkRole.back.label,
      AlbumArtworkRole.disc => AlbumArtworkRole.disc.label,
      AlbumArtworkRole.booklet =>
        '${AlbumArtworkRole.booklet.label} ${++bookletCount}',
      AlbumArtworkRole.other =>
        '${AlbumArtworkRole.other.label} ${++otherCount}',
    };
    result.add(artwork.withLabel(label));
  }
  return List<AlbumArtwork>.unmodifiable(result);
}

/// 自然序取值：优先内嵌图片序号，其次展示名末尾的数字。
int _naturalOrderOf(AlbumArtwork artwork) {
  final index = artwork.pictureIndex;
  if (index != null) return index;
  final match = RegExp(r'(\d+)\s*$').firstMatch(artwork.label);
  if (match == null) return 0;
  return int.tryParse(match.group(1)!) ?? 0;
}

class _ArtworkOrderEntry {
  const _ArtworkOrderEntry({
    required this.artwork,
    required this.inputIndex,
    required this.naturalOrder,
  });

  final AlbumArtwork artwork;
  final int inputIndex;
  final int naturalOrder;
}