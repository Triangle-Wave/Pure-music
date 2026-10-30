import 'dart:async';

/// 同一 SACD 轨道的提取任务合并表。
///
/// 快速连切时同一轨可能被同时请求多次，这里让并发调用共享同一个 Future，
/// 只向 Rust 侧发起一次提取。任务结束（无论成功还是失败）后立即移除记录：
/// 成功时后续调用会重新进入提取流程并命中磁盘缓存，失败时不会把错误结果永久缓存。
class SacdSourceCache {
  final Map<String, Future<String>> _inFlight = <String, Future<String>>{};

  /// 当前在途提取数量，用于测试与诊断。
  int get inFlightCount => _inFlight.length;

  Future<String> extract(String key, Future<String> Function() load) {
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = Future<String>.sync(load);
    _inFlight[key] = future;
    // 单独挂一个监听：即使调用方不等待结果，提取失败也不会以未处理异步异常的形式漏出。
    unawaited(
      future
          .then<void>(
            (_) {},
            onError: (Object _, StackTrace __) {},
          )
          .whenComplete(() {
            if (identical(_inFlight[key], future)) {
              _inFlight.remove(key);
            }
          }),
    );
    return future;
  }
}
