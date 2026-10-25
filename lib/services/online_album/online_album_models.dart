import 'package:pure_music/services/online_album/album_match.dart';
import 'package:pure_music/services/online_album/cover_art_client.dart';

class OnlineAlbumArtwork {
  const OnlineAlbumArtwork({
    required this.url,
    required this.role,
    required this.label,
  });

  final String url;

  /// `front`、`back` 或 `booklet`。
  final String role;
  final String label;
}

class OnlineAlbumInfo {
  const OnlineAlbumInfo({
    required this.releaseGroupId,
    required this.title,
    this.artist,
    this.year,
    this.label,
    this.genre,
    this.summary,
    this.trackCount,
    this.primaryType,
    this.secondaryTypes = const [],
    this.covers = CoverArtSet.empty,
    this.source,
  });

  final String releaseGroupId;
  final String title;
  final String? artist;
  final int? year;
  final String? label;
  final String? genre;
  final String? summary;
  final int? trackCount;
  final String? primaryType;
  final List<String> secondaryTypes;
  final CoverArtSet covers;

  /// 数据来源显示名，例如“网易云音乐”“MusicBrainz”。
  final String? source;

  String get sourceLabel {
    final value = source?.trim();
    return value == null || value.isEmpty ? 'MusicBrainz' : value;
  }

  List<OnlineAlbumArtwork> get artworks {
    final result = <OnlineAlbumArtwork>[];
    final front = covers.front;
    if (front != null) {
      result.add(
        OnlineAlbumArtwork(url: front.url, role: 'front', label: '封面'),
      );
    }
    final back = covers.back;
    if (back != null) {
      result.add(
        OnlineAlbumArtwork(url: back.url, role: 'back', label: '封底'),
      );
    }
    for (var i = 0; i < covers.booklets.length; i++) {
      result.add(
        OnlineAlbumArtwork(
          url: covers.booklets[i].url,
          role: 'booklet',
          label: '内页 ${i + 1}',
        ),
      );
    }
    return List.unmodifiable(result);
  }

  Map<String, Object?> toJson() => {
    'releaseGroupId': releaseGroupId,
    'title': title,
    'artist': artist,
    'year': year,
    'label': label,
    'genre': genre,
    'summary': summary,
    'trackCount': trackCount,
    'primaryType': primaryType,
    'secondaryTypes': secondaryTypes,
    'covers': covers.toJson(),
    'source': source,
  };

  static OnlineAlbumInfo? fromJson(Object? data) {
    if (data is! Map<dynamic, dynamic>) return null;
    final releaseGroupId = textOrNull(data['releaseGroupId']);
    final title = textOrNull(data['title']);
    if (releaseGroupId == null || title == null) return null;
    return OnlineAlbumInfo(
      releaseGroupId: releaseGroupId,
      title: title,
      artist: textOrNull(data['artist']),
      year: numberOrNull(data['year']),
      label: textOrNull(data['label']),
      genre: textOrNull(data['genre']),
      summary: textOrNull(data['summary']),
      trackCount: numberOrNull(data['trackCount']),
      primaryType: textOrNull(data['primaryType']),
      secondaryTypes: textListOrEmpty(data['secondaryTypes']),
      covers: CoverArtSet.fromJson(data['covers']),
      source: textOrNull(data['source']),
    );
  }
}

/// 一个可选的在线专辑来源。
///
/// [info] 是查询时生成的完整信息快照，选中候选后无需再次请求即可展示；
/// [imageUrl] 只用于候选列表缩略图。
class OnlineAlbumCandidate {
  const OnlineAlbumCandidate({
    required this.id,
    required this.source,
    required this.title,
    required this.artist,
    required this.score,
    required this.info,
    this.year,
    this.trackCount,
    this.imageUrl,
  });

  final String id;
  final String source;
  final String title;
  final String artist;
  final int? year;
  final int? trackCount;
  final String? imageUrl;
  final double score;
  final OnlineAlbumInfo info;

