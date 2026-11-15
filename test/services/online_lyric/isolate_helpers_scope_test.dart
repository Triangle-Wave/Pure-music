import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/online_lyric/api/isolate_helpers.dart';

void main() {
  group('closeNetworkClients', () {
    test('快照遍历期间移除客户端不抛并发修改异常', () {
      final clients = <String>{'a', 'b', 'c'};
      final closed = <String>[];
      expect(
        () => closeNetworkClients<String>(
          clients,
          closeClient: (client) {
            closed.add(client);
            clients.remove(client);
          },
          onCloseError: (_, __) {},
        ),
        returnsNormally,
      );
      expect(closed, unorderedEquals(['a', 'b', 'c']));
    });

    test('单个客户端关闭失败记录后继续关闭其余客户端', () {
      final closed = <String>[];
      final errors = <Object>[];
      closeNetworkClients<String>(
        {'a', 'b', 'c'},
        closeClient: (client) {
          if (client == 'b') throw StateError('close failed');
          closed.add(client);
        },
        onCloseError: (error, _) => errors.add(error),
      );
      expect(closed, unorderedEquals(['a', 'c']));
      expect(errors, hasLength(1));
    });

    test('错误处理回调抛异常时继续关闭其余客户端并清空集合', () {
      final clients = <String>{'a', 'b', 'c'};
      final closed = <String>[];
      expect(
        () => closeNetworkClients<String>(
          clients,
          closeClient: (client) {
            if (client == 'b') throw StateError('close failed');
            closed.add(client);
          },
          onCloseError: (_, __) => throw StateError('handler failed'),
        ),
        returnsNormally,
      );
      expect(closed, unorderedEquals(['a', 'c']));
      expect(clients, isEmpty);
    });
  });

  group('NetworkRequestScope', () {
    test('close 重复调用不重复关闭客户端', () {
      final closed = <String>[];
      final scope = NetworkRequestScope<String>(
        closed.add,
        (_, __) {},
      );
      scope.add('a');
      scope.add('b');
      scope.close();
      scope.close();
      expect(closed, unorderedEquals(['a', 'b']));
    });

    test('close 期间移除客户端不抛并发修改异常', () {
      late NetworkRequestScope<String> scope;
      scope = NetworkRequestScope<String>(
        (client) => scope.remove(client),
        (_, __) {},
      );
      scope.add('a');
      scope.add('b');
      expect(() => scope.close(), returnsNormally);
    });

    test('关闭后加入的客户端被直接关闭且不进入集合', () {
      final closed = <String>[];
      final scope = NetworkRequestScope<String>(
        closed.add,
        (_, __) {},
      );
      scope.close();
      scope.add('late');
      expect(closed, ['late']);
      expect(() => scope.close(), returnsNormally);
    });

    test('关闭客户端抛异常时按回调降级且不冒泡', () {
      final errors = <Object>[];
      final scope = NetworkRequestScope<String>(
        (client) => throw StateError('boom'),
        (error, _) => errors.add(error),
      );
      scope.add('a');
      scope.add('b');
      expect(() => scope.close(), returnsNormally);
      expect(errors, hasLength(2));
    });
  });
}
