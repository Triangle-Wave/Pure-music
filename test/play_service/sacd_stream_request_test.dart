import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/sacd_stream_request.dart';

const String _iso = r'D:\Music\SACD\album.iso';

String _sacdPath({
  String area = '2ch',
  int track = 1,
  int endMs = 200000,
}) {
  final trackText = track.toString().padLeft(2, '0');
  return '$_iso::track=$trackText::start=0::end=$endMs::sacd=$area';
}

SacdStreamRequest? _build(
  String path, {
  bool preferPcm = true,
  int sampleRate = 44100,
  int bitDepth = 24,
}) {
  return buildSacdStreamRequest(
    path: path,
    preferPcm: preferPcm,
    sampleRate: sampleRate,
    bitDepth: bitDepth,
  );
}

void main() {
  group('buildSacdStreamRequest', () {
    test('2ch 区解析出 ISO 路径、区与轨号', () {
      final request = _build(_sacdPath(track: 3));
      expect(request, isNotNull);
      expect(request!.isoPath, _iso);
      expect(request.area, '2ch');
      expect(request.trackNumber, 3);
    });

    test('mch 区保留区标记', () {
      final request = _build(_sacdPath(area: 'mch'));
      expect(request?.area, 'mch');
    });

    test('PCM 模式带采样率与位深', () {
      final request = _build(_sacdPath(), sampleRate: 96000, bitDepth: 16);
      expect(request?.mode, sacdStreamModePcm);
      expect(request?.sampleRate, 96000);
      expect(request?.bitDepth, 16);
    });

    test('DSD 模式同样透传设置', () {
      final request = _build(
        _sacdPath(),
        preferPcm: false,
        sampleRate: 88200,
        bitDepth: 24,
      );
      expect(request?.mode, sacdStreamModeDsd);
      expect(request?.sampleRate, 88200);
      expect(request?.bitDepth, 24);
    });

    test('普通文件路径返回 null', () {
      expect(_build(r'D:\Music\song.flac'), isNull);
    });

    test('CUE 虚拟轨返回 null', () {
      expect(_build('$_iso::track=01::start=0::end=200000'), isNull);
    });

    test('非法 sacd 标记返回 null', () {
      expect(_build('$_iso::track=01::start=0::end=200000::sacd=6ch'), isNull);
      expect(_build('$_iso::track=01::start=0::end=200000::sacd='), isNull);
    });

    test('缺少轨号时返回 null', () {
      expect(_build('$_iso::track=x::start=0::end=200000::sacd=2ch'), isNull);
    });
  });
}
