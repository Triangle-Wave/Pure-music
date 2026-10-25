import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pure_music/remote/remote_client.dart';
import 'package:pure_music/remote/remote_source.dart';

final class _NetResource extends ffi.Struct {
  @ffi.Uint32()
  external int dwScope;

  @ffi.Uint32()
  external int dwType;

  @ffi.Uint32()
  external int dwDisplayType;

  @ffi.Uint32()
  external int dwUsage;

  external ffi.Pointer<ffi.Uint16> lpLocalName;
  external ffi.Pointer<ffi.Uint16> lpRemoteName;
  external ffi.Pointer<ffi.Uint16> lpComment;
  external ffi.Pointer<ffi.Uint16> lpProvider;
}

typedef _WNetAddConnection2Native =
    ffi.Uint32 Function(
      ffi.Pointer<_NetResource>,
      ffi.Pointer<ffi.Uint16>,
      ffi.Pointer<ffi.Uint16>,
      ffi.Uint32,
    );
typedef _WNetAddConnection2Dart =
    int Function(
      ffi.Pointer<_NetResource>,
      ffi.Pointer<ffi.Uint16>,
      ffi.Pointer<ffi.Uint16>,
      int,
    );

const int _connectTemporary = 0x00000004;
const Duration _connectTimeout = Duration(seconds: 30);

void _connectBlocking(String remote, String username, String password) {
  final addConnection = ffi.DynamicLibrary.open('mpr.dll')
      .lookup<ffi.NativeFunction<_WNetAddConnection2Native>>(
        'WNetAddConnection2W',
      )
      .asFunction<_WNetAddConnection2Dart>();
  final remotePtr = remote.toNativeUtf16().cast<ffi.Uint16>();
  final userPtr = username.isEmpty
      ? ffi.nullptr.cast<ffi.Uint16>()
      : username.toNativeUtf16().cast<ffi.Uint16>();
  final passwordPtr = password.isEmpty
      ? ffi.nullptr.cast<ffi.Uint16>()
      : password.toNativeUtf16().cast<ffi.Uint16>();
  final resource = calloc<_NetResource>(1);
  try {
    resource.ref
      ..dwScope = 0
      ..dwType = 1
      ..dwDisplayType = 0
      ..dwUsage = 0
      ..lpLocalName = ffi.nullptr
      ..lpRemoteName = remotePtr
      ..lpComment = ffi.nullptr
      ..lpProvider = ffi.nullptr;
    final result = addConnection(
      resource,
      passwordPtr,
      userPtr,
      _connectTemporary,
    );
    if (result != 0) {
      throw StateError(_connectErrorMessage(result));
    }
  } finally {
    calloc.free(resource);
    malloc.free(remotePtr);
    if (userPtr != ffi.nullptr) malloc.free(userPtr);
    if (passwordPtr != ffi.nullptr) malloc.free(passwordPtr);
  }
}

String _connectErrorMessage(int code) {
  return switch (code) {
    5 => '访问共享文件夹被拒绝，请检查账号权限（Windows 错误 5）',
    53 || 67 => '找不到共享文件夹，请检查服务器地址和共享名（Windows 错误 $code）',
    86 || 1326 => '共享文件夹账号或密码错误（Windows 错误 $code）',
    1219 => 'Windows 已使用其他账号连接此服务器，请先断开该服务器的现有连接（Windows 错误 1219）',
    1272 => 'Windows 安全策略禁止未经身份验证的来宾访问，请为共享配置账号（Windows 错误 1272）',
    1222 || 1231 => 'Windows 网络不可用，请检查网络连接（Windows 错误 $code）',
    _ => '无法连接共享文件夹（Windows 错误 $code）',
  };
}

String _friendlySmbError(Object error) {
  final text = error.toString();
  if (text.contains('1272')) {
    return 'Windows 安全策略禁止未经身份验证的来宾访问，请为共享配置账号（Windows 错误 1272）';
  }
  if (text.contains('os error 53') ||
      text.contains('Windows 错误 53') ||
      text.contains('找不到网络路径')) {
    return '找不到共享文件夹，请检查服务器地址和共享名（Windows 错误 53）';
  }
  if (text.contains('1219')) {
    return 'Windows 已使用其他账号连接此服务器，请先断开该服务器的现有连接（Windows 错误 1219）';
  }
  return text;
}

class SmbClient implements RemoteClient {
  String shareRoot(String root) {
    final normalized = _normalizeRoot(root);
    final segments = normalized
        .split('\\')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    return '\\\\${segments[0]}\\${segments[1]}';
  }

  String _normalizeRoot(String root) {
    final normalized = root
        .trim()
        .replaceAll('/', '\\')
        .replaceFirst(RegExp(r'\\+$'), '');
    final segments = normalized
        .split('\\')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (!normalized.startsWith(r'\\') ||
        normalized.startsWith(r'\\?') ||
        segments.length < 2 ||
        segments.any(
          (segment) =>
              segment == '.' ||
              segment == '..' ||
              segment.contains(':') ||
              segment.contains('\u0000'),
        )) {
      throw const FormatException('SMB 共享路径必须是 \\服务器\\共享名');
    }
    return normalized;
  }

  String _sourceRoot(RemoteSource source) {
    return _normalizeRoot(source.root.isEmpty ? source.baseUrl : source.root);
  }

  void validateSource(RemoteSource source) {
    _sourceRoot(source);
  }

  Future<void> authenticate(RemoteSource source, String password) async {
    final username = source.username;
    final remote = shareRoot(_sourceRoot(source));
    try {
      await Isolate.run(
        () => _connectBlocking(remote, username, password),
      ).timeout(_connectTimeout);
    } on TimeoutException {
      throw StateError('连接共享文件夹超时，请检查地址、账号和网络');
    }
  }

  Future<void> warmUp(RemoteSource source, String password) async {
    try {
      await authenticate(source, password);
    } catch (_) {}
  }

  @override
  Future<List<RemoteTrack>> fetchTracks(
    RemoteSource source,
    String password, {
    RemoteSyncProgress? onProgress,
  }) async {
    await authenticate(source, password);
    // TODO(remote-index): rust 侧 build_remote_index_from_folders_recursively
    // 的 Dart 绑定尚未 codegen；本地索引入口会拒绝网络路径，
    // 生成绑定前 SMB 曲库同步保持不可用。
    throw StateError(
      _friendlySmbError('SMB 曲库索引尚未生成，请运行 flutter_rust_bridge_codegen 后重试'),
    );
  }

  @override
  String playbackUrl(RemoteSource source, String password, String trackId) {
    // 认证在同步或启动预热时完成，播放路径保持同步以免阻塞 UI。
    final root = _sourceRoot(source);
    final segments = trackId
        .replaceAll('/', '\\')
        .split('\\')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty ||
        segments.any(
          (segment) =>
              segment == '.' ||
              segment == '..' ||
              segment.contains(':') ||
              segment.contains('\u0000'),
        )) {
      throw const FormatException('SMB 曲目路径无效');
    }
    return '$root\\${segments.join('\\')}';
  }

  @override
  Future<Uint8List?> cover(
    RemoteSource source,
    String password,
    String? coverId,
    int size,
  ) async {
    return null;
  }
}
