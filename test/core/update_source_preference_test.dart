import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/preference.dart';

void main() {
  group('migrateUpdateRepoSlug', () {
    test('replaces the upstream default with the user repository', () {
      expect(
        AppPreference.migrateUpdateRepoSlug('qingyueyin/Pure-music'),
        AppPreference.defaultUpdateRepoSlug,
      );
    });

    test('keeps a user-customized repository', () {
      expect(
        AppPreference.migrateUpdateRepoSlug('example/Pure-music'),
        'example/Pure-music',
      );
    });

    test('falls back to the default when the value is empty', () {
      expect(
        AppPreference.migrateUpdateRepoSlug('   '),
        AppPreference.defaultUpdateRepoSlug,
      );
    });
  });

  group('migrateUpdateCheckUrls', () {
    test('replaces upstream defaults and keeps custom urls', () {
      final migrated = AppPreference.migrateUpdateCheckUrls([
        'https://raw.githubusercontent.com/qingyueyin/Pure-music/main/update/version.json',
        'https://gitee.com/qingyueyin/Pure-music/raw/main/update/version.json',
        'https://example.com/update/version.json',
      ]);

      expect(migrated, [
        'https://raw.githubusercontent.com/Triangle-Wave/Pure-music/main/update/version.json',
        'https://example.com/update/version.json',
      ]);
    });

    test('fills the default when nothing is stored', () {
      expect(
        AppPreference.migrateUpdateCheckUrls(const []),
        AppPreference.defaultUpdateCheckUrls,
      );
    });
  });

  group('migrateUpdateChannel', () {
    test('moves the retired Gitee channel to GitHub', () {
      expect(AppPreference.migrateUpdateChannel('gitee'), 'github');
      expect(AppPreference.migrateUpdateChannel('GITEE'), 'github');
    });

    test('keeps unset and customized channels', () {
      expect(AppPreference.migrateUpdateChannel(null), isNull);
      expect(AppPreference.migrateUpdateChannel('github'), 'github');
    });
  });

  test('applyStoredMap migrates a legacy configuration once', () {
    final preference = AppPreference();
    preference.applyStoredMap({
      'updateRepoSlug': 'qingyueyin/Pure-music',
      'updateChannel': 'gitee',
      'updateCheckUrls': [
        'https://raw.githubusercontent.com/qingyueyin/Pure-music/main/update/version.json',
        'https://gitee.com/qingyueyin/Pure-music/raw/main/update/version.json',
      ],
    });

    expect(preference.updateRepoSlug, AppPreference.defaultUpdateRepoSlug);
    expect(preference.updateChannel, 'github');
    expect(preference.updateCheckUrls, AppPreference.defaultUpdateCheckUrls);
    expect(preference.updateSourceMigrated, isTrue);
    expect(preference.consumeUpdateSourceMigration(), isTrue);
    expect(preference.consumeUpdateSourceMigration(), isFalse);
  });

  test('applyStoredMap keeps customized values when already migrated', () {
    final preference = AppPreference();
    preference.applyStoredMap({
      'updateRepoSlug': 'example/Pure-music',
      'updateChannel': 'github',
      'updateCheckUrls': ['https://example.com/update/version.json'],
      'updateSourceMigrated': true,
    });

    expect(preference.updateRepoSlug, 'example/Pure-music');
    expect(preference.updateCheckUrls, [
      'https://example.com/update/version.json',
    ]);
    expect(preference.consumeUpdateSourceMigration(), isFalse);
  });

  test('applyStoredMap keeps user values in a legacy configuration', () {
    final preference = AppPreference();
    preference.applyStoredMap({
      'updateRepoSlug': 'example/Pure-music',
      'updateCheckUrls': ['https://example.com/update/version.json'],
    });

    expect(preference.updateRepoSlug, 'example/Pure-music');
    expect(preference.updateCheckUrls, [
      'https://example.com/update/version.json',
    ]);
  });
}
