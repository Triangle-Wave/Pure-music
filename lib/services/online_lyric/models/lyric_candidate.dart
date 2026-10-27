// 一首歌的在线歌词候选与用户选择。
//
// 缓存文件位于 `<数据根>/cache/lyrics/<sha1>.json`，键由标题、艺术家、专辑与
// 时长（按 5 秒取整）归一化后计算。候选保存来源、曲目信息、格式、原始歌词
// 文本、翻译与罗马音文本、前几行预览与匹配分数；用户选择单独保存在同一份
// 记录里。

/// 候选预览保留的行数。
const int lyricCandidatePreviewLineCount = 3;

/// 一首歌最多保留的候选数量，超出时丢弃分数最低的候选。
const int lyricCandidateMaxCount = 16;

/// 候选记录的 JSON 结构版本；结构变化时旧文件会被丢弃并重新获取。
const int lyricCandidateRecordVersion = 2;

/// 候选匹配分数的最小值；低于该值的搜索结果不进入候选列表。
const double lyricCandidateMinScore = 40.0;

/// 一条在线歌词候选。
class LyricCandidate {
  const LyricCandidate({
    required this.id,
    required this.source,
    required this.sourceId,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSec,
    required this.score,
    required this.format,
    required this.wordByWord,
    required this.text,
    required this.fetchedAtMs,
    this.translationText,
    this.romanizationText,
    this.preview = const [],
  });

  /// 稳定主键，格式 `<source>:<sourceId>`。
  final String id;

  /// 来源标识：`qq`、`kugou`、`ne`、`amll`。
  final String source;

  /// 来源内的歌曲标识。
  final String sourceId;

  final String title;
  final String artist;
  final String album;

  /// 候选时长，单位秒；未知时为 0。
  final int durationSec;

  /// 与当前曲目的匹配分数。
  final double score;

  /// 歌词格式：`lrc`、`qrc`、`krc`、`yrc`、`ttml`。
  final String format;

  final bool wordByWord;

  /// 原始歌词文本，用于选中后离线重建歌词。
  final String text;

  /// 每行的翻译文本，每行形如 `[mm:ss.mmm]翻译`；重建歌词时按时间戳补回。
  final String? translationText;

  /// 每行的罗马音文本，每行形如 `[mm:ss.mmm]罗马音`；重建歌词时按时间戳补回。
  final String? romanizationText;

  /// 前几行歌词，供选择界面预览。
  final List<String> preview;

  /// 取回候选的时间，毫秒时间戳。
  final int fetchedAtMs;

  bool get hasText => text.trim().isNotEmpty;

  String get formatLabel {
    return switch (format) {
      'qrc' => 'QRC 逐字',
      'krc' => 'KRC 逐字',
      'yrc' => 'YRC 逐字',
      'ttml' => 'TTML',
      'lrc' => 'LRC 逐行',
      _ => wordByWord ? '逐字' : '逐行',
    };
  }

  String get sourceLabel {
    return switch (source) {
      'qq' => 'QQ',
      'kugou' => '酷狗',
      'ne' => '网易',
      'amll' => 'AMLL',
      _ => source,
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'source': source,
      'sourceId': sourceId,
      'title': title,
      'artist': artist,
      'album': album,
      'durationSec': durationSec,
      'score': score,
      'format': format,
      'wordByWord': wordByWord,
      'text': text,
      'translationText': translationText,
      'romanizationText': romanizationText,
      'preview': preview,
      'fetchedAtMs': fetchedAtMs,
    };
  }

