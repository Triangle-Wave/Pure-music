import 'package:pure_music/core/log/app_log.dart';

/// SACD 轨道的播放源：解析出的缓存路径，以及是否需要补一次后台 PCM 转换。
class SacdPlaybackSource {
  const SacdPlaybackSource(this.path, {required this.pcmPending});

  final String path;

  /// 为 true 时 [path] 是 DSF 缓存，PCM 缓存尚未就绪，调用方应安排后台转换。
  final bool pcmPending;
}

/// SACD 播放源解析策略。
///
/// PCM 模式下先确保 DSF 缓存可用：PCM 缓存已经就绪时返回 PCM，否则立即
/// 返回 DSF 供起播，并由调用方在后台把该轨转换为 PCM。DSF 模式只提取 DSF。
class SacdSourceResolver {
  const SacdSourceResolver._();

  /// 解析 [trackUid] 的播放源。
  ///
  /// [isPcmCached] 只读探测给定 DSF 路径对应的 PCM 缓存，探测异常由实现方
  /// 按未就绪处理。[loadPcm] 只在 PCM 缓存已就绪时调用，失败记录告警并
  /// 回退到 DSF，不再安排后台重试。DSF 提取失败时记录带轨道标识的错误并
  /// 重新抛出原始异常。
  static Future<SacdPlaybackSource> resolve({
    required String trackUid,
    required bool preferPcm,
    required int sampleRate,
    required int bitDepth,
    required Future<String> Function() loadDsf,
    required Future<bool> Function(String dsfPath) isPcmCached,
    required Future<String> Function() loadPcm,
  }) async {
    final dsfPath = await _loadDsf(
      trackUid: trackUid,
      preferPcm: preferPcm,
      loadDsf: loadDsf,
    );
    if (!preferPcm) {
      return SacdPlaybackSource(dsfPath, pcmPending: false);
    }

    final pcmReady = await _isPcmCached(
      trackUid: trackUid,
      dsfPath: dsfPath,
      isPcmCached: isPcmCached,
    );
    if (!pcmReady) {
      log.playback.debug(
        'sacd.pcm',
        'PCM 缓存未就绪，先以 DSF 起播',
        fields: {
          'uid': trackUid,
          'sampleRate': sampleRate,
          'bitDepth': bitDepth,
        },
      );
      return SacdPlaybackSource(dsfPath, pcmPending: true);
    }

    try {
      return SacdPlaybackSource(await loadPcm(), pcmPending: false);
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
      return SacdPlaybackSource(dsfPath, pcmPending: false);
    }
  }

  static Future<String> _loadDsf({
    required String trackUid,
    required bool preferPcm,
    required Future<String> Function() loadDsf,
  }) async {
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

  /// PCM 缓存探测自身出错时按未就绪处理，避免探测故障阻断起播。
  static Future<bool> _isPcmCached({
    required String trackUid,
    required String dsfPath,
    required Future<bool> Function(String dsfPath) isPcmCached,
  }) async {
    try {
      return await isPcmCached(dsfPath);
    } catch (err, trace) {
      log.playback.debug(
        'sacd.pcm',
        'PCM 缓存探测异常，按未就绪处理',
        fields: {'uid': trackUid, 'dsf': dsfPath},
        error: err,
        stackTrace: trace,
      );
      return false;
    }
  }
}