  Map<String, Object?> toJson() => {
    'id': id,
    'source': source,
    'title': title,
    'artist': artist,
    'year': year,
    'trackCount': trackCount,
    'imageUrl': imageUrl,
    'score': score,
    'info': info.toJson(),
  };

  static OnlineAlbumCandidate? fromJson(Object? data) {
    if (data is! Map<dynamic, dynamic>) return null;
    final id = textOrNull(data['id']);
    final source = textOrNull(data['source']);
    final title = textOrNull(data['title']);
    final info = OnlineAlbumInfo.fromJson(data['info']);
    if (id == null || source == null || title == null || info == null) {
      return null;
    }
    return OnlineAlbumCandidate(
      id: id,
      source: source,
      title: title,
      artist: textOrNull(data['artist']) ?? '',
      year: numberOrNull(data['year']),
      trackCount: numberOrNull(data['trackCount']),
      imageUrl: textOrNull(data['imageUrl']),
      score: doubleOrNull(data['score']) ?? 0,
      info: info,
    );
  }
}

/// 专辑候选与当前选择。
///
/// [selectedCandidateId] 为空表示自动使用最佳候选；[disabled] 表示用户选择
/// “不使用（显示空白）”，此时不发请求也不展示在线信息。
class OnlineAlbumCandidateCache {
  const OnlineAlbumCandidateCache({
    required this.candidates,
    this.selectedCandidateId,
    this.disabled = false,
    this.savedAt,
  });

  final List<OnlineAlbumCandidate> candidates;
  final String? selectedCandidateId;
  final bool disabled;
  final DateTime? savedAt;

  OnlineAlbumCandidate? get bestCandidate {
    OnlineAlbumCandidate? best;
    for (final candidate in candidates) {
      if (best == null || candidate.score > best.score) best = candidate;
    }
    return best;
  }

  /// 实际生效的候选：显式选择优先，否则使用达到阈值的最高分候选。
  OnlineAlbumCandidate? get activeCandidate {
    if (disabled) return null;
    final id = selectedCandidateId;
    if (id != null) {
      for (final candidate in candidates) {
        if (candidate.id == id) return candidate;
      }
    }
    final best = bestCandidate;
    if (best == null) return null;
    return best.score >= minimumOnlineAlbumScore ? best : null;
  }

  OnlineAlbumInfo? get info => activeCandidate?.info;

  bool get hasExplicitSelection => !disabled && selectedCandidateId != null;

  OnlineAlbumCandidateCache withSelection({
    required String? candidateId,
    required bool disabled,
    required DateTime savedAt,
  }) {
    return OnlineAlbumCandidateCache(
      candidates: candidates,
      selectedCandidateId: candidateId,
      disabled: disabled,
      savedAt: savedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'schema': 2,
    'savedAt': savedAt?.toIso8601String(),
    'selectedCandidateId': selectedCandidateId,
    'disabled': disabled,
    'candidates': candidates.map((candidate) => candidate.toJson()).toList(),
  };

  static OnlineAlbumCandidateCache? fromJson(Object? data) {
    if (data is! Map<dynamic, dynamic>) return null;
    final rawCandidates = data['candidates'];
    if (rawCandidates is! List<dynamic>) return null;
    final candidates = <OnlineAlbumCandidate>[];
    for (final raw in rawCandidates) {
      final candidate = OnlineAlbumCandidate.fromJson(raw);
      if (candidate != null) candidates.add(candidate);
    }
    if (rawCandidates.isNotEmpty && candidates.isEmpty) return null;
    return OnlineAlbumCandidateCache(
      candidates: List.unmodifiable(candidates),
      selectedCandidateId: textOrNull(data['selectedCandidateId']),
      disabled: data['disabled'] == true,
      savedAt: dateOrNull(data['savedAt']),
    );
  }
}

/// 一个可选的在线艺术家头像来源。
class OnlineArtistCandidate {
  const OnlineArtistCandidate({
    required this.id,
    required this.source,
    required this.name,
    required this.score,
    this.imageUrl,
    this.albumCount,
  });

