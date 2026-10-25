import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/app_http.dart';
import 'package:pure_music/core/network_proxy.dart';

const _githubUrl = 'https://api.github.com/repos/a/b/releases/latest';

void main() {
  tearDown(() {
    AppHttp.instance.rebuild();
    NetworkProxy.instance.apply(const ProxyConfig(mode: ProxyMode.direct));
  });

  test('共享 Dio 使用代理适配器并在重建后更换实例', () {
    final first = AppHttp.instance.dio;

    expect(first.httpClientAdapter, isA<IOHttpClientAdapter>());
    expect(
      first.interceptors.whereType<ProxyFallbackInterceptor>(),
      hasLength(1),
    );

    AppHttp.instance.rebuild();

    final second = AppHttp.instance.dio;
    expect(identical(first, second), isFalse);
    expect(second.httpClientAdapter, isA<IOHttpClientAdapter>());
    expect(
      AppHttp.instance.directDio.interceptors
          .whereType<ProxyFallbackInterceptor>(),
      isEmpty,
    );
  });

  test('手动代理连接失败时用直连重试一次', () async {
    var proxyAttempts = 0;
    final direct = Dio()
      ..httpClientAdapter = _StubAdapter(
        (_) async => _jsonResponse('{"ok":true}'),
      );
    final proxied = Dio()
      ..httpClientAdapter = _StubAdapter((options) async {
        proxyAttempts++;
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'proxy refused',
        );
      });
    proxied.interceptors.add(
      ProxyFallbackInterceptor(
        directDio: direct,
        config: const ProxyConfig(
          mode: ProxyMode.manual,
          host: '127.0.0.1',
          port: 7890,
        ),
      ),
    );

    final response = await proxied.get<Map<String, dynamic>>(_githubUrl);

    expect(proxyAttempts, 1);
    expect(response.statusCode, 200);
    expect(response.data, {'ok': true});
  });

  test('手动代理与直连都失败时保留原始错误', () async {
    final direct = Dio()
      ..httpClientAdapter = _StubAdapter(
        (options) async => throw DioException.connectionError(
          requestOptions: options,
          reason: 'direct refused',
        ),
      );
    final proxied = Dio()
      ..httpClientAdapter = _StubAdapter(
        (options) async => throw DioException.connectionError(
          requestOptions: options,
          reason: 'proxy refused',
        ),
      );
    proxied.interceptors.add(
      ProxyFallbackInterceptor(
        directDio: direct,
        config: const ProxyConfig(
          mode: ProxyMode.manual,
          host: '127.0.0.1',
          port: 7890,
        ),
      ),
    );

    await expectLater(
      proxied.get<dynamic>(_githubUrl),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.connectionError,
        ),
      ),
    );
  });

  test('直连模式不触发代理回退', () async {
    var directAttempts = 0;
    final direct = Dio()
      ..httpClientAdapter = _StubAdapter((_) async {
        directAttempts++;
        return _jsonResponse('{"ok":true}');
      });
    final proxied = Dio()
      ..httpClientAdapter = _StubAdapter(
        (options) async => throw DioException.connectionError(
          requestOptions: options,
          reason: 'proxy refused',
        ),
      );
    proxied.interceptors.add(
      ProxyFallbackInterceptor(
        directDio: direct,
        config: const ProxyConfig(mode: ProxyMode.direct),
      ),
    );

    await expectLater(
      proxied.get<dynamic>(_githubUrl),
      throwsA(isA<DioException>()),
    );
    expect(directAttempts, 0);
  });
}

ResponseBody _jsonResponse(String body) {
  return ResponseBody.fromString(
    body,
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);

  @override
  void close({bool force = false}) {}
}
