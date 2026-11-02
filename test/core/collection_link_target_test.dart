import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/collection_link_target.dart';

void main() {
  group('resolveCollectionLinkTarget', () {
    test('单歌手命中曲库时返回单目标', () {
      final target = resolveCollectionLinkTarget<String>(
        ['林俊杰'],
        {'林俊杰': 'artist-lin'},
      );

      expect(target, isA<CollectionLinkSingle<String>>());
      expect((target as CollectionLinkSingle<String>).value, 'artist-lin');
    });

    test('多歌手返回菜单项并保留查不到的名字', () {
      final target = resolveCollectionLinkTarget<String>(
        ['周杰伦', '费玉清'],
        {'周杰伦': 'artist-jay'},
      );

      expect(target, isA<CollectionLinkMultiple<String>>());
      final options = (target as CollectionLinkMultiple<String>).options;
      expect(options.map((option) => option.label), ['周杰伦', '费玉清']);
      expect(options.first.value, 'artist-jay');
      expect(options.last.value, isNull);
    });

    test('多歌手全部不在曲库时不可用', () {
      final target = resolveCollectionLinkTarget<String>(
        ['周杰伦', '费玉清'],
        {'林俊杰': 'artist-lin'},
      );

      expect(target, isA<CollectionLinkUnavailable<String>>());
    });

    test('单歌手不在曲库时不可用', () {
      final target = resolveCollectionLinkTarget<String>(
        ['林俊杰'],
        {'周杰伦': 'artist-jay'},
      );

      expect(target, isA<CollectionLinkUnavailable<String>>());
    });

    test('空歌手列表不可用', () {
      final target = resolveCollectionLinkTarget<String>(
        const <String>[],
        {'周杰伦': 'artist-jay'},
      );

      expect(target, isA<CollectionLinkUnavailable<String>>());
    });

    test('空白名字被过滤并去重', () {
      final target = resolveCollectionLinkTarget<String>(
        [' 周杰伦 ', '周杰伦', '', '   '],
        {'周杰伦': 'artist-jay'},
      );

      expect(target, isA<CollectionLinkSingle<String>>());
      expect((target as CollectionLinkSingle<String>).value, 'artist-jay');
    });

    test('空专辑名不可用', () {
      final target = resolveCollectionLinkTarget<String>(
        [''],
        {'': 'album-empty'},
      );

      expect(target, isA<CollectionLinkUnavailable<String>>());
    });
  });
}