  final String id;
  final String source;
  final String name;
  final String? imageUrl;
  final int? albumCount;
  final double score;

  Map<String, Object?> toJson() => {
    'id': id,
    'source': source,
    'name': name,
    'imageUrl': imageUrl,
    'albumCount': albumCount,
    'score': score,
  };

  static OnlineArtistCandidate? fromJson(Object? data) {
    if (data is! Map<dynamic, dynamic>) return null;
    final id = textOrNull(data['id']);
    final source = textOrNull(data['source']);
    final name = textOrNull(data['name']);
    if (id == null || source == null || name == null) return null;
    return OnlineArtistCandidate(
      id: id,
      source: source,
      name: name,
      imageUrl: textOrNull(data['imageUrl']),
      albumCount: numberOrNull(data['albumCount']),
      score: doubleOrNull(data['score']) ?? 0,
    );
  }
}

/// 艺术家候选与当前选择。语义与 [OnlineAlbumCandidateCache] 一致。
class OnlineArtistCandidateCache {
  const OnlineArtistCandidateCache({
    required this.candidates,
    this.selectedCandidateId,
    this.disabled = false,
    this.savedAt,
  });

  final List<OnlineArtistCandidate> candidates;
  final String? selectedCandidateId;
  final bool disabled;
  final DateTime? savedAt;

  OnlineArtistCandidate? get bestCandidate {
    OnlineArtistCandidate? best;
    for (final candidate in candidates) {
      final image = candidate.imageUrl;
      if (image == null || image.isEmpty) continue;
      if (best == null || candidate.score > best.score) best = candidate;
    }
    return best;
  }

  OnlineArtistCandidate? get activeCandidate {
    if (disabled) return null;
    final id = selectedCandidateId;
    if (id != null) {
      for (final candidate in candidates) {
        if (candidate.id != id) continue;
        final image = candidate.imageUrl;
        return image == null || image.isEmpty ? null : candidate;
      }
    }
    final best = bestCandidate;
    if (best == null || best.score < minimumArtistNameScore) return null;
    return best;
  }

  String? get activeImageUrl => activeCandidate?.imageUrl;

  bool get hasExplicitSelection => !disabled && selectedCandidateId != null;

  OnlineArtistCandidateCache withSelection({
    required String? candidateId,
    required bool disabled,
    required DateTime savedAt,
  }) {
    return OnlineArtistCandidateCache(
      candidates: candidates,
      selectedCandidateId: candidateId,
      disabled: disabled,
      savedAt: savedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'schema': 2,
    'savedAt': savedAt?.toIso8601String(),
    'selectedCandidateId': selectedCandidateId,
    'disabled': disabled,
    'candidates': candidates.map((candidate) => candidate.toJson()).toList(),
  };

  static OnlineArtistCandidateCache? fromJson(Object? data) {
    if (data is! Map<dynamic, dynamic>) return null;
    final rawCandidates = data['candidates'];
    if (rawCandidates is! List<dynamic>) return null;
    final candidates = <OnlineArtistCandidate>[];
    for (final raw in rawCandidates) {
      final candidate = OnlineArtistCandidate.fromJson(raw);
      if (candidate != null) candidates.add(candidate);
    }
    if (rawCandidates.isNotEmpty && candidates.isEmpty) return null;
    return OnlineArtistCandidateCache(
      candidates: List.unmodifiable(candidates),
      selectedCandidateId: textOrNull(data['selectedCandidateId']),
      disabled: data['disabled'] == true,
      savedAt: dateOrNull(data['savedAt']),
    );
  }
}

String? textOrNull(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}

int? numberOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

double? doubleOrNull(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

DateTime? dateOrNull(Object? value) {
  if (value is String && value.trim().isNotEmpty) {
    return DateTime.tryParse(value.trim());
  }
  return null;
}

List<String> textListOrEmpty(Object? value) {
  if (value is! List<dynamic>) return const [];
  final result = <String>[];
  for (final item in value) {
    final text = textOrNull(item);
    if (text != null) result.add(text);
  }
  return List.unmodifiable(result);
}
