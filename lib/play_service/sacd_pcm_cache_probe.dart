import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pure_music/core/log/app_log.dart';

/// 只读探测 DSF 对应的 PCM 缓存是否已经就绪。
///
/// 缓存布局由 Rust 侧生成：WAV 与 `.key` 和 DSF 同目录、同文件名主干，
/// 后缀为 `-<采样率>-<位深>`；键文本以 DSF 路径、长度、修改时间秒数、
/// 采样率与位深开头。这里只比较这一段前缀，转换器版本变化时最多多一次
/// DSF 起播，Rust 会自行重新转换。
///
/// `rdsd2pcm` 无法输出 48kHz 族，请求 48000 时实际缓存为 44100，探测按同一
/// 换算查找。任何 IO 异常都按“未就绪”处理，调用方退回 DSF 播放，不阻断起播。
class SacdPcmCacheProbe {
  const SacdPcmCacheProbe._();

  static Future<bool> isReady({
    required String dsfPath,
    required int sampleRate,
    required int bitDepth,
  }) async {
    try {
      final dsfStat = await File(dsfPath).stat();
      if (dsfStat.type != FileSystemEntityType.file) return false;

      final effectiveRate = sampleRate == 48000 ? 44100 : sampleRate;
      final directory = p.dirname(dsfPath);
      final stem = p.basenameWithoutExtension(dsfPath);
      final suffix = '$effectiveRate-$bitDepth';
      final wavPath = p.join(directory, '$stem-$suffix.wav');
      final keyPath = p.join(directory, '$stem-$suffix.key');

      final wavStat = await File(wavPath).stat();
      if (wavStat.type != FileSystemEntityType.file || wavStat.size <= 44) {
        return false;
      }

      final key = await File(keyPath).readAsString();
      final mtimeSecs = dsfStat.modified.millisecondsSinceEpoch ~/ 1000;
      final prefix =
          '$dsfPath|${dsfStat.size}|$mtimeSecs|$effectiveRate|$bitDepth|';
      return key.startsWith(prefix);
    } catch (err, trace) {
      log.playback.debug(
        'sacd.pcm',
        'PCM 缓存探测失败，按未就绪处理',
        fields: {'dsf': dsfPath},
        error: err,
        stackTrace: trace,
      );
      return false;
    }
  }
}
