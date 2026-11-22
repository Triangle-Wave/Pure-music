import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/bass/bass.dart';
import 'package:pure_music/native/bass/bass_player.dart';

ExternalStreamSpec _spec({
  int user = 0x1234,
  int flags = 0,
  void Function(int user)? discard,
}) {
  return ExternalStreamSpec(
    user: user,
    closeProc: 0x1,
    lengthProc: 0x2,
    readProc: 0x3,
    seekProc: 0x4,
    flags: flags,
    discard: discard,
  );
}

void main() {
  group('ExternalStreamSpec', () {
    test('保留 user 与四个回调地址', () {
      final spec = _spec(user: 0x7f00, flags: BASS_STREAM_DECODE);
      expect(spec.user, 0x7f00);
      expect(spec.closeProc, 0x1);
      expect(spec.lengthProc, 0x2);
      expect(spec.readProc, 0x3);
      expect(spec.seekProc, 0x4);
      expect(spec.flags, BASS_STREAM_DECODE);
    });

    test('未指定 flags 与 discard 时默认为 0 与空', () {
      final spec = _spec();
      expect(spec.flags, 0);
      expect(spec.discard, isNull);
    });
  });

  group('外部流标志', () {
    test('去掉 Unicode 与异步文件标志，并保留浮点采样与解码标志', () {
      final flags = externalStreamFlags(
        BASS_UNICODE | BASS_ASYNCFILE | BASS_SAMPLE_FLOAT | BASS_STREAM_DECODE,
      );
      expect(flags & BASS_UNICODE, 0);
      expect(flags & BASS_ASYNCFILE, 0);
      expect(flags & BASS_SAMPLE_FLOAT, BASS_SAMPLE_FLOAT);
      expect(flags & BASS_STREAM_DECODE, BASS_STREAM_DECODE);
    });

    test('调用方未带浮点采样时补上', () {
      expect(
        externalStreamFlags(BASS_STREAM_DECODE) & BASS_SAMPLE_FLOAT,
        BASS_SAMPLE_FLOAT,
      );
      expect(externalStreamFlags(0), BASS_SAMPLE_FLOAT);
    });

    test('可播放流只保留浮点采样', () {
      final flags = externalStreamFlags(
        BASS_UNICODE | BASS_SAMPLE_FLOAT | BASS_ASYNCFILE,
      );
      expect(flags, BASS_SAMPLE_FLOAT);
      expect(flags & BASS_STREAM_DECODE, 0);
    });

    test('额外标志原样保留', () {
      const extra = 0x1000;
      expect(externalStreamFlags(BASS_STREAM_DECODE | extra) & extra, extra);
    });
  });

  group('外部流失败收尾', () {
    test('调用 discard 释放会话并返回 0', () {
      final discarded = <int>[];
      final spec = _spec(user: 0x1234, discard: discarded.add);
      expect(discardExternalStream(spec), 0);
      expect(discarded, <int>[0x1234]);
    });

    test('释放回调抛异常时不向外冒泡', () {
      final spec = _spec(
        discard: (user) => throw StateError('discard failed: $user'),
      );
      expect(discardExternalStream(spec), 0);
    });

    test('没有会话或没有释放回调时返回 0', () {
      expect(discardExternalStream(null), 0);
      expect(discardExternalStream(_spec()), 0);
    });
  });

  group('BASS_FILEPROCS 布局', () {
    test('四字段按 close、length、read、seek 顺序紧排', () {
      expect(sizeOf<BassFileProcs>(), 4 * sizeOf<IntPtr>());
      final procs = calloc<BassFileProcs>();
      try {
        const closeAddress = 0x11;
        const lengthAddress = 0x22;
        const readAddress = 0x33;
        const seekAddress = 0x44;
        procs.ref
          ..close =
              Pointer<NativeFunction<Void Function(Pointer<Void>)>>.fromAddress(
                closeAddress,
              )
          ..length =
              Pointer<NativeFunction<Uint64 Function(Pointer<Void>)>>.fromAddress(
                lengthAddress,
              )
          ..read = Pointer<
            NativeFunction<Uint32 Function(Pointer<Void>, Uint32, Pointer<Void>)>
          >.fromAddress(readAddress)
          ..seek =
              Pointer<NativeFunction<Int32 Function(Uint64, Pointer<Void>)>>.fromAddress(
                seekAddress,
              );
        final words = procs.cast<IntPtr>();
        expect(words[0], closeAddress);
        expect(words[1], lengthAddress);
        expect(words[2], readAddress);
        expect(words[3], seekAddress);
      } finally {
        calloc.free(procs);
      }
    });

    test('文件系统常量与 bass.h 一致', () {
      expect(STREAMFILE_NOBUFFER, 0);
      expect(STREAMFILE_BUFFER, 1);
    });
  });
}