  static LyricCandidate? fromJson(Object? json) {
    if (json is! Map<Object?, Object?>) return null;
    final id = _asText(json['id']);
    final source = _asText(json['source']);
    final sourceId = _asText(json['sourceId']);
    if (id.isEmpty || source.isEmpty) return null;
    final rawPreview = json['preview'];
    final preview = rawPreview is List
        ? rawPreview
              .whereType<String>()
              .where((line) => line.trim().isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    return LyricCandidate(
      id: id,
      source: source,
      sourceId: sourceId,
      title: _asText(json['title']),
      artist: _asText(json['artist']),
      album: _asText(json['album']),
      durationSec: _asInt(json['durationSec']),
      score: _asDouble(json['score']),
      format: _asText(json['format']),
      wordByWord: json['wordByWord'] == true,
      text: _asText(json['text']),
      translationText: _asOptionalText(json['translationText']),
      romanizationText: _asOptionalText(json['romanizationText']),
      preview: preview,
      fetchedAtMs: _asInt(json['fetchedAtMs']),
    );
  }

  LyricCandidate copyWith({
    String? text,
    String? translationText,
    String? romanizationText,
    List<String>? preview,
  }) {
    return LyricCandidate(
      id: id,
      source: source,
      sourceId: sourceId,
      title: title,
      artist: artist,
      album: album,
      durationSec: durationSec,
      score: score,
      format: format,
      wordByWord: wordByWord,
      text: text ?? this.text,
      translationText: translationText ?? this.translationText,
      romanizationText: romanizationText ?? this.romanizationText,
      preview: preview ?? this.preview,
      fetchedAtMs: fetchedAtMs,
    );
  }
}

/// 一首歌的候选记录与用户选择。
class LyricCandidateRecord {
  const LyricCandidateRecord({
    required this.cacheKey,
    required this.audioPath,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSec,
    required this.updatedAtMs,
    required this.candidates,
    this.selectedSourceId,
    this.disabled = false,
  });

  final String cacheKey;
  final String audioPath;
  final String title;
  final String artist;
  final String album;
  final int durationSec;
  final int updatedAtMs;
  final List<LyricCandidate> candidates;

  /// 用户选中的候选 id；null 表示自动选择最佳候选。
  final String? selectedSourceId;

  /// 用户选择「不使用」时置为 true，此时不显示在线歌词、不请求在线源。
  final bool disabled;

  LyricCandidate? get bestCandidate {
    if (candidates.isEmpty) return null;
    final sorted = [...candidates]
      ..sort((a, b) => b.score.compareTo(a.score));
    return sorted.first;
  }

  LyricCandidate? get selectedCandidate {
    final id = selectedSourceId;
    if (id == null) return null;
    for (final candidate in candidates) {
      if (candidate.id == id) return candidate;
    }
    return null;
  }

  /// 实际要显示的候选：用户选择优先，否则最佳候选。
  LyricCandidate? get activeCandidate => selectedCandidate ?? bestCandidate;

  bool get hasCandidates => candidates.isNotEmpty;

  LyricCandidateRecord copyWith({
    List<LyricCandidate>? candidates,
    int? updatedAtMs,
    String? selectedSourceId,
    bool clearSelectedSourceId = false,
    bool? disabled,
  }) {
    return LyricCandidateRecord(
      cacheKey: cacheKey,
      audioPath: audioPath,
      title: title,
      artist: artist,
      album: album,
      durationSec: durationSec,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      candidates: candidates ?? this.candidates,
      selectedSourceId: clearSelectedSourceId
          ? null
          : (selectedSourceId ?? this.selectedSourceId),
      disabled: disabled ?? this.disabled,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': lyricCandidateRecordVersion,
      'cacheKey': cacheKey,
      'audioPath': audioPath,
      'title': title,
      'artist': artist,
      'album': album,
      'durationSec': durationSec,
      'updatedAtMs': updatedAtMs,
      'selectedSourceId': selectedSourceId,
      'disabled': disabled,
      'candidates': candidates.map((candidate) => candidate.toJson()).toList(),
    };
  }

  static LyricCandidateRecord? fromJson(Object? json, {required String cacheKey}) {
    if (json is! Map<Object?, Object?>) return null;
    if (_asInt(json['version']) != lyricCandidateRecordVersion) return null;
    final storedKey = _asText(json['cacheKey']);
    if (storedKey.isNotEmpty && storedKey != cacheKey) return null;
    final rawCandidates = json['candidates'];
    final candidates = <LyricCandidate>[];
    if (rawCandidates is List) {
      for (final raw in rawCandidates) {
        final candidate = LyricCandidate.fromJson(raw);
        if (candidate != null) candidates.add(candidate);
      }
    }
    final selected = _asText(json['selectedSourceId']);
    return LyricCandidateRecord(
      cacheKey: cacheKey,
      audioPath: _asText(json['audioPath']),
      title: _asText(json['title']),
      artist: _asText(json['artist']),
      album: _asText(json['album']),
      durationSec: _asInt(json['durationSec']),
      updatedAtMs: _asInt(json['updatedAtMs']),
      candidates: candidates,
      selectedSourceId: selected.isEmpty ? null : selected,
      disabled: json['disabled'] == true,
    );
  }
}

String _asText(Object? value) => value is String ? value : '';

String? _asOptionalText(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim()) ?? 0;
  return 0;
}
