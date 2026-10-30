import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

typedef _StreamCreateUrlNative =
    ffi.Uint32 Function(
      ffi.Pointer<ffi.Char>,
      ffi.Uint32,
      ffi.Uint32,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _StreamCreateUrlDart =
    int Function(
      ffi.Pointer<ffi.Char>,
      int,
      int,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );

class BassUrl {
  BassUrl(ffi.DynamicLibrary library)
    : _create = library
          .lookup<ffi.NativeFunction<_StreamCreateUrlNative>>(
            'BASS_StreamCreateURL',
          )
          .asFunction<_StreamCreateUrlDart>();

  final _StreamCreateUrlDart _create;

  int streamCreateUrl(String url, {int offset = 0, int flags = 0}) {
    final urlPtr = url.toNativeUtf8();
    try {
      return _create(urlPtr.cast(), offset, flags, ffi.nullptr, ffi.nullptr);
    } finally {
      malloc.free(urlPtr);
    }
  }
}
