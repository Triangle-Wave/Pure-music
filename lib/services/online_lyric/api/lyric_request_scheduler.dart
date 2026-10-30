import 'dart:async';

final _lyricRequestTokenZoneKey = Object();
const lyricInlineWorkByteLimit = 256 * 1024;

bool shouldRunLyricWorkInline(int byteLength) =>
    byteLength <= lyricInlineWorkByteLimit;

LyricRequestToken? get currentLyricRequestToken =>
    Zone.current[_lyricRequestTokenZoneKey] as LyricRequestToken?;

class LyricRequestToken {
  final _cancelListeners = <void Function()>{};
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List<void Function()>.of(_cancelListeners);
    _cancelListeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void Function() addCancelListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _cancelListeners.add(listener);
    return () => _cancelListeners.remove(listener);
  }
}

class LyricRequestScheduler {
  LyricRequestScheduler({int backgroundQueueLimit = 2})
    : _interactiveLane = _RequestLane(queueLimit: 1),
      _backgroundLane = _RequestLane(queueLimit: backgroundQueueLimit),
      _computeLane = _RequestLane(queueLimit: 4);

  static final instance = LyricRequestScheduler();

  final _RequestLane _interactiveLane;
  final _RequestLane _backgroundLane;
  final _RequestLane _computeLane;
  LyricRequestToken? _interactiveToken;
  bool _closed = false;

  LyricRequestToken beginInteractive() {
    if (_closed) return LyricRequestToken()..cancel();
    cancelInteractive();
    final token = LyricRequestToken();
    _interactiveToken = token;
    return token;
  }

  void cancelInteractive() {
    _interactiveToken?.cancel();
    _interactiveToken = null;
    _interactiveLane.cancelQueued();
    _computeLane.cancelQueued();
  }

  void cancelBackground() {
    _backgroundLane.cancelAll();
  }

  Future<T?> runInteractive<T>(
    Future<T?> Function(LyricRequestToken token) task,
  ) {
    if (_closed) return Future<T?>.value(null);
    final token = _interactiveToken ?? beginInteractive();
    return _interactiveLane.enqueue(token, task);
  }

  Future<T?> runBackground<T>(
    Future<T?> Function(LyricRequestToken token) task,
  ) {
    if (_closed) return Future<T?>.value(null);
    return _backgroundLane.enqueue(LyricRequestToken(), task);
  }

  Future<T?> runLyricCompute<T>(
    Future<T?> Function(LyricRequestToken token) task,
  ) {
    if (_closed) return Future<T?>.value(null);
    final token = currentLyricRequestToken ??
        _interactiveToken ??
        LyricRequestToken();
    return _computeLane.enqueue(token, task);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _interactiveToken?.cancel();
    _interactiveLane.close();
    _backgroundLane.close();
    _computeLane.close();
  }

}

class _RequestLane {
  _RequestLane({required this.queueLimit}) : assert(queueLimit > 0);

  final int queueLimit;
  final _pending = <_QueuedRequest<Object?>>[];
  _QueuedRequest<Object?>? _running;
  bool _closed = false;

  Future<T?> enqueue<T>(
    LyricRequestToken token,
    Future<T?> Function(LyricRequestToken token) task,
  ) {
    if (_closed || token.isCancelled) return Future<T?>.value(null);
    if (_pending.length >= queueLimit) {
      token.cancel();
      return Future<T?>.value(null);
    }

    final request = _QueuedRequest<Object?>(
      token,
      (token) => task(token),
    );
    _pending.add(request);
    _pump();
    return request.completer.future.then((value) => value as T?);
  }

  void cancelQueued() {
    final pending = List<_QueuedRequest<Object?>>.of(_pending);
    _pending.clear();
    for (final request in pending) {
      request.token.cancel();
      request.complete(null);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _running?.token.cancel();
    cancelQueued();
  }

  void cancelAll() {
    _running?.token.cancel();
    cancelQueued();
  }

  void _pump() {
    if (_closed || _running != null || _pending.isEmpty) return;
    final request = _pending.removeAt(0);
    _running = request;
    unawaited(_run(request));
  }

  Future<void> _run(_QueuedRequest<Object?> request) async {
    try {
      if (request.token.isCancelled) {
        request.complete(null);
        return;
      }
      final result = await runZoned<Future<Object?>>(
        () => request.task(request.token),
        zoneValues: {_lyricRequestTokenZoneKey: request.token},
      );
      request.complete(result);
    } catch (error, trace) {
      request.completeError(error, trace);
    } finally {
      if (identical(_running, request)) _running = null;
      _pump();
    }
  }
}

class _QueuedRequest<T> {
  _QueuedRequest(this.token, this.task);

  final LyricRequestToken token;
  final Future<T?> Function(LyricRequestToken token) task;
  final completer = Completer<T?>();

  void complete(T? value) {
    if (!completer.isCompleted) completer.complete(value);
  }

  void completeError(Object error, StackTrace trace) {
    if (!completer.isCompleted) completer.completeError(error, trace);
  }
}
