import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/cue_segment_path.dart';

/// 文件夹歌单导入时识别的文件扩展名。
///
/// 音频部分与 Rust 扫描器的 SUPPORTED_FORMATS 一致；`cue` 与 `iso` 本身
/// 不直接播放，但需要被收集后展开为整轨引用出的虚拟轨。
const Set<String> importableAudioFileExtensions = <String>{
  'mp3',
  'mp2',
  'mp1',
  'mpa',
  'ogg',
  'oga',
  'opus',
  'spx',
  'wav',
  'wave',
  'aif',
  'aiff',
  'aifc',
  'afc',
  'asf',
  'wma',
  'aac',
  'adts',
  'm4a',
  'mp4',
  'm4b',
  'm4p',
  'm4r',
  'm4v',
  '3gp',
  '3g2',
  'mka',
  'mkv',
  'webm',
  'weba',
  'caf',
  'ac3',
  'a52',
  'amr',
  '3ga',
  'flac',
  'mpc',
  'mp+',
  'mpp',
  'mid',
  'midi',
  'kar',
  'rmi',
  'wv',
  'dsf',
  'dff',
  'ape',
  'cue',
  'iso',
};

/// 与曲库查找一致的路径键：去空格、统一分隔符、去尾部斜杠、转小写。
String normalizeAudioLibraryPathKey(String value) {
  var normalized = value.trim().replaceAll('\\', '/');
  while (normalized.endsWith('/') && normalized.length > 1) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized.toLowerCase();
}

/// 剥离虚拟轨合成路径的 `::` 后缀；普通路径原样返回。
String virtualTrackSourcePath(String path) {
  return parseCueSegmentPath(path)?.sourcePath ?? path;
}

String importedPlaylistBasenameKey(String value) {
  return p.basename(value.trim()).toLowerCase();
}

/// 按文件名在曲库路径中查找导入项，合成路径先按原样精确比较，
/// 再退回“剥离 `::` 后缀后的源文件名”比较。
String? findLibraryPathByImportedFileName({
  required String rawPath,
  required Iterable<String> libraryPaths,
}) {
  final rawKey = importedPlaylistBasenameKey(rawPath);
  if (rawKey.isEmpty) return null;
  final rawSourceKey = importedPlaylistBasenameKey(
    virtualTrackSourcePath(rawPath),
  );
  final rawSegment = parseCueSegmentPath(rawPath);
  String? sourceFallback;
  for (final libraryPath in libraryPaths) {
    if (importedPlaylistBasenameKey(libraryPath) == rawKey) {
      return libraryPath;
    }
    if (sourceFallback != null) continue;
    if (importedPlaylistBasenameKey(virtualTrackSourcePath(libraryPath)) !=
        rawSourceKey) {
      continue;
    }
    final librarySegment = parseCueSegmentPath(libraryPath);
    if (rawSegment != null &&
        librarySegment != null &&
        (rawSegment.trackNumber != librarySegment.trackNumber ||
            rawSegment.sacdArea != librarySegment.sacdArea)) {
      continue;
    }
    sourceFallback = libraryPath;
  }
  return sourceFallback;
}

/// 曲库虚拟轨按“源文件路径”建立的索引。
class VirtualTrackIndex {
  VirtualTrackIndex._(this._tracksBySourcePath);

  final Map<String, List<Audio>> _tracksBySourcePath;

  static final VirtualTrackIndex empty = VirtualTrackIndex._(
    const <String, List<Audio>>{},
  );

  /// 扫描曲目集合，收录 CUE / SACD 虚拟轨。
  ///
  /// 同一源文件展开出的多条虚拟轨按区、轨号、起点排序，保证导入顺序稳定。
  factory VirtualTrackIndex.fromAudios(Iterable<Audio> audios) {
    try {
      final grouped = <String, List<Audio>>{};
      for (final audio in audios) {
        final segment = audio.cueSegment;
        if (segment == null) continue;
        final key = normalizeAudioLibraryPathKey(segment.sourcePath);
        if (key.isEmpty) continue;
        grouped.putIfAbsent(key, () => <Audio>[]).add(audio);
      }
      for (final tracks in grouped.values) {
        tracks.sort(_compareVirtualTracks);
      }
      return VirtualTrackIndex._(grouped);
    } catch (err, trace) {
      log.library.error(
        'legacy',
        '构建虚拟轨索引失败',
        error: err,
        stackTrace: trace,
      );
      return VirtualTrackIndex.empty;
    }
  }

