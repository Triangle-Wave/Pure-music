import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/services/online_lyric/lyric_candidate_cache.dart';
import 'package:pure_music/services/online_lyric/models/lyric_candidate.dart';

Audio _audio({
  String title = 'Test Song',
  String artist = 'Test Artist',
  String album = 'Test Album',
  int duration = 240,
  String path = r'C:\Music\test.mp3',
}) {
  return Audio(
    title,
    artist,
    album,
    null,
    1,
    duration,
    null,
    null,
    path,
    0,
    0,
    null,
  );
}

LyricCandidateRecord _record(Audio audio, {String id = 'qq:100'}) {
  return LyricCandidateRecord(
    cacheKey: lyricCandidateCacheKey(audio),
    audioPath: audio.path,
    title: audio.title,
    artist: audio.artist,
    album: audio.album,
    durationSec: audio.duration,
    updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    candidates: [
      LyricCandidate(
        id: id,
        source: 'qq',
        sourceId: id.split(':').last,
        title: 'Test Song',
        artist: 'Test Artist',
        album: 'Test Album',
        durationSec: 240,
        score: 96,
        format: 'lrc',
        wordByWord: false,
        text: '[00:00.00]first line\n[00:03.00]second line',
        preview: const ['first line', 'second line'],
        fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    ],
  );
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lyric_candidate_cache_test_');
  });

  tearDown(() async {
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // 测试目录清理失败不影响断言结果。
    }
  });

  test('缓存键抹平大小写、括号说明与版本词', () {
    final plain = _audio();
    final variant = _audio(title: 'test song (Live)', artist: 'TEST ARTIST');

    expect(lyricCandidateCacheKey(plain), lyricCandidateCacheKey(variant));
  });

  test('缓存键容忍 5 秒内的时长偏差', () {
    final base = _audio(duration: 240);
    final near = _audio(duration: 242);
    final far = _audio(duration: 260);

    expect(lyricCandidateCacheKey(base), lyricCandidateCacheKey(near));
    expect(lyricCandidateCacheKey(base), isNot(lyricCandidateCacheKey(far)));
  });

  test('未知曲目按音频路径区分', () {
    final first = _audio(
      title: '',
      artist: '',
      album: '',
      path: r'C:\Music\a.mp3',
    );
    final second = _audio(
      title: '',
      artist: '',
      album: '',
      path: r'C:\Music\b.mp3',
    );

    expect(lyricCandidateCacheKey(first), isNot(lyricCandidateCacheKey(second)));
  });

  test('候选记录写入磁盘后可被新实例读回', () async {
    final audio = _audio();
    final cache = LyricCandidateCache(rootDirectory: () async => root);
    await cache.write(audio, _record(audio));

    final reloaded = LyricCandidateCache(
      rootDirectory: () async => root,
    ).read(audio);

    final record = await reloaded;
    expect(record, isNotNull);
    expect(record!.candidates.single.id, 'qq:100');
    expect(record.candidates.single.text, contains('first line'));
    expect(record.candidates.single.preview, hasLength(2));
  });

  test('损坏的缓存文件被删除并视为未命中', () async {
    final audio = _audio();
    final key = lyricCandidateCacheKey(audio);
    final directory = Directory(p.join(root.path, 'lyrics'));
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, '$key.json'));
    await file.writeAsString('{not valid json');

    final record = await LyricCandidateCache(
      rootDirectory: () async => root,
    ).read(audio);

    expect(record, isNull);
    expect(await file.exists(), isFalse);
  });

  test('超过有效期后删除并重新获取', () async {
    final audio = _audio();
    final now = DateTime.now();
    final writer = LyricCandidateCache(
      rootDirectory: () async => root,
      clock: () => now,
    );
    await writer.write(audio, _record(audio));

    final reader = LyricCandidateCache(
      rootDirectory: () async => root,
      clock: () => now.add(lyricCandidateCacheTtl + const Duration(days: 1)),
    );

    expect(await reader.read(audio), isNull);
  });

  test('用户选择与不使用状态持久化', () async {
    final audio = _audio();
    final cache = LyricCandidateCache(rootDirectory: () async => root);
    await cache.write(audio, _record(audio));

    final selected = await cache.updateSelection(
      audio,
      disabled: false,
      selectedSourceId: 'qq:100',
    );
    expect(selected.selectedSourceId, 'qq:100');
    expect(selected.disabled, isFalse);

    final disabled = await cache.updateSelection(audio, disabled: true);
    expect(disabled.disabled, isTrue);
    expect(disabled.selectedSourceId, isNull);

    final reloaded = await LyricCandidateCache(
      rootDirectory: () async => root,
    ).read(audio);
    expect(reloaded?.disabled, isTrue);
  });

  test('刷新候选时保留仍然存在的用户选择', () async {
    final audio = _audio();
    final cache = LyricCandidateCache(rootDirectory: () async => root);
    await cache.write(audio, _record(audio));
    await cache.updateSelection(
      audio,
      disabled: false,
      selectedSourceId: 'qq:100',
    );

    final replaced = await cache.replaceCandidates(
      audio,
      _record(audio).candidates,
    );

    expect(replaced.selectedSourceId, 'qq:100');
  });

  test('没有候选时也能保存「不使用」状态', () async {
    final audio = _audio();

    final updated = await LyricCandidateCache(
      rootDirectory: () async => root,
    ).updateSelection(audio, disabled: true);

    expect(updated.disabled, isTrue);
    expect(updated.candidates, isEmpty);
    final reloaded = await LyricCandidateCache(
      rootDirectory: () async => root,
    ).read(audio);
    expect(reloaded?.disabled, isTrue);
  });

  test('清理全部缓存后目录为空', () async {
    final first = _audio(path: r'C:\Music\a.mp3');
    final second = _audio(title: 'Other', path: r'C:\Music\b.mp3');
    final cache = LyricCandidateCache(rootDirectory: () async => root);
    await cache.write(first, _record(first));
    await cache.write(second, _record(second, id: 'qq:200'));

    final removed = await cache.clearAll();

    expect(removed, 2);
    expect((await cache.stats()).fileCount, 0);
    expect(await cache.read(first), isNull);
  });
}
