import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/online_lyric/models/lyric_candidate.dart';

LyricCandidate _candidate({
  required String id,
  required double score,
  String format = 'lrc',
  String? translationText,
  String? romanizationText,
}) {
  return LyricCandidate(
    id: id,
    source: id.split(':').first,
    sourceId: id.split(':').last,
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    durationSec: 200,
    score: score,
    format: format,
    wordByWord: format != 'lrc',
    text: '[00:00.00]line',
    translationText: translationText,
    romanizationText: romanizationText,
    preview: const ['line'],
    fetchedAtMs: 1,
  );
}

void main() {
  test('候选 JSON 往返保留格式与预览', () {
    final candidate = _candidate(id: 'kugou:abc', score: 88, format: 'krc');

    final decoded = LyricCandidate.fromJson(candidate.toJson());

    expect(decoded, isNotNull);
    expect(decoded!.id, 'kugou:abc');
    expect(decoded.format, 'krc');
    expect(decoded.formatLabel, 'KRC 逐字');
    expect(decoded.preview, ['line']);
    expect(decoded.wordByWord, isTrue);
  });

  test('候选 JSON 往返保留翻译与罗马音文本', () {
    final candidate = _candidate(
      id: 'ne:2',
      score: 86,
      format: 'yrc',
      translationText: '[00:00.000]第一行译文\n[00:03.200]第二行译文',
      romanizationText: '[00:00.000]romaji one\n[00:03.200]romaji two',
    );

    final decoded = LyricCandidate.fromJson(candidate.toJson());

    expect(decoded, isNotNull);
    expect(decoded!.translationText, candidate.translationText);
    expect(decoded.romanizationText, candidate.romanizationText);
  });

  test('缺少 id 或 source 的候选被丢弃', () {
    expect(LyricCandidate.fromJson({'id': 'qq:1'}), isNull);
    expect(LyricCandidate.fromJson({'source': 'qq'}), isNull);
    expect(LyricCandidate.fromJson('broken'), isNull);
  });

  test('记录 JSON 版本不匹配时丢弃', () {
    final recordJson = {
      'version': lyricCandidateRecordVersion + 1,
      'cacheKey': 'key',
      'candidates': <Object>[],
    };

    expect(
      LyricCandidateRecord.fromJson(recordJson, cacheKey: 'key'),
      isNull,
    );
  });

  test('用户选择优先于最佳候选', () {
    final record = LyricCandidateRecord(
      cacheKey: 'key',
      audioPath: 'path',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      durationSec: 200,
      updatedAtMs: 1,
      candidates: [
        _candidate(id: 'qq:1', score: 95),
        _candidate(id: 'ne:2', score: 80),
      ],
      selectedSourceId: 'ne:2',
    );

    expect(record.bestCandidate?.id, 'qq:1');
    expect(record.activeCandidate?.id, 'ne:2');
  });

  test('未选择时使用分数最高的候选', () {
    final record = LyricCandidateRecord(
      cacheKey: 'key',
      audioPath: 'path',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      durationSec: 200,
      updatedAtMs: 1,
      candidates: [
        _candidate(id: 'qq:1', score: 70),
        _candidate(id: 'amll:2', score: 92),
      ],
    );

    expect(record.activeCandidate?.id, 'amll:2');
  });

  test('记录往返保留不使用状态', () {
    final record = LyricCandidateRecord(
      cacheKey: 'key',
      audioPath: 'path',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      durationSec: 200,
      updatedAtMs: 1,
      candidates: [_candidate(id: 'qq:1', score: 90)],
      disabled: true,
    );

    final decoded = LyricCandidateRecord.fromJson(
      record.toJson(),
      cacheKey: 'key',
    );

    expect(decoded, isNotNull);
    expect(decoded!.disabled, isTrue);
    expect(decoded.selectedSourceId, isNull);
    expect(decoded.bestCandidate?.id, 'qq:1');
  });
}
