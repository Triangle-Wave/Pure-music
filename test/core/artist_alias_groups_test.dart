import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/artist_alias_groups.dart';

void main() {
  test('links several artist names into one display name', () {
    final result = applyArtistGroupLink(
      currentName: 'YOASOBI',
      displayName: 'YOASOBI',
      selectedNames: const ['夜遊', 'Ayase'],
      aliases: const {},
    );

    expect(result, {'夜遊': 'YOASOBI', 'Ayase': 'YOASOBI'});
    expect(result.containsKey('YOASOBI'), isFalse);
    expect(artistGroupMembers('YOASOBI', result), ['夜遊', 'Ayase']);
  });

  test('renames the whole group', () {
    final result = applyArtistGroupLink(
      currentName: 'YOASOBI',
      displayName: 'Yoru',
      selectedNames: const ['夜遊'],
      aliases: const {'夜遊': 'YOASOBI'},
    );

    expect(result, {'夜遊': 'Yoru', 'YOASOBI': 'Yoru'});
    expect(artistGroupMembers('Yoru', result), ['夜遊', 'YOASOBI']);
  });

  test('keeps a display name that is itself an original name unmapped', () {
    final result = applyArtistGroupLink(
      currentName: '柚子',
      displayName: '柚子',
      selectedNames: const ['Yuzu', 'ゆず'],
      aliases: const {},
    );

    expect(result, {'Yuzu': '柚子', 'ゆず': '柚子'});
    expect(result.containsKey('柚子'), isFalse);
  });

  test('removes one member but keeps the rest of the group', () {
    final result = applyArtistGroupLink(
      currentName: 'YOASOBI',
      displayName: 'YOASOBI',
      selectedNames: const ['Ayase'],
      aliases: const {'夜遊': 'YOASOBI', 'Ayase': 'YOASOBI'},
    );

    expect(result, {'Ayase': 'YOASOBI'});
    expect(artistGroupMembers('YOASOBI', result), ['Ayase']);
  });

  test('dissolves the whole group', () {
    final result = applyArtistGroupLink(
      currentName: 'YOASOBI',
      displayName: 'YOASOBI',
      selectedNames: const [],
      aliases: const {'夜遊': 'YOASOBI', 'Ayase': 'YOASOBI'},
    );

    expect(result, isEmpty);
    expect(artistGroupMembers('YOASOBI', result), isEmpty);
  });

  test('absorbs the whole group of a selected display name', () {
    final result = applyArtistGroupLink(
      currentName: 'A',
      displayName: 'A',
      selectedNames: const ['B'],
      aliases: const {'X': 'B', 'Y': 'B'},
    );

    expect(result, {'B': 'A', 'X': 'A', 'Y': 'A'});
  });

  test('search names include the display name and every member', () {
    expect(
      artistSearchNames('YOASOBI', const {'夜遊': 'YOASOBI', 'X': 'Other'}),
      ['YOASOBI', '夜遊'],
    );
  });
}
