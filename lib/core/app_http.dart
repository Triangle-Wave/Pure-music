import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/network_proxy.dart';

/// 全局共享的 Dio 实例。
///
/// [dio] 跟随全局代理配置，所有请求统一使用；[directDio] 仅供
/// [ProxyFallbackInterceptor] 在代理连接失败时回退一次。
class AppHttp {
  AppHttp._();

  static final AppHttp instance = AppHttp._();

  Dio? _dio;
  Dio? _directDio;

  /// 跟随代理配置的客户端，所有 HTTPS 请求统一从这里取。
  Dio get dio => _dio ??= _createDio();

  /// 强制直连的客户端，仅用于代理失败后的兜底。
  Dio get directDio => _directDio ??= _createDio(direct: true);

  void rebuild() {
    _close(_dio);
    _close(_directDio);
    _dio = null;
    _directDio = null;
  }

  void _close(Dio? dio) {
    if (dio == null) return;
    try {
      dio.close(force: true);
    } catch (error, trace) {
      log.app.warn(
        'legacy',
        '[network] 关闭网络客户端失败',
        error: error,
        stackTrace: trace,
      );
    }
  }

  Dio _createDio({bool direct = false}) {
    final dio = Dio();
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => direct
          ? NetworkProxy.instance.createDirectHttpClient()
          : NetworkProxy.instance.createHttpClient(),
    );
    if (!direct) {
      dio.interceptors.add(
        ProxyFallbackInterceptor(
          directDio: directDio,
          config: NetworkProxy.instance.config,
        ),
      );
    }
    return dio;
  }
}

/// 手动代理连接失败时改用直连重试一次。
///
/// 代理未启动或端口填错时，请求仍有一次直连机会；重试只针对连接类错误，
/// 流式下载与不可重放的请求体不重试。
class ProxyFallbackInterceptor extends Interceptor {
  ProxyFallbackInterceptor({required this.directDio, required this.config});

  final Dio directDio;
  final ProxyConfig config;

  static const _retryKey = 'proxy_fallback_retried';

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (!_shouldRetry(err)) {
      handler.next(err);
      return;
    }
    unawaited(_retry(err, handler));
  }

  bool _shouldRetry(DioException err) {
    if (config.mode != ProxyMode.manual) return false;
    if (err.requestOptions.extra[_retryKey] == true) return false;
    if (err.requestOptions.cancelToken?.isCancelled ?? false) return false;
    if (err.requestOptions.responseType == ResponseType.stream) return false;
    if (err.requestOptions.data is Stream<Object?>) return false;
    return err.type == DioExceptionType.connectionError ||
        err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.receiveTimeout;
  }

  Future<void> _retry(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    options.extra[_retryKey] = true;
    final host = options.uri.host;
    try {
      final response = await directDio.fetch<dynamic>(options);
      log.app.warn(
        'legacy',
        '[network] 代理连接失败，已回退直连: $host (${err.type.name})',
        fields: {'host': host, 'error': err.type.name},
      );
      handler.resolve(response);
    } catch (fallbackError, trace) {
      log.app.warn(
        'legacy',
        '[network] 代理与直连均失败: $host (${err.type.name})',
        fields: {'host': host, 'error': err.type.name},
        error: fallbackError,
        stackTrace: trace,
      );
      handler.next(err);
    }
  }
}
