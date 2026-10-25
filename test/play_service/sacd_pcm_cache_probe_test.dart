import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/play_service/sacd_pcm_cache_probe.dart';

void main() {
  group('SACD PCM 缓存探测', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sacd_pcm_probe_');
    });

    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    Future<String> writeReadyCache({
      int sampleRate = 44100,
      int bitDepth = 24,
    }) async {
      final dsf = File(p.join(dir.path, '2ch-01.dsf'));
      await dsf.writeAsBytes(List<int>.filled(128, 0));
      await dsf.setLastModified(
        DateTime.now().subtract(const Duration(seconds: 30)),
      );
      final stat = await dsf.stat();
      final stem = p.basenameWithoutExtension(dsf.path);
      final mtimeSecs = stat.modified.millisecondsSinceEpoch ~/ 1000;
      await File(p.join(dir.path, '$stem-$sampleRate-$bitDepth.key'))
          .writeAsString(
            '${dsf.path}|${stat.size}|$mtimeSecs|$sampleRate|$bitDepth|'
            'rdsd2pcm-test',
          );
      await File(
        p.join(dir.path, '$stem-$sampleRate-$bitDepth.wav'),
      ).writeAsBytes(List<int>.filled(128, 0));
      return dsf.path;
    }

    test('WAV 与键都完整时判定为就绪', () async {
      final dsfPath = await writeReadyCache();

      expect(
        await SacdPcmCacheProbe.isReady(
          dsfPath: dsfPath,
          sampleRate: 44100,
          bitDepth: 24,
        ),
        isTrue,
      );
    });

    test('请求 48000 时按 44100 缓存查找', () async {
      final dsfPath = await writeReadyCache();

      expect(
        await SacdPcmCacheProbe.isReady(
          dsfPath: dsfPath,
          sampleRate: 48000,
          bitDepth: 24,
        ),
        isTrue,
      );
    });

    test('缺少 WAV 时判定为未就绪', () async {
      final dsfPath = await writeReadyCache();
      final wav = File(p.join(dir.path, '2ch-01-44100-24.wav'));
      await wav.delete();

      expect(
        await SacdPcmCacheProbe.isReady(
          dsfPath: dsfPath,
          sampleRate: 44100,
          bitDepth: 24,
        ),
        isFalse,
      );
    });

    test('键内容与 DSF 不对应时判定为未就绪', () async {
      final dsfPath = await writeReadyCache();
      await File(p.join(dir.path, '2ch-01-44100-24.key'))
          .writeAsString('stale-key');

      expect(
        await SacdPcmCacheProbe.isReady(
          dsfPath: dsfPath,
          sampleRate: 44100,
          bitDepth: 24,
        ),
        isFalse,
      );
    });

    test('DSF 不存在时判定为未就绪', () async {
      expect(
        await SacdPcmCacheProbe.isReady(
          dsfPath: p.join(dir.path, '2ch-02.dsf'),
          sampleRate: 44100,
          bitDepth: 24,
        ),
        isFalse,
      );
    });

    test('WAV 只有头部时判定为未就绪', () async {
      final dsfPath = await writeReadyCache();
      await File(p.join(dir.path, '2ch-01-44100-24.wav')).writeAsBytes(
        List<int>.filled(44, 0),
      );

      expect(
        await SacdPcmCacheProbe.isReady(
          dsfPath: dsfPath,
          sampleRate: 44100,
          bitDepth: 24,
        ),
        isFalse,
      );
    });
  });
}
