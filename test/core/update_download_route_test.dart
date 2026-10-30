import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/update_checker.dart';
import 'package:pure_music/core/update_route.dart';

const _directUrl =
    'https://github.com/Triangle-Wave/Pure-music/releases/download/'
    'v2.3.9/pure_music_2.3.9_release_installer.exe';
const _giteeUrl =
    'https://gitee.com/qingyueyin/Pure-music/releases/download/'
    'v2.3.9/pure_music_2.3.9_release_installer.exe';
const _githubMetadata =
    'https://raw.githubusercontent.com/Triangle-Wave/Pure-music/main/update/version.json';
const _giteeMetadata =
    'https://gitee.com/qingyueyin/Pure-music/raw/main/update/version.json';

List<UpdateDownloadCandidate> _candidates(UpdateDownloadRoute route) {
  return updateDownloadCandidates(
    route: route,
    directUrl: _directUrl,
    giteeUrl: _giteeUrl,
  );
}

void main() {
  group('candidate order', () {
    test('auto tries direct, Gitee, then every proxy', () {
      final candidates = _candidates(UpdateDownloadRoute.auto);

      expect(candidates.map((candidate) => candidate.url).toList(), [
        _directUrl,
        _giteeUrl,
        'https://ghfast.top/$_directUrl',
        'https://gh-proxy.com/$_directUrl',
        'https://ghproxy.net/$_directUrl',
      ]);
      expect(candidates.map((candidate) => candidate.source).toList(), [
        UpdateDownloadSource.direct,
        UpdateDownloadSource.gitee,
        UpdateDownloadSource.proxy,
        UpdateDownloadSource.proxy,
        UpdateDownloadSource.proxy,
      ]);
    });

    test('github only tries the direct download', () {
      final candidates = updateDownloadCandidates(
        route: UpdateDownloadRoute.github,
        directUrl: _directUrl,
        giteeUrl: _giteeUrl,
        extraUrls: const [
          'https://raw.githubusercontent.com/Triangle-Wave/Pure-music/dev/update/version.json',
        ],
      );

      expect(candidates.map((c) => c.url).toList(), [_directUrl]);
      expect(candidates.single.source, UpdateDownloadSource.direct);
    });

    test('gitee only tries the Gitee mirror', () {
      expect(_candidates(UpdateDownloadRoute.gitee).map((c) => c.url).toList(), [
        _giteeUrl,
      ]);
    });

    test('proxy only tries the proxies and never falls back to direct', () {
      final candidates = _candidates(UpdateDownloadRoute.proxy);

      expect(candidates.map((candidate) => candidate.source).toList(), [
        UpdateDownloadSource.proxy,
        UpdateDownloadSource.proxy,
        UpdateDownloadSource.proxy,
      ]);
      expect(candidates.every((candidate) => !candidate.isDirect), isTrue);
      expect(candidates.first.url, startsWith('https://ghfast.top/https://'));
    });

    test('metadata candidates never include proxy prefixes', () {
      for (final route in UpdateDownloadRoute.values) {
        final candidates = updateMetadataCandidates(
          route: route,
          directUrl: _githubMetadata,
          giteeUrl: _giteeMetadata,
          extraUrls: const [
            'https://ghfast.top/$_githubMetadata',
            'https://raw.githubusercontent.com/Triangle-Wave/Pure-music/dev/update/version.json',
          ],
        );

        expect(
          candidates.any((candidate) => candidate.source == UpdateDownloadSource.proxy),
          isFalse,
          reason: '${route.name} metadata must not go through a proxy',
        );
        for (final candidate in candidates) {
          expect(
            defaultUpdateProxyPrefixes.any(
              (prefix) => candidate.url.startsWith(prefix),
            ),
            isFalse,
            reason: '${route.name} metadata leaked a proxy prefix',
          );
        }
      }
    });

    test('metadata candidates reuse the official source order', () {
      final candidates = updateMetadataCandidates(
        route: UpdateDownloadRoute.auto,
        directUrl: _githubMetadata,
        giteeUrl: _giteeMetadata,
      );

      expect(candidates.map((candidate) => candidate.url).toList(), [
        _githubMetadata,
        _giteeMetadata,
      ]);
    });

    test('auto keeps custom metadata sources before Gitee', () {
      final candidates = updateMetadataCandidates(
        route: UpdateDownloadRoute.auto,
        directUrl: _githubMetadata,
        giteeUrl: _giteeMetadata,
        extraUrls: const [
          'https://raw.githubusercontent.com/Triangle-Wave/Pure-music/dev/update/version.json',
        ],
      );

      expect(candidates[0].url, _githubMetadata);
      expect(candidates[1].url, contains('/dev/'));
      expect(candidates[2].url, _giteeMetadata);
    });

    test('deduplicates candidates with the same url', () {
      final candidates = updateDownloadCandidates(
        route: UpdateDownloadRoute.auto,
        directUrl: _directUrl,
        giteeUrl: _directUrl,
      );

      expect(
        candidates.where((candidate) => candidate.url == _directUrl),
        hasLength(1),
      );
    });
  });

  group('fallback', () {
    test('uses Gitee when the direct download fails', () async {
      final failures = <UpdateDownloadAttemptFailure>[];
      final result = await runUpdateDownloadAttempts<String>(
        candidates: _candidates(UpdateDownloadRoute.auto),
        attempt: (candidate) async {
          if (candidate.source == UpdateDownloadSource.direct) {
            throw const UpdateDownloadAttemptException(
              UpdateDownloadFailureReason.timeout,
            );
          }
          return candidate.url;
        },
        onFailure: failures.add,
      );

      expect(result, _giteeUrl);
      expect(failures.single.reason, UpdateDownloadFailureReason.timeout);
      expect(failures.single.candidate.source, UpdateDownloadSource.direct);
    });

    test('uses the first proxy when direct and Gitee both fail', () async {
      final failures = <UpdateDownloadAttemptFailure>[];
      final result = await runUpdateDownloadAttempts<String>(
        candidates: _candidates(UpdateDownloadRoute.auto),
        attempt: (candidate) async {
          if (candidate.source == UpdateDownloadSource.proxy) {
            return candidate.url;
          }
          throw const UpdateDownloadAttemptException(
            UpdateDownloadFailureReason.notFound,
            statusCode: 404,
          );
        },
        onFailure: failures.add,
      );

      expect(result, 'https://ghfast.top/$_directUrl');
      expect(failures, hasLength(2));
    });

    test('reports the direct failure when every route fails', () async {
      final failures = <UpdateDownloadAttemptFailure>[];
      Object? error;
      try {
        await runUpdateDownloadAttempts<String>(
          candidates: _candidates(UpdateDownloadRoute.auto),
          attempt: (candidate) async {
            throw switch (candidate.source) {
              UpdateDownloadSource.direct =>
                const UpdateDownloadAttemptException(
                  UpdateDownloadFailureReason.timeout,
                ),
              UpdateDownloadSource.gitee =>
                const UpdateDownloadAttemptException(
                  UpdateDownloadFailureReason.notFound,
                  statusCode: 404,
                ),
              UpdateDownloadSource.proxy =>
                const UpdateDownloadAttemptException(
                  UpdateDownloadFailureReason.connection,
                ),
              UpdateDownloadSource.custom =>
                const UpdateDownloadAttemptException(
                  UpdateDownloadFailureReason.unknown,
                ),
            };
          },
          onFailure: failures.add,
        );
      } catch (caught) {
        error = caught;
      }

      expect(error, isA<UpdateDownloadAggregateException>());
      final message = (error as UpdateDownloadAggregateException).message;
      expect(message, startsWith('下载失败：GitHub 直连'));
      expect(message, contains('连接超时'));
      expect(message, contains('已尝试 5 条线路'));
    });

    test('cancellation stops the fallback without reporting a failure', () async {
      var attempts = 0;
      final failures = <UpdateDownloadAttemptFailure>[];
      Object? error;
      try {
        await runUpdateDownloadAttempts<String>(
          candidates: _candidates(UpdateDownloadRoute.auto),
          attempt: (_) async {
            attempts += 1;
            throw const UpdateDownloadAttemptException(
              UpdateDownloadFailureReason.cancelled,
            );
          },
          onFailure: failures.add,
        );
      } catch (caught) {
        error = caught;
      }

      expect(error, isA<UpdateDownloadAttemptException>());
      expect(
        (error as UpdateDownloadAttemptException).reason,
        UpdateDownloadFailureReason.cancelled,
      );
      expect(attempts, 1);
      expect(failures, isEmpty);
    });
  });

  group('checksum', () {
    test('switches to the next route when a checksum does not match', () async {
      final failures = <UpdateDownloadAttemptFailure>[];
      final result = await runUpdateDownloadAttempts<String>(
        candidates: _candidates(UpdateDownloadRoute.auto),
        attempt: (candidate) async {
          if (candidate.source == UpdateDownloadSource.direct) {
            throw const UpdateDownloadAttemptException(
              UpdateDownloadFailureReason.checksum,
            );
          }
          return candidate.url;
        },
        onFailure: failures.add,
      );

      expect(result, _giteeUrl);
      expect(failures.single.reason, UpdateDownloadFailureReason.checksum);
    });

    test('fails clearly when no route matches the checksum', () async {
      Object? error;
      try {
        await runUpdateDownloadAttempts<String>(
          candidates: _candidates(UpdateDownloadRoute.auto),
          attempt: (_) async => throw const UpdateDownloadAttemptException(
            UpdateDownloadFailureReason.checksum,
          ),
          onFailure: (_) {},
        );
      } catch (caught) {
        error = caught;
      }

      expect(error, isA<UpdateDownloadAggregateException>());
      expect(
        (error as UpdateDownloadAggregateException).message,
        contains('SHA256 校验不通过'),
      );
    });
  });

  group('trusted route urls', () {
    test('the shipped manifest points at the trusted Gitee mirror', () {
      final decoded = jsonDecode(File('update/version.json').readAsStringSync());
      expect(decoded, isA<Map<String, dynamic>>());
      final manifest = decoded as Map<String, dynamic>;
      final installer = manifest['gitee_installer_url'] as String;
      final checksum = manifest['gitee_installer_checksum_url'] as String;

      expect(installer, contains('gitee.com/qingyueyin/Pure-music'));
      expect(checksum, contains('gitee.com/qingyueyin/Pure-music'));
      expect(isAllowedUpdateDownloadUrlForRoute(installer), isTrue);
      expect(isAllowedUpdateDownloadUrlForRoute(checksum), isTrue);
    });

    test('accepts the real Gitee mirror address', () {
      expect(_giteeUrl, contains('gitee.com/qingyueyin/Pure-music'));
      expect(_giteeMetadata, contains('gitee.com/qingyueyin/Pure-music'));
      expect(isAllowedUpdateDownloadUrlForRoute(_giteeUrl), isTrue);
      expect(isAllowedUpdateMetadataUrlForRoute(_giteeMetadata), isTrue);
    });

    test('accepts GitHub, Gitee and built-in proxies for downloads', () {
      expect(isAllowedUpdateDownloadUrlForRoute(_directUrl), isTrue);
      expect(isAllowedUpdateDownloadUrlForRoute(_giteeUrl), isTrue);
      for (final prefix in defaultUpdateProxyPrefixes) {
        expect(
          isAllowedUpdateDownloadUrlForRoute('$prefix$_directUrl'),
          isTrue,
        );
      }
    });

    test('rejects unknown proxies and untrusted inner urls', () {
      expect(
        isAllowedUpdateDownloadUrlForRoute('https://evil.example/$_directUrl'),
        isFalse,
      );
      expect(
        isAllowedUpdateDownloadUrlForRoute(
          'https://ghfast.top/https://example.com/app.exe',
        ),
        isFalse,
      );
      expect(
        isAllowedUpdateDownloadUrlForRoute(
          'http://github.com/Triangle-Wave/Pure-music/releases/download/v2.3.9/app.exe',
        ),
        isFalse,
      );
    });

    test('metadata accepts Gitee but rejects every proxy prefix', () {
      expect(isAllowedUpdateMetadataUrlForRoute(_giteeMetadata), isTrue);
      for (final prefix in defaultUpdateProxyPrefixes) {
        expect(
          isAllowedUpdateMetadataUrlForRoute('$prefix$_githubMetadata'),
          isFalse,
        );
        expect(
          isAllowedUpdateMetadataUrlForRoute('$prefix$_giteeMetadata'),
          isFalse,
        );
      }
      expect(
        isAllowedUpdateMetadataUrlForRoute(
          'https://ghfast.top/https://example.com/version.json',
        ),
        isFalse,
      );
      expect(
        isAllowedUpdateMetadataUrlForRoute(
          'https://ghfast.top/https://api.github.com/repos/'
          'Triangle-Wave/Pure-music/releases/latest',
        ),
        isFalse,
      );
    });

    test('rejects the retired Gitee slug on Gitee', () {
      expect(
        isAllowedUpdateDownloadUrlForRoute(
          'https://gitee.com/Triangle-Wave/Pure-music/releases/download/'
          'v2.3.9/app.exe',
        ),
        isFalse,
      );
    });
  });

  group('settings', () {
    test('parses persisted route names', () {
      expect(UpdateDownloadRoute.parse('auto'), UpdateDownloadRoute.auto);
      expect(UpdateDownloadRoute.parse('github'), UpdateDownloadRoute.github);
      expect(UpdateDownloadRoute.parse('gitee'), UpdateDownloadRoute.gitee);
      expect(UpdateDownloadRoute.parse('proxy'), UpdateDownloadRoute.proxy);
      expect(UpdateDownloadRoute.parse('unknown'), UpdateDownloadRoute.auto);
      expect(UpdateDownloadRoute.parse(null), UpdateDownloadRoute.auto);
    });

    test('defaults to auto and reads a stored route', () {
      final preference = AppPreference();
      preference.applyStoredMap(const {});
      expect(preference.updateDownloadRoute, UpdateDownloadRoute.auto);

      preference.applyStoredMap({'updateDownloadRoute': 'proxy'});
      expect(preference.updateDownloadRoute, UpdateDownloadRoute.proxy);

      preference.applyStoredMap({'updateDownloadRoute': 'gitee'});
      expect(preference.updateDownloadRoute, UpdateDownloadRoute.gitee);
    });
  });
}
