import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/matcher.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/window_render_gate.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_widget.dart';
import 'package:pure_music/play_service/play_service.dart';

typedef _SetProcessWorkingSetSizeNative =
    ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr, ffi.IntPtr);
typedef _SetProcessWorkingSetSizeDart = int Function(int, int, int);

/// 内存监控服务：定时检查 RSS，分级清理缓存。
/// 窗口不可见时换出工作集页：最小化只换出，托盘隐藏额外卸界面并清图片/排版缓存。
class MemoryMonitorService {
  static final instance = MemoryMonitorService._();
  MemoryMonitorService._();

  Timer? _timer;
  Timer? _settleTrimTimer;
  Timer? _settleTrimFollowUpTimer;
  Timer? _hiddenTrimTimer;
  Listenable? _hiddenNowPlaying;
  String? _hiddenSongPath;
  DateTime? _lastTier1CleanupAt;
  DateTime? _lastTier2CleanupAt;
  DateTime? _lastTier3CleanupAt;

  static ffi.DynamicLibrary? _kernel32;
  static _SetProcessWorkingSetSizeDart? _setProcessWorkingSetSize;

  /// 把工作集页换出到备用列表。只动内存页，不碰音频缓冲，也不丢缓存数据。
  void _trimWorkingSet() {
    try {
      _kernel32 ??= ffi.DynamicLibrary.open('kernel32.dll');
      _setProcessWorkingSetSize ??= _kernel32!
          .lookupFunction<
            _SetProcessWorkingSetSizeNative,
            _SetProcessWorkingSetSizeDart
          >('SetProcessWorkingSetSize');
      // 传 -1/-1 等于 EmptyWorkingSet。
      _setProcessWorkingSetSize!(-1, -1, -1);
    } catch (_) {
      _setProcessWorkingSetSize = null;
    }
  }

  /// 隐藏期间定时换出工作集：先等界面落定，再按间隔补。
  void _holdWorkingSetWhileHidden(Duration interval) {
    _armSettleTrim();
    _hiddenTrimTimer?.cancel();
    _hiddenTrimTimer = Timer.periodic(interval, (_) {
      if (WindowRenderGate.instance.framesEnabled.value) return;
      _trimWorkingSet();
    });
    _watchHiddenSongChange();
  }

  void _armSettleTrim() {
    _settleTrimTimer?.cancel();
    _settleTrimTimer = Timer(const Duration(seconds: 3), () {
      _settleTrimTimer = null;
      if (WindowRenderGate.instance.framesEnabled.value) return;
      _trimWorkingSet();
    });
  }

  /// 隐藏时切歌会重新分配歌词、封面和缩略图，等 3 秒再补一次换出，把刚涨上来的页推回备用列表。
  void _watchHiddenSongChange() {
    final notifier = PlayService.existingPlaybackService?.nowPlayingNotifier;
    if (identical(notifier, _hiddenNowPlaying)) return;
    _hiddenNowPlaying?.removeListener(_onHiddenSongChanged);
    _hiddenNowPlaying = notifier;
    _hiddenSongPath = PlayService.existingPlaybackService?.nowPlaying?.path;
    notifier?.addListener(_onHiddenSongChanged);
  }

  void _onHiddenSongChanged() {
    final path = PlayService.existingPlaybackService?.nowPlaying?.path;
    if (path == _hiddenSongPath) return;
    _hiddenSongPath = path;
    if (WindowRenderGate.instance.framesEnabled.value) return;
    _armSettleTrim();
    // 切歌后的分配会持续几秒，3 秒那次之后再补一次。
    _settleTrimFollowUpTimer?.cancel();
    _settleTrimFollowUpTimer = Timer(const Duration(seconds: 8), () {
      _settleTrimFollowUpTimer = null;
      if (WindowRenderGate.instance.framesEnabled.value) return;
      _trimWorkingSet();
    });
  }

  /// 回到前台：停掉隐藏期间的换出，缓存和页面都不动。
  void stopHiddenTrim() {
    _settleTrimTimer?.cancel();
    _settleTrimTimer = null;
    _settleTrimFollowUpTimer?.cancel();
    _settleTrimFollowUpTimer = null;
    _hiddenTrimTimer?.cancel();
    _hiddenTrimTimer = null;
    _hiddenNowPlaying?.removeListener(_onHiddenSongChanged);
    _hiddenNowPlaying = null;
    _hiddenSongPath = null;
  }

  bool _cleanupDue(DateTime now, DateTime? lastRun, Duration cooldown) =>
      lastRun == null || now.difference(lastRun) >= cooldown;

