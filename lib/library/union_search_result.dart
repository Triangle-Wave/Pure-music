import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/core/artist_alias_groups.dart';
import 'package:pure_music/core/search_action_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';

enum SearchScope { music, artist, album }

/// 联合搜索结果的条目类型，同时作为同档同 key 时的固定次序。
enum UnionSearchItemKind { music, artist, album }

/// 混排列表里的单个条目，只持有其中一类对象。
class UnionSearchItem {
  const UnionSearchItem({
    required this.kind,
    required this.rank,
    required this.sortKey,
    required this.audioIndex,
    this.audio,
    this.artist,
    this.album,
  });

  final UnionSearchItemKind kind;
  final int rank;
  final String sortKey;
  final int audioIndex;
  final Audio? audio;
  final Artist? artist;
  final Album? album;
}

/// 名字完全匹配或前缀命中归 0；其余包含、别名与拼音命中归 1。
int unionSearchRank(String name, String queryInLowerCase) {
  final normalized = normalizedSearchQuery(name).toLowerCase();
  return normalized == queryInLowerCase ||
          normalized.startsWith(queryInLowerCase)
      ? 0
      : 1;
}

/// 把三类命中按统一档位合成为一个有序列表，供搜索框混排展示。
/// 档位 0 在前、档位 1 在后；同档按显示名字典序，再按类型固定次序兜底。
/// 返回的 audioIndex 是歌曲在 audios 中的原始下标，用于确定播放队列。
List<UnionSearchItem> rankUnionSearchItems({
  required List<Audio> audios,
  required List<Artist> artists,
  required List<Album> albums,
  required String queryInLowerCase,
  Map<String, List<String>>? artistAliasGroups,
  bool Function(String text, String query)? matchesQuery,
}) {
  if (queryInLowerCase.isEmpty) return const <UnionSearchItem>[];
  final matches = matchesQuery ?? _matchesQuery;
  final groups =
      artistAliasGroups ??
      groupArtistAliases(AppSettings.instance.artistAliases);
  final items = <UnionSearchItem>[];

  for (int i = 0; i < audios.length; i++) {
    final audio = audios[i];
    final rank = audio.searchMatchRank(queryInLowerCase);
    if (rank != 0 && rank != 1) continue;
    items.add(
      UnionSearchItem(
        kind: UnionSearchItemKind.music,
        rank: rank,
        sortKey: normalizedSearchQuery(audio.title).toLowerCase(),
        audioIndex: i,
        audio: audio,
      ),
    );
  }

  for (final artist in artists) {
    final rank = _artistRank(
      artist,
      queryInLowerCase,
      groups,
      matches,
    );
    if (rank == null) continue;
    items.add(
      UnionSearchItem(
        kind: UnionSearchItemKind.artist,
        rank: rank,
        sortKey: normalizedSearchQuery(artist.name).toLowerCase(),
        audioIndex: -1,
        artist: artist,
      ),
    );
  }

  for (final album in albums) {
    if (!matches(album.name, queryInLowerCase)) continue;
    items.add(
      UnionSearchItem(
        kind: UnionSearchItemKind.album,
        rank: unionSearchRank(album.name, queryInLowerCase),
        sortKey: normalizedSearchQuery(album.name).toLowerCase(),
        audioIndex: -1,
        album: album,
      ),
    );
  }

  items.sort((a, b) {
    final byRank = a.rank.compareTo(b.rank);
    if (byRank != 0) return byRank;
    final byKey = a.sortKey.compareTo(b.sortKey);
    if (byKey != 0) return byKey;
    return a.kind.index.compareTo(b.kind.index);
  });
  return List<UnionSearchItem>.unmodifiable(items);
}

/// 文本、拼音首字母与完整拼音共用同一套规范化匹配。
bool _matchesQuery(String text, String queryInLowerCase) {
  if (normalizedSearchQuery(text).toLowerCase().contains(queryInLowerCase)) {
    return true;
  }
  return text.getPinyinInitials().toLowerCase().contains(queryInLowerCase) ||
      text.getPinyin().toLowerCase().contains(queryInLowerCase);
}

int? _artistRank(
  Artist artist,
  String queryInLowerCase,
  Map<String, List<String>> groups,
  bool Function(String text, String query) matches,
) {
  final nameMatches = matches(artist.name, queryInLowerCase);
  final members = groups[artist.name] ?? const <String>[];
  final aliasMatches = members.any(
    (name) => matches(name, queryInLowerCase),
  );
  if (!nameMatches && !aliasMatches) return null;
  if (!nameMatches) return 1;
  return unionSearchRank(artist.name, queryInLowerCase);
}

class UnionSearchResult {
  String query;

  List<Audio> audios = [];
  List<Artist> artists = [];
  List<Album> album = [];

  UnionSearchResult(this.query);

  /// 三类命中按统一相关度穿插后的单个列表，供不分组混排展示。
  List<UnionSearchItem> get mixedItems {
    try {
      return rankUnionSearchItems(
        audios: audios,
        artists: artists,
        albums: album,
        queryInLowerCase: normalizedSearchQuery(query).toLowerCase(),
      );
    } catch (error, trace) {
      log.library.warn(
        'union_search_mixed_failed',
        '综合搜索混排计算失败，按空结果降级',
        error: error,
        stackTrace: trace,
      );
      return const <UnionSearchItem>[];
    }
  }

  static UnionSearchResult search(String query, {SearchScope? scope}) {
    final normalizedQuery = normalizedSearchQuery(query);
    final result = UnionSearchResult(normalizedQuery);

    final queryInLowerCase = normalizedQuery.toLowerCase();
    final library = AudioLibrary.instance;

    if (scope == null || scope == SearchScope.music) {
      final titleMatches = <Audio>[];
      final metadataMatches = <Audio>[];
      for (int i = 0; i < library.audioCollection.length; i++) {
        final audio = library.audioCollection[i];
        final rank = audio.searchMatchRank(queryInLowerCase);
        if (rank == 0) {
          titleMatches.add(audio);
        } else if (rank == 1) {
          metadataMatches.add(audio);
        }
      }
      result.audios
        ..addAll(titleMatches)
        ..addAll(metadataMatches);
    }

    if (scope == null || scope == SearchScope.artist) {
      final groups = groupArtistAliases(AppSettings.instance.artistAliases);
      for (Artist item in library.artistCollection.values) {
        final members = groups[item.name] ?? const <String>[];
        if (_matchesQuery(item.name, queryInLowerCase) ||
            members.any((name) => _matchesQuery(name, queryInLowerCase))) {
          result.artists.add(item);
        }
      }
    }

    if (scope == null || scope == SearchScope.album) {
      for (Album item in library.albumCollection.values) {
        if (_matchesQuery(item.name, queryInLowerCase)) {
          result.album.add(item);
        }
      }
    }

    return result;
  }
}
