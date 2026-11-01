import 'package:flutter/material.dart';
import 'package:pure_music/library/audio_library.dart';

/// 列表数据只有采样率、位深与码率：采样率高于 CD 的 44.1 kHz 即为 Hi-Res，
/// 44.1 kHz 则需要位深不低于 24 bit；DSD 本身即高解析，一律算 Hi-Res。
bool isHiResAudio(Audio audio) {
  if (isDsdAudio(audio)) return true;
  final rate = audio.sampleRate;
  if (rate == null) return false;
  if (rate > 44100) return true;
  final depth = audio.bitDepth;
  return rate == 44100 && depth != null && depth >= 24;
}

/// DSD 判定：SACD 虚拟轨、DSF/DFF 来源、DSD 采样率或 DSD 源文件路径
/// 任一命中即为 DSD；`by` 记录标签来源，SACD ISO 解析出的轨道标记为 sacd。
bool isDsdAudio(Audio audio) {
  if (audio.isSacdTrack) return true;

  final by = audio.by?.toLowerCase();
  if (by == 'dsf' || by == 'dff' || by == 'sacd') return true;

  final sampleRate = audio.sampleRate;
  if (sampleRate != null && sampleRate >= 2822400) return true;

  final lowerPath = audio.path.toLowerCase();
  if (lowerPath.contains('::sacd=')) return true;

  // CUE/SACD 虚拟轨路径带 `::track=` 等段信息，取合成段之前的源文件部分。
  final separator = lowerPath.indexOf('::');
  final sourcePath = separator < 0
      ? lowerPath
      : lowerPath.substring(0, separator);
  return sourcePath.endsWith('.dsf') || sourcePath.endsWith('.dff');
}

/// 窄宽列表里徽章组可占用的最大宽度；超出时整体等比缩小，剩余宽度留给标题。
const double compactBadgeGroupMaxWidth = 56.0;

/// Hi-Res 金色小标签：高度 14，宽度按原图 35×15 比例。
class HiResBadge extends StatelessWidget {
  const HiResBadge({super.key});

  static const double height = 14.0;
  static const double width = height * 35 / 15;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Hi-Res',
      image: true,
      child: Image.asset(
        'assets/images/hr_logo2.png',
        width: width,
        height: height,
        filterQuality: FilterQuality.medium,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => const SizedBox(width: width, height: height),
      ),
    );
  }
}

/// DSD 白色小标签：高度 14，宽度按原图 48×24 比例。
class DsdBadge extends StatelessWidget {
  const DsdBadge({super.key});

  static const double height = 14.0;
  static const double width = 28.0;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'DSD',
      image: true,
      child: Image.asset(
        'assets/images/dsd_logo.png',
        width: width,
        height: height,
        filterQuality: FilterQuality.medium,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => const SizedBox(width: width, height: height),
      ),
    );
  }
}
