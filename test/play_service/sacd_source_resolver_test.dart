import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/sacd_source_resolver.dart';

void main() {
  group('SACD 播放源解析', () {
    test('PCM 模式优先返回 PCM 路径', () async {
      var dsfCalls = 0;
      final path = await SacdSourceResolver.resolve(
        trackUid: 'uid',
        preferPcm: true,
        sampleRate: 44100,
        bitDepth: 24,
        loadPcm: () async => r'D:\cache\track01.wav',
        loadDsf: () async {
          dsfCalls++;
          return r'D:\cache\track01.dsf';
        },
      );

      expect(path, r'D:\cache\track01.wav');
      expect(dsfCalls, 0);
    });

    test('PCM 转换失败时回退 DSF', () async {
      var dsfCalls = 0;
      final path = await SacdSourceResolver.resolve(
        trackUid: 'uid',
        preferPcm: true,
        sampleRate: 44100,
        bitDepth: 24,
        loadPcm: () => Future<String>.error(StateError('pcm failed')),
        loadDsf: () async {
          dsfCalls++;
          return r'D:\cache\track01.dsf';
        },
      );

      expect(path, r'D:\cache\track01.dsf');
      expect(dsfCalls, 1);
    });

    test('DSF 模式跳过 PCM', () async {
      var pcmCalls = 0;
      final path = await SacdSourceResolver.resolve(
        trackUid: 'uid',
        preferPcm: false,
        sampleRate: 44100,
        bitDepth: 24,
        loadPcm: () async {
          pcmCalls++;
          return r'D:\cache\track01.wav';
        },
        loadDsf: () async => r'D:\cache\track01.dsf',
      );

      expect(path, r'D:\cache\track01.dsf');
      expect(pcmCalls, 0);
    });

    test('PCM 与 DSF 都失败时抛出 DSF 的原始异常', () async {
      await expectLater(
        SacdSourceResolver.resolve(
          trackUid: 'uid',
          preferPcm: true,
          sampleRate: 44100,
          bitDepth: 24,
          loadPcm: () => Future<String>.error(StateError('pcm failed')),
          loadDsf: () => Future<String>.error(ArgumentError('dsf failed')),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
