import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/library/virtual_track_index.dart';

Audio _audio(String path) => Audio(
  'Track',
  'Artist',
  'Album',
  null,
  1,
  100,
  320,
  44100,
  path,
  1,
  1,
  'cue',
);

void main() {
  test('indexes virtual tracks by cue source path', () {
    final tracks = [
      _audio(r'D:\Music\Album\disc.flac::track=02::start=1000::end=2000'),
      _audio(r'D:\Music\Album\disc.flac::track=01::start=0::end=1000'),
      _audio(r'D:\Music\Album\single.flac'),
    ];
    final index = VirtualTrackIndex.fromAudios(tracks);

    final expanded = index.tracksForSource(r'd:/music/album/DISC.flac');

    expect(expanded.map((audio) => audio.cueSegment!.trackNumber), [1, 2]);
    expect(index.tracksForSource(r'D:\Music\Album\single.flac'), isEmpty);
  });

  test('expands cue and sacd sources into every virtual track once', () {
    const cuePaths = [
      r'D:\Music\Album\disc.flac::track=01::start=0::end=1000',
      r'D:\Music\Album\disc.flac::track=02::start=1000::end=2000',
    ];
    const sacdPaths = [
      r'D:\Music\SACD\album.iso::track=01::start=0::end=90000::sacd=2ch',
      r'D:\Music\SACD\album.iso::track=02::start=90000::end=180000::sacd=2ch',
    ];
    const plainPath = r'D:\Music\Album\plain.mp3';
    final audios = [
      for (final path in cuePaths) _audio(path),
      for (final path in sacdPaths) _audio(path),
      _audio(plainPath),
    ];

    final resolved = resolveImportedLibraryPaths(
      rawPaths: [
        r'D:\Music\Album\disc.flac',
        r'D:\Music\Album\disc.flac',
        plainPath,
        r'D:\Music\Album\inner.cue',
        r'D:\Music\SACD\album.iso',
      ],
      virtualTracks: VirtualTrackIndex.fromAudios(audios),
      libraryPaths: audios.map((audio) => audio.path),
    );

    expect(resolved, [...cuePaths, plainPath, ...sacdPaths]);
  });

  test('matches a cue source by file name without changing the library path', () {
    const libraryPath =
        r'D:\Music\Album\disc.flac::track=01::start=0::end=1000';

    expect(
      findImportedPlaylistLibraryPath(
        rawPath: r'C:\incoming\disc.flac',
        libraryPaths: [libraryPath],
      ),
      libraryPath,
    );
    expect(
      findImportedPlaylistLibraryPath(
        rawPath: r'D:\Music\Album\disc.flac::track=02::start=1000::end=2000',
        libraryPaths: [libraryPath],
      ),
      isNull,
    );
  });

  test('expands a bare source file name from m3u into all virtual tracks', () {
    const cuePaths = [
      r'D:\Music\Album\disc.flac::track=01::start=0::end=1000',
      r'D:\Music\Album\disc.flac::track=02::start=1000::end=2000',
    ];
    final audios = [for (final path in cuePaths) _audio(path)];

    final resolved = resolveImportedLibraryPaths(
      rawPaths: [r'Z:\NotExisting\disc.flac'],
      virtualTracks: VirtualTrackIndex.fromAudios(audios),
      libraryPaths: audios.map((audio) => audio.path),
      preferExistingFile: true,
    );

    expect(resolved, cuePaths);
  });

  test('keeps an existing library path for a concrete virtual track', () {
    const libraryPath =
        r'D:\Music\Album\disc.flac::track=01::start=0::end=1000';
    final audios = [_audio(libraryPath)];

    final resolved = resolveImportedLibraryPaths(
      rawPaths: [libraryPath],
      virtualTracks: VirtualTrackIndex.fromAudios(audios),
      libraryPaths: [libraryPath],
    );

    expect(resolved, [libraryPath]);
  });
}
