import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:pure_music/core/network_proxy.dart';

/// 全局共享的 Dio 实例。
///
/// 更新检查、更新下载与 Last.fm 都从这里取 Dio，代理配置变化后调用
/// [rebuild]，后续请求会使用新的连接参数。
class AppHttp {
  AppHttp._();

  static final AppHttp instance = AppHttp._();

  Dio? _dio;

  Dio get dio => _dio ??= _createDio();

  void rebuild() {
    final previous = _dio;
    _dio = null;
    previous?.close(force: true);
  }

  Dio _createDio() {
    final dio = Dio();
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => NetworkProxy.instance.createHttpClient(),
    );
    return dio;
  }
}
