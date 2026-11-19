import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/page_preference.dart';
import 'package:pure_music/core/preference.dart';

void main() {
  test('page preference keeps legacy enum and bounded sort decoding', () {
    final preference = PagePreference.fromMap({
      'sortMethod': '-4',
      'sortOrder': 'SortOrder.decending',
      'contentView': 1,
    });

    expect(preference.sortMethod, 0);
    expect(preference.sortOrder, SortOrder.decending);
    expect(preference.contentView, ContentView.table);
  });

  test('page preference round-trips its storage map', () {
    final preference = PagePreference(1, SortOrder.ascending, ContentView.list);

    expect(
      PagePreference.fromMap(preference.toMap()).toMap(),
      preference.toMap(),
    );
  });

  test('artist detail page defaults to album sort method', () {
    expect(AppPreference().artistDetailPagePref.sortMethod, 1);
  });
}
