/// TickerMode 静音期间 Ticker 不回调，恢复后 `elapsed` 会包含整段静音时长。
/// 判断 TickerMode 是否由关闭恢复为开启，调用方据此丢弃旧的计时基准。
bool tickerModeResumed({
  required bool? previousEnabled,
  required bool enabled,
}) => previousEnabled == false && enabled;

/// 返回上一帧到本帧允许推进的动画时长。
///
/// [last] 为空表示刚建立计时基准，本帧只校准不推进；
/// 间隔超过 [maxDelta] 说明经历了静音、挂起或长时间掉帧，同样只校准。
Duration tickerFrameDelta(
  Duration? last,
  Duration elapsed, {
  Duration maxDelta = const Duration(milliseconds: 250),
}) {
  if (last == null) return Duration.zero;
  final delta = elapsed - last;
  if (delta <= Duration.zero || delta > maxDelta) return Duration.zero;
  return delta;
}