  /// 播放中的画面会持续复用图片、文字和图形缓存，不能按 RSS 周期清空。
  bool _isPlaying() {
    try {
      final state = PlayService.existingPlaybackService?.playerState;
      return state == PlayerState.playing || state == PlayerState.stalled;
    } catch (_) {
      return false;
    }
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      try {
        _checkMemoryPressure();
      } catch (e, trace) {
        log.memory.error('legacy', '[mem] monitor error: $e\n$trace');
      }
    });
  }

  void _checkMemoryPressure() {
    final rssMB = (ProcessInfo.currentRss / (1024 * 1024)).round();
    final playbackService = PlayService.existingPlaybackService;
    final nowPlaying = playbackService?.nowPlaying;
    final playingPath = nowPlaying?.path;
    final playingFilePath = nowPlaying?.filePath;
    final now = DateTime.now();
    if (_isPlaying()) {
      if (Platform.environment['CP_MEMORY_LOG'] == '1') {
        CoverImageCache.instance.logStats();
      }
      return;
    }
    const tier1Threshold = 220;
    const tier2Threshold = 260;
    const tier3Threshold = 320;
    if (rssMB > tier3Threshold &&
        _cleanupDue(now, _lastTier3CleanupAt, const Duration(minutes: 1))) {
      _runTier3Cleanup(
        now,
        playingPath,
        playingFilePath,
        rssMB,
        tier3Threshold,
      );
    } else if (rssMB > tier2Threshold &&
        _cleanupDue(now, _lastTier2CleanupAt, const Duration(minutes: 3))) {
      _runTier2Cleanup(now, playingFilePath, rssMB, tier2Threshold);
    } else if (rssMB > tier1Threshold &&
        _cleanupDue(now, _lastTier1CleanupAt, const Duration(minutes: 1))) {
      _runTier1Cleanup(now);
    }
    if (Platform.environment['CP_MEMORY_LOG'] == '1') {
      CoverImageCache.instance.logStats();
    }
  }

  void _runTier3Cleanup(
    DateTime now,
    String? playingPath,
    String? playingFilePath,
    int rssMB,
    int tier3Threshold,
  ) {
    _lastTier1CleanupAt = now;
    _lastTier2CleanupAt = now;
    _lastTier3CleanupAt = now;
    log.memory.warn(
      'legacy',
      '[mem] RSS ${rssMB}MB > $tier3Threshold, tier-3 emergency cleanup',
    );
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    CoverImageCache.instance.trimMemory(keepPath: playingFilePath);
    CoverImageCache.instance.trimSmall(keepEntries: 24);
    AudioLibrary.instance.trimCollectionThumbnailRetention(32);
    LyricsLinePainter.clearPool();
    LyricsLineWidget.clearBlurFilterCache();
    AudioLibrary.instance.evictAllCoversExcept(
      playingPath,
      includeCollectionCovers: true,
    );
    clearLyricCaches();
  }

  void _runTier2Cleanup(
    DateTime now,
    String? playingFilePath,
    int rssMB,
    int tier2Threshold,
  ) {
    _lastTier1CleanupAt = now;
    _lastTier2CleanupAt = now;
    log.memory.warn(
      'legacy',
      '[mem] RSS ${rssMB}MB > $tier2Threshold, tier-2 cleanup',
    );
    CoverImageCache.instance.trimMemory(keepPath: playingFilePath);
    CoverImageCache.instance.trimSmall(keepEntries: 64);
    AudioLibrary.instance.trimCollectionThumbnailRetention(80);
    LyricsLinePainter.trimPool();
    LyricsLineWidget.clearBlurFilterCache();
    AudioLibrary.instance.evictStaleCoverBytes();
  }

  void _runTier1Cleanup(DateTime now) {
    _lastTier1CleanupAt = now;
    AudioLibrary.instance.trimCollectionThumbnailRetention(128);
    LyricsLinePainter.trimPool();
    AudioLibrary.instance.evictStaleCoverBytes();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    stopHiddenTrim();
  }

  void trimAfterSongChange() {
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.filePath;
    AudioLibrary.instance.evictStaleCoverBytes();
    AudioLibrary.instance.trimCollectionThumbnailRetention(96);
    CoverImageCache.instance.trimMemory(keepPath: playingPath);
    CoverImageCache.instance.trimSmall(keepEntries: 64);
  }

  /// 托盘驻留清理：释放大图/位图等大头，但保留 48px 小图与当前曲目，
  /// 保证恢复窗口时列表不卡；隐藏期间按间隔换出工作集页。
  void trimTrayHidden() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.filePath;
    CoverImageCache.instance.trimMemory(keepPath: playingPath);
    CoverImageCache.instance.trimSmall(keepEntries: 96);
    AudioLibrary.instance.trimCollectionThumbnailRetention(128);
    LyricsLinePainter.trimPool();
    LyricsLineWidget.clearBlurFilterCache();
    AudioLibrary.instance.evictStaleCoverBytes();
    _holdWorkingSetWhileHidden(const Duration(seconds: 15));
  }

  /// 任务栏最小化清理：只回收可重建的非当前资源，保留恢复所需的页面对象；
  /// 界面还在，只换出工作集页，不按 RSS 瘦身。
  void trimWindowMinimized() {
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.filePath;
    PaintingBinding.instance.imageCache.clear();
    CoverImageCache.instance.trimMemory(keepPath: playingPath);
    CoverImageCache.instance.trimSmall(keepEntries: 128);
    AudioLibrary.instance.trimCollectionThumbnailRetention(128);
    LyricsLinePainter.trimPool();
    LyricsLineWidget.clearBlurFilterCache();
    AudioLibrary.instance.evictStaleCoverBytes();
    _holdWorkingSetWhileHidden(const Duration(seconds: 30));
  }

  /// 强制释放可回收内存，用于窗口最小化/低内存通知等场景
  void trimAll() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    CoverImageCache.instance.trimMemory();
    CoverImageCache.instance.clear();
    AudioLibrary.instance.trimCollectionThumbnailRetention(0);
    LyricsLinePainter.clearPool();
    LyricsLineWidget.clearBlurFilterCache();
    AudioLibrary.instance.evictAllCoversExcept(
      PlayService.existingPlaybackService?.nowPlaying?.path,
      includeCollectionCovers: true,
    );
  }
}
