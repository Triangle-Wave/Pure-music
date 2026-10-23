import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/app_http.dart';

void main() {
  test('共享 Dio 使用代理适配器并在重建后更换实例', () {
    final first = AppHttp.instance.dio;

    expect(first.httpClientAdapter, isA<IOHttpClientAdapter>());

    AppHttp.instance.rebuild();

    final second = AppHttp.instance.dio;
    expect(identical(first, second), isFalse);
    expect(second.httpClientAdapter, isA<IOHttpClientAdapter>());
  });
}
