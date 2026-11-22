import 'package:pure_music/library/cue_segment_path.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/native/rust/api/sacd.dart' as rust_sacd;

/// SACD 直播模式的取值：解码到 PCM 输出。
const String sacdStreamModePcm = 'pcm';

/// SACD 直播模式的取值：交给 BASS 的 DSD 解码。
const String sacdStreamModeDsd = 'dsd';

/// Rust 建流会话所需的参数。
class SacdStreamRequest {
  const SacdStreamRequest({
    required this.isoPath,
    required this.area,
    required this.trackNumber,
    required this.mode,
    required this.sampleRate,
    required this.bitDepth,
  });

  /// ISO 镜像路径。
  final String isoPath;

  /// SACD 区标记，`2ch` 或 `mch`。
  final String area;

  /// 区内轨号，从 1 开始。
  final int trackNumber;

  /// [sacdStreamModePcm] 或 [sacdStreamModeDsd]。
  final String mode;

  /// PCM 模式使用的输出采样率；DSD 模式不使用。
  final int sampleRate;

  /// PCM 模式使用的输出位深；DSD 模式不使用。
  final int bitDepth;
}

/// 路径是否为 SACD 虚拟轨；只解析字符串，不读播放设置与磁盘。
bool isSacdStreamPath(String path) {
  final segment = parseCueSegmentPath(path);
  return segment != null && segment.isSacd;
}

/// 由虚拟轨路径与播放设置生成建流参数。
///
/// 非 SACD 路径（普通文件、CUE 虚拟轨、非法 `sacd=` 标记）返回 null。
SacdStreamRequest? buildSacdStreamRequest({
  required String path,
  required bool preferPcm,
  required int sampleRate,
  required int bitDepth,
}) {
  final segment = parseCueSegmentPath(path);
  final area = segment?.sacdArea;
  if (segment == null || area == null) return null;
  return SacdStreamRequest(
    isoPath: segment.sourcePath,
    area: area,
    trackNumber: segment.trackNumber,
    mode: preferPcm ? sacdStreamModePcm : sacdStreamModeDsd,
    sampleRate: sampleRate,
    bitDepth: bitDepth,
  );
}

/// Dart int 在 VM 上是带符号 64 位；x64 用户态地址远低于该上限。
final BigInt _maxIntAddress = BigInt.parse('9223372036854775807');

/// 地址字段转 int；超出范围时抛出可读错误，不做静默截断。
int _toAddressInt(BigInt value, String field) {
  if (value.isNegative || value > _maxIntAddress) {
    throw StateError('SACD 流地址超出 int 范围：$field=$value');
  }
  return value.toInt();
}

/// 把 Rust 会话描述转换为 [ExternalStreamSpec]。
///
/// FRB 2.12 把 Rust usize 映射为 Dart BigInt，而 BASS 与 `Pointer.fromAddress`
/// 只接受 int，转换集中在此处完成；[discard] 收到与 [ExternalStreamSpec.user]
/// 相同的 int 值，由调用方换回 BigInt 交给 Rust。
ExternalStreamSpec buildSacdExternalStreamSpec(
  rust_sacd.SacdStreamDescriptor descriptor,
  void Function(int user) discard,
) {
  return ExternalStreamSpec(
    user: _toAddressInt(descriptor.user, 'user'),
    closeProc: _toAddressInt(descriptor.procs.close, 'procs.close'),
    lengthProc: _toAddressInt(descriptor.procs.length, 'procs.length'),
    readProc: _toAddressInt(descriptor.procs.read, 'procs.read'),
    seekProc: _toAddressInt(descriptor.procs.seek, 'procs.seek'),
    discard: discard,
  );
}
