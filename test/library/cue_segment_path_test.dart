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
}