  /// 返回源文件展开出的全部虚拟轨；普通文件返回空列表。
  List<Audio> tracksForSource(String sourcePath) {
    final key = normalizeAudioLibraryPathKey(sourcePath);
    if (key.isEmpty) return const <Audio>[];
    return _tracksBySourcePath[key] ?? const <Audio>[];
  }

  bool hasSource(String sourcePath) {
    final key = normalizeAudioLibraryPathKey(sourcePath);
    return key.isNotEmpty && _tracksBySourcePath.containsKey(key);
  }

  static int _compareVirtualTracks(Audio a, Audio b) {
    final segmentA = a.cueSegment;
    final segmentB = b.cueSegment;
    if (segmentA == null || segmentB == null) return 0;
    final areaOrder = (segmentA.sacdArea ?? '').compareTo(
      segmentB.sacdArea ?? '',
    );
    if (areaOrder != 0) return areaOrder;
    final trackOrder = segmentA.trackNumber.compareTo(segmentB.trackNumber);
    if (trackOrder != 0) return trackOrder;
    return segmentA.startMs.compareTo(segmentB.startMs);
  }
}

/// 把外部导入路径解析为可写入歌单的曲库路径。
///
/// 规则：
/// 1. 路径是虚拟轨源文件（CUE 引用的整轨音频、SACD ISO）时，展开为全部虚拟轨；
/// 2. `preferExistingFile` 为真时，磁盘上存在的普通文件保留原路径；
/// 3. 曲库中存在的路径按规范化键匹配并保留曲库写法；
/// 4. 其余退回文件名匹配。
///
/// 结果按规范化路径去重，同一虚拟轨只出现一次。
List<String> resolveImportedLibraryPaths({
  required Iterable<String> rawPaths,
  required VirtualTrackIndex virtualTracks,
  required Iterable<String> libraryPaths,
  bool preferExistingFile = false,
}) {
  final resolved = <String>[];
  final seenKeys = <String>{};
  final libraryPathList = libraryPaths.toList(growable: false);
  final libraryPathByKey = <String, String>{};
  for (final path in libraryPathList) {
    final key = normalizeAudioLibraryPathKey(path);
    if (key.isEmpty) continue;
    libraryPathByKey.putIfAbsent(key, () => path);
  }

  void add(String path) {
    final key = normalizeAudioLibraryPathKey(path);
    if (key.isEmpty || !seenKeys.add(key)) return;
    resolved.add(path);
  }

  for (final raw in rawPaths) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;

    final virtualTracksForSource = virtualTracks.tracksForSource(trimmed);
    if (virtualTracksForSource.isNotEmpty) {
      for (final track in virtualTracksForSource) {
        add(track.path);
      }
      continue;
    }

    if (preferExistingFile) {
      try {
        if (File(trimmed).existsSync()) {
          add(trimmed);
          continue;
        }
      } catch (err, trace) {
        log.library.error(
          'legacy',
          '检查导入文件是否存在失败：$trimmed',
          error: err,
          stackTrace: trace,
        );
      }
    }

    final exact = libraryPathByKey[normalizeAudioLibraryPathKey(trimmed)];
    if (exact != null) {
      add(exact);
      continue;
    }

    final matched = findLibraryPathByImportedFileName(
      rawPath: trimmed,
      libraryPaths: libraryPathList,
    );
    if (matched == null) continue;
    final matchedSegment = parseCueSegmentPath(matched);
    // 导入项只给了源文件名时，命中的虚拟轨应展开为同源的全部轨道。
    if (parseCueSegmentPath(trimmed) == null && matchedSegment != null) {
      for (final track in virtualTracks.tracksForSource(
        matchedSegment.sourcePath,
      )) {
        add(track.path);
      }
      continue;
    }
    add(matched);
  }

  return resolved;
}
