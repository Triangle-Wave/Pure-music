import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/sacd_source_resolver.dart';

void main() {
  group('SACD 播放源解析', () {
    test('PCM 缓存已就绪时返回 PCM', () async {
      var dsfCalls = 0;
      var pcmCalls = 0;
      var probedPath = '';
      final source = await SacdSourceResolver.resolve(
        trackUid: 'uid',
        preferPcm: true,
        sampleRate: 44100,
        bitDepth: 24,
        loadDsf: () async {
          dsfCalls++;
          return r'D:\cache\track01.dsf';
        },
        isPcmCached: (dsfPath) async {
          probedPath = dsfPath;
          return true;
        },
        loadPcm: () async {
          pcmCalls++;
          return r'D:\cache\track01-44100-24.wav';
        },
      );

      expect(source.path, r'D:\cache\track01-44100-24.wav');
      expect(source.pcmPending, isFalse);
      expect(probedPath, r'D:\cache\track01.dsf');
      expect(dsfCalls, 1);
      expect(pcmCalls, 1);
    });

    test('PCM 缓存未就绪时先返回 DSF 并标记待转换', () async {
      var pcmCalls = 0;
      final source = await SacdSourceResolver.resolve(
        trackUid: 'uid',
        preferPcm: true,
        sampleRate: 44100,
        bitDepth: 24,
        loadDsf: () async => r'D:\cache\track01.dsf',
        isPcmCached: (_) async => false,
        loadPcm: () async {
          pcmCalls++;
          return r'D:\cache\track01-44100-24.wav';
        },
      );

      expect(source.path, r'D:\cache\track01.dsf');
      expect(source.pcmPending, isTrue);
      expect(pcmCalls, 0);
    });

    test('PCM 缓存探测异常时按未就绪处理', () async {
      final source = await SacdSourceResolver.resolve(
        trackUid: 'uid',
        preferPcm: true,
        sampleRate: 44100,
        bitDepth: 24,
        loadDsf: () async => r'D:\cache\track01.dsf',
        isPcmCached: (_) async => throw StateError('probe failed'),
        loadPcm: () async => r'D:\cache\track01-44100-24.wav',
      );

      expect(source.path, r'D:\cache\track01.dsf');
      expect(source.pcmPending, isTrue);
    });

    test('DSF 模式跳过 PCM 探测与转换', () async {
      var probeCalls = 0;
      var pcmCalls = 0;
      final source = await SacdSourceResolver.resolve(
        trackUid: 'uid',
        preferPcm: false,
        sampleRate: 44100,
        bitDepth: 24,
        loadDsf: () async => r'D:\cache\track01.dsf',
        isPcmCached: (_) async {
          probeCalls++;
          return true;
        },
        loadPcm: () async {
          pcmCalls++;
          return r'D:\cache\track01-44100-24.wav';
        },
      );

      expect(source.path, r'D:\cache\track01.dsf');
      expect(source.pcmPending, isFalse);
      expect(probeCalls, 0);
      expect(pcmCalls, 0);
    });

    test('PCM 缓存就绪但转换失败时回退 DSF 且不再补转换', () async {
      final source = await SacdSourceResolver.resolve(
        trackUid: 'uid',
        preferPcm: true,
        sampleRate: 44100,
        bitDepth: 24,
        loadDsf: () async => r'D:\cache\track01.dsf',
        isPcmCached: (_) async => true,
        loadPcm: () => Future<String>.error(StateError('pcm failed')),
      );

      expect(source.path, r'D:\cache\track01.dsf');
      expect(source.pcmPending, isFalse);
    });

    test('DSF 提取失败时抛出原始异常', () async {
      await expectLater(
        SacdSourceResolver.resolve(
          trackUid: 'uid',
          preferPcm: true,
          sampleRate: 44100,
          bitDepth: 24,
          loadDsf: () => Future<String>.error(ArgumentError('dsf failed')),
          isPcmCached: (_) async => true,
          loadPcm: () async => r'D:\cache\track01-44100-24.wav',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
