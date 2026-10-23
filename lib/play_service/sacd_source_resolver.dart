import 'package:pure_music/core/log/app_log.dart';

/// SACD 播放源解析策略。
///
/// 默认把轨道转换为 PCM WAV；转换失败时记录告警并回退到 DSF 提取，
/// 转换链路异常时轨道仍然可播。
class SacdSourceResolver {
  const SacdSourceResolver._();

  /// 按 [preferPcm] 选择播放源路径。
  ///
  /// [loadPcm] 与 [loadDsf] 由调用方提供，缓存与并发去重由调用方在更外层处理。
  /// PCM 失败时回退；DSF 也失败时先记录带轨道标识的错误，再重新抛出原始异常。
  static Future<String> resolve({
    required String trackUid,
    required bool preferPcm,
    required int sampleRate,
    required int bitDepth,
    required Future<String> Function() loadPcm,
    required Future<String> Function() loadDsf,
  }) async {
    if (preferPcm) {
      try {
        return await loadPcm();
      } catch (err, trace) {
        log.playback.warn(
          'sacd.pcm',
          'SACD PCM 转换失败，回退 DSF',
          fields: {
            'uid': trackUid,
            'sampleRate': sampleRate,
            'bitDepth': bitDepth,
          },
          error: err,
          stackTrace: trace,
        );
      }
    }
    try {
      return await loadDsf();
    } catch (err, trace) {
      log.playback.error(
        'sacd.source',
        'SACD 轨道提取失败',
        fields: {'uid': trackUid, 'mode': preferPcm ? 'pcm' : 'dsf'},
        error: err,
        stackTrace: trace,
      );
      Error.throwWithStackTrace(err, trace);
    }
  }
}
