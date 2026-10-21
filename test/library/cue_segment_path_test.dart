import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/cue_segment_path.dart';

void main() {
  test('parses a synthetic cue path', () {
    final segment = parseCueSegmentPath(
      r'D:\Music\Album\disc.flac::track=02::start=1000::end=201000',
    );

    expect(segment, isNotNull);
    expect(segment!.sourcePath, r'D:\Music\Album\disc.flac');
    expect(segment.trackNumber, 2);
    expect(segment.startMs, 1000);
    expect(segment.endMs, 201000);
    expect(segment.durationMs, 200000);
  });

  test('keeps chinese, spaces and brackets in the source path', () {
    final segment = parseCueSegmentPath(
      r'F:\MyMusic\CD\白色相簿 [SACD]\disc 01.flac::track=12::start=0::end=300000',
    );

    expect(segment, isNotNull);
    expect(segment!.sourcePath, r'F:\MyMusic\CD\白色相簿 [SACD]\disc 01.flac');
    expect(segment.trackNumber, 12);
  });

  test('returns null for a normal file path', () {
    expect(parseCueSegmentPath(r'D:\Music\Album\disc.flac'), isNull);
    expect(parseCueSegmentPath(''), isNull);
  });

  test('rejects malformed paths', () {
    expect(parseCueSegmentPath('::track=01::start=0::end=1000'), isNull);
    expect(parseCueSegmentPath('disc.flac::track=01::start=0'), isNull);
    expect(parseCueSegmentPath('disc.flac::track=01::start=0::end=1000::x=1'), isNull);
    expect(parseCueSegmentPath('disc.flac::track=x::start=0::end=1000'), isNull);
    expect(parseCueSegmentPath('disc.flac::track=01::start=x::end=1000'), isNull);
    expect(parseCueSegmentPath('disc.flac::track=01::start=0::end=x'), isNull);
  });

  test('rejects inverted or non-positive ranges', () {
    expect(parseCueSegmentPath('disc.flac::track=01::start=1000::end=0'), isNull);
    expect(parseCueSegmentPath('disc.flac::track=00::start=0::end=1000'), isNull);
  });

  test('accepts a zero-length range', () {
    final segment = parseCueSegmentPath(
      'disc.flac::track=03::start=1000::end=1000',
    );

    expect(segment, isNotNull);
    expect(segment!.durationMs, 0);
  });

  test('parses a synthetic sacd path', () {
    final segment = parseCueSegmentPath(
      r'D:\Music\SACD\album.iso::track=02::start=1000::end=201000::sacd=2ch',
    );

    expect(segment, isNotNull);
    expect(segment!.sourcePath, r'D:\Music\SACD\album.iso');
    expect(segment.trackNumber, 2);
    expect(segment.startMs, 1000);
    expect(segment.endMs, 201000);
    expect(segment.sacdArea, '2ch');
    expect(segment.isSacd, isTrue);
    expect(
      segment.trackUid,
      r'sacd:d:/music/sacd/album.iso#2ch#02',
    );
  });

  test('parses both sacd areas', () {
    for (final area in ['2ch', 'mch']) {
      final segment = parseCueSegmentPath(
        'album.iso::track=12::start=0::end=90000::sacd=$area',
      );

      expect(segment, isNotNull);
      expect(segment!.sacdArea, area);
      expect(segment.trackUid, 'sacd:album.iso#$area#12');
    }
  });

  test('rejects unknown sacd areas', () {
    expect(
      parseCueSegmentPath(
        'album.iso::track=01::start=0::end=1000::sacd=5.1',
      ),
      isNull,
    );
    expect(
      parseCueSegmentPath('album.iso::track=01::start=0::end=1000::sacd='),
      isNull,
    );
    expect(
      parseCueSegmentPath('album.iso::track=01::start=0::end=1000::other=2ch'),
      isNull,
    );
  });

  test('keeps cue paths without a sacd area', () {
    final segment = parseCueSegmentPath(
      r'D:\Music\CD\disc.flac::track=01::start=0::end=1000',
    );

    expect(segment, isNotNull);
    expect(segment!.sacdArea, isNull);
    expect(segment.isSacd, isFalse);
    expect(segment.trackUid, r'cue:d:/music/cd/disc.flac#01');
  });
}
