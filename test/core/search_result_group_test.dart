import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/search_result_group.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/union_search_result.dart';

Audio _audio(String title) => Audio(
  title,
  'Artist',
  'Album',
  null,
  1,
  60,
  320,
  44100,
  r'C:\Music\a.mp3',
  1,
  1,
  'test',
);

UnionSearchItem _item(UnionSearchItemKind kind, String key) => UnionSearchItem(
  kind: kind,
  rank: 0,
  sortKey: key,
  audioIndex: -1,
  audio: kind == UnionSearchItemKind.music ? _audio(key) : null,
  artist: kind == UnionSearchItemKind.artist ? Artist(name: key) : null,
  album: kind == UnionSearchItemKind.album ? Album(name: key) : null,
);

void main() {
  test('groups items in music artist album order with counts', () {
    final groups = groupSearchItems([
      _item(UnionSearchItemKind.album, 'A'),
      _item(UnionSearchItemKind.artist, 'B'),
      _item(UnionSearchItemKind.music, 'C'),
      _item(UnionSearchItemKind.music, 'D'),
    ]);

    expect(
      groups.map((group) => group.kind).toList(),
      <UnionSearchItemKind>[
        UnionSearchItemKind.music,
        UnionSearchItemKind.artist,
        UnionSearchItemKind.album,
      ],
    );
    expect(groups.map((group) => group.title).toList(), [
      '歌曲 · 2',
      '歌手 · 1',
      '专辑 · 1',
    ]);
    expect(
      groups.first.items.map((item) => item.sortKey).toList(),
      ['C', 'D'],
    );
  });

  test('skips empty groups', () {
    final groups = groupSearchItems([
      _item(UnionSearchItemKind.artist, 'B'),
    ]);

    expect(groups.length, 1);
    expect(groups.single.kind, UnionSearchItemKind.artist);
  });

  test('returns empty for no items', () {
    expect(groupSearchItems(const <UnionSearchItem>[]), isEmpty);
  });
}
