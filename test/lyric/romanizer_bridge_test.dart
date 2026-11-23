import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/romanizer_bridge.dart';

void main() {
  tearDown(debugResetRomanizer);

  test('空输入不调用词典', () async {
    var calls = 0;
    debugOverrideRomanizer(
      romanize: (texts, includeKanjiOnly) async {
        calls++;
        return const <String>[];
      },
    );

    expect(await romanizeLines(const []), isEmpty);
    expect(await romanizeLines(const [], includeKanjiOnly: true), isEmpty);
    expect(calls, 0);
  });

  test('正常返回与输入等长的结果并透传标志', () async {
    List<String>? received;
    var receivedIncludeKanjiOnly = false;
    debugOverrideRomanizer(
      romanize: (texts, includeKanjiOnly) async {
        received = List<String>.from(texts);
        receivedIncludeKanjiOnly = includeKanjiOnly;
        return const ['kimi', 'toukyou'];
      },
    );

    final result = await romanizeLines(
      const ['きみ', '東京'],
      includeKanjiOnly: true,
    );
    expect(result, ['kimi', 'toukyou']);
    expect(received, ['きみ', '東京']);
    expect(receivedIncludeKanjiOnly, isTrue);
  });

  test('词典抛异常时返回等长空列表', () async {
    debugOverrideRomanizer(
      romanize: (texts, includeKanjiOnly) async {
        throw StateError('dictionary unavailable');
      },
    );

    final result = await romanizeLines(const ['あ', 'い', 'う']);
    expect(result, ['', '', '']);
  });

  test('返回行数不足时按空串补齐', () async {
    debugOverrideRomanizer(
      romanize: (texts, includeKanjiOnly) async => const ['kimi'],
    );

    expect(await romanizeLines(const ['きみ', 'そら']), ['kimi', '']);
  });

  test('预热失败不外抛', () async {
    debugOverrideRomanizer(
      warmup: () async => throw StateError('warmup failed'),
    );

    await warmUpRomanizer();
  });
}
