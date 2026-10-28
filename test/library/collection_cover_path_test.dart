import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/library/audio_library.dart';

Audio _audio(String path) => Audio(
  'Title',
  'Artist',
  'Album',
  null,
  1,
  60,
  320,
  44100,
  path,
  1,
  1,
  'test',
);

void main() {
  test('virtual track primary path resolves to the source file', () {
    final source = p.join(r'C:\Music', '告白.tak');
    final virtualPath = '$source::track=01::start=0::end=275640';
    final audio = _audio(virtualPath);
    final album = Album(name: '告白')..works = [audio];
    final artist = Artist(name: 'azusa')..works = [audio];

    expect(audio.filePath, source);
    expect(album.primaryPath, source);
    expect(artist.primaryPath, source);
    expect(album.identityPath, virtualPath);
    expect(artist.identityPath, virtualPath);
  });

  test('primary path equals path for regular audio', () {
    final audio = _audio(r'C:\Music\song.flac');
    final album = Album(name: 'Album')..works = [audio];
    final artist = Artist(name: 'Artist')..works = [audio];

    expect(album.primaryPath, audio.path);
    expect(artist.primaryPath, audio.path);
    expect(album.identityPath, audio.path);
  });

  test('primary path is null for an empty collection', () {
    final album = Album(name: 'Album');
    final artist = Artist(name: 'Artist');

    expect(album.primaryPath, isNull);
    expect(artist.primaryPath, isNull);
    expect(album.identityPath, isNull);
    expect(artist.identityPath, isNull);
  });
}
