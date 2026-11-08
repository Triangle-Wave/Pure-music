// ignore_for_file: camel_case_types

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math';
import 'dart:ui';

import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/component/hotkey_ui_feedback.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/page/now_playing_page/now_playing_open_transition.dart';
import 'package:pure_music/component/side_nav.dart';
import 'package:pure_music/component/title_bar.dart';
import 'package:pure_music/core/menu_styles.dart';
import 'package:pure_music/core/color_extraction.dart';
import 'package:pure_music/core/collection_link_target.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/memory_monitor.dart';
import 'package:pure_music/core/now_playing_perf_probe.dart';
import 'package:pure_music/core/sleep_blocker.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/hotkey_binding.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/immersive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/system_volume_service.dart';
import 'package:pure_music/core/ticker_timing.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/window_render_gate.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/page/now_playing_page/component/concert_act_cue.dart';
import 'package:pure_music/page/now_playing_page/component/concert_act_label.dart';
import 'package:pure_music/services/concert_session.dart';
import 'package:pure_music/page/now_playing_page/component/current_playlist_view.dart';
import 'package:pure_music/page/now_playing_page/component/equalizer_dialog.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_source_view.dart';
import 'package:pure_music/page/now_playing_page/component/sleep_timer_dialog.dart';
import 'package:pure_music/page/now_playing_page/component/pitch_control.dart';
import 'package:pure_music/page/now_playing_page/component/player_chrome_foreground.dart';
import 'package:pure_music/page/now_playing_page/component/spectrum_bar.dart';
import 'package:pure_music/page/now_playing_page/component/vertical_lyric_view.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background.dart';
import 'package:pure_music/page/now_playing_page/now_playing_visibility.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_collapsible_chrome.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_small_view_switch.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

part 'small_page.dart';
part 'large_page.dart';
part 'immersive_page.dart';

final nowPlayingViewMode = ValueNotifier(
  AppPreference.instance.nowPlayingPagePref.nowPlayingViewMode,
);

/// 音量面板是否展开；展开期间暂停播放页光标自动隐藏。
final ValueNotifier<bool> nowPlayingVolumePanelOpen = ValueNotifier(false);

/// 切换播放页视图：更新全局模式并写入偏好，写盘失败只记录日志。
void switchNowPlayingView(NowPlayingViewMode mode) {
  if (nowPlayingViewMode.value == mode) return;
  nowPlayingViewMode.value = mode;
  AppPreference.instance.nowPlayingPagePref.nowPlayingViewMode = mode;
  unawaited(_saveNowPlayingViewMode(mode));
}

/// 播放列表展示时，点击列表以外的区域回到歌词。
void exitPlaylistToLyric() {
  if (nowPlayingViewMode.value != NowPlayingViewMode.withPlaylist) return;
  switchNowPlayingView(NowPlayingViewMode.withLyric);
}

Future<void> _saveNowPlayingViewMode(NowPlayingViewMode mode) async {
  try {
    final saved = await AppPreference.instance.save();
    if (!saved) {
      log.app.debug(
        'now_playing_view_mode_persist_failed',
        '播放页视图偏好写盘未成功',
        fields: {'mode': mode.name},
      );
    }
  } catch (error) {
    log.app.debug(
      'now_playing_view_mode_persist_failed',
      '保存播放页视图偏好失败',
      fields: {'mode': mode.name, 'error': error.runtimeType.toString()},
    );
  }
}

/// 普通播放页切到紧凑布局的宽度上限：右下角控件组加入歌手、专辑入口后
/// 需要更宽的窗口才能与中组拉开距离。
const double _nowPlayingLargeLayoutMinWidth = 1000.0;

bool _usesCompactNowPlayingLayout(BuildContext context, ScreenType screenType) {
  return screenType == ScreenType.small ||
      MediaQuery.orientationOf(context) == Orientation.portrait;
}

double _responsiveNowPlayingCoverSize({
  required double maxWidth,
  required double maxHeight,
}) {
  const textAreaHeight = 80.0;
  const compactExtent = 420.0;
  const roomyExtent = 920.0;
  final availableExtent = min(maxWidth, max(0.0, maxHeight - textAreaHeight));
  final growth =
      ((availableExtent - compactExtent) / (roomyExtent - compactExtent))
          .clamp(0.0, 1.0)
          .toDouble();
  // 封面占可用区比例：紧凑窗口 0.55，宽裕窗口 0.60
  final fillFraction = lerpDouble(0.55, 0.60, growth)!;
  return availableExtent * fillFraction;
}

// 沉浸模式封面下方区域高度（24 间距 + 进度条 40）
const _immersiveCoverBelowHeight = 64.0;

// 普通横屏模式下信息区底部控制区高度（进度条约40 + 控制行64 + 底部留白12）。
// 两种横屏模式的封面垂直居中于整个窗口：普通模式从信息区中心下移该值的一半，
// 沉浸模式从整列中心下移封面下方区域的一半，两者落点一致。
const _normalLandscapeBottomAreaHeight = 116.0;

double _portraitNowPlayingCoverSize({
  required double maxWidth,
  required double maxHeight,
}) {
  const textAreaHeight = 80.0;
  const maxPortraitCoverSize = 420.0;
  final coverAreaHeight = max(0.0, maxHeight - textAreaHeight);
  return min(maxWidth, min(coverAreaHeight, maxPortraitCoverSize));
}

class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key});

  static Future<void> precacheBackgrounds() => NowPlayingBackground.precache();

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  final playbackService = PlayService.instance.playbackService;
  Uint8List? _nowPlayingCoverBytes;
  String? _nowPlayingCoverPath;
  // 封面字节来源等级：0无 1小封面缩略 2详情封面 3高清缓存，只升不降。
  int _coverBytesLevel = 0;
  Timer? _coverDebounceTimer;
  Timer? _songChangeTrimTimer;
  Timer? _cursorHideTimer;
  Animation<double>? _routeAnimation;
  int _coverRequestToken = 0;
  final ValueNotifier<bool> _cursorHiddenNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _routeReadyNotifier = ValueNotifier(false);
  bool _lastImmersive = false;
  bool _routeReady = false;
  bool _sessionShown = true;
  bool _backgroundUsesCachedLargeCover = false;
  late final Listenable _backgroundListenable;
  Color? _dominantColor;
  List<Color>? _preExtractedPalette;
  String? _palettePath;
  final ColorExtractionService _colorService = ColorExtractionService();

  /// 用于防重复：同一次切歌内只提取一次调色板

  void _bumpCursor() {
    _cursorHideTimer?.cancel();
    _cursorHiddenNotifier.value = false;
    // 音量面板展开期间保持光标可见：隐藏光标层会接管命中测试，
    // 让音量按钮收到 onExit 并触发悬停关闭。
    if (nowPlayingVolumePanelOpen.value) return;
    _cursorHideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      _cursorHiddenNotifier.value = true;
    });
  }

  /// Guard against race conditions in async cover loading.
  /// Returns true if the request is stale and should be aborted.
  bool _isCoverRequestStale(int token, String expectedPath) {
    return token != _coverRequestToken ||
        playbackService.nowPlaying?.path != expectedPath ||
        !_routeReady ||
        !mounted;
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    final ready = status == AnimationStatus.completed;
    if (_routeReady == ready) return;
    _routeReady = ready;
    _routeReadyNotifier.value = ready;
    if (ready) {
      _scheduleCoverDetails();
    } else {
      _coverDebounceTimer?.cancel();
    }
  }

  void _scheduleCoverDetails() {
    _coverDebounceTimer?.cancel();
    final path = _nowPlayingCoverPath;
    if (!_routeReady || path == null) return;
    if (_backgroundUsesCachedLargeCover &&
        _palettePath == path &&
        _preExtractedPalette != null) {
      return;
    }
    final token = _coverRequestToken;

    _coverDebounceTimer = Timer(
      MotionDuration.xFast,
      () => _loadCoverDetails(token, path),
    );
  }

  Future<void> _loadCoverDetails(int token, String path) async {
    final audio = playbackService.nowPlaying;
    if (audio == null || _isCoverRequestStale(token, path)) return;
    final modified = audio.modified;
    final cachedPalette = _colorService.getCachedPaletteForPath(
      path,
      modified: modified,
    );
    final loaded = await _loadCoverBytesAndPalette(
      path,
      modified,
      cachedPalette,
    );
    if (_isCoverRequestStale(token, path)) return;
    _applyLoadedCover(path, modified, loaded.bytes, loaded.palette);
    if (mounted) setState(() {});
    NowPlayingPerfProbe.instance.onCoverVisible(
      fromCache: cachedPalette != null && cachedPalette.isNotEmpty,
    );
  }

  Future<({Uint8List? bytes, List<Color>? palette})> _loadCoverBytesAndPalette(
    String path,
    int modified,
    List<Color>? cachedPalette,
  ) async {
    if (cachedPalette != null && cachedPalette.isNotEmpty) {
      final bytes = await CoverImageCache.instance.loadBytes(
        path: path,
        modified: modified,
        width: 160,
        height: 160,
      );
      return (bytes: bytes, palette: cachedPalette);
    }
    developer.Timeline.startSync('cover.extractColors');
    late final Uint8List? loadedBytes;
    late final List<int> rustColors;
    try {
      final result = await getPictureAndColors(
        path: path,
        width: 160,
        height: 160,
        numColors: 8,
      );
      loadedBytes = result.$1;
      rustColors = result.$2;
      if (loadedBytes != null) {
        CoverImageCache.instance.putDecodedBytes(
          path: path,
          width: 160,
          height: 160,
          bytes: loadedBytes,
          modified: modified,
        );
      }
    } finally {
      developer.Timeline.finishSync();
    }
    return (
      bytes: loadedBytes,
      palette: rustColors.isNotEmpty
          ? rustColors.map((argb) => Color(argb)).toList()
          : null,
    );
  }

  void _applyLoadedCover(
    String path,
    int modified,
    Uint8List? bytes,
    List<Color>? palette,
  ) {
    // 160px 详情只补小封面的缺，不覆盖高清缓存，也不重复写同级字节。
    if (bytes != null && _coverBytesLevel < 2) {
      _nowPlayingCoverBytes = bytes;
      _coverBytesLevel = 2;
    }
    if (palette != null && palette.isNotEmpty) {
      _dominantColor = palette.first;
      _preExtractedPalette = palette;
      _palettePath = path;
      _colorService.cachePaletteForPath(path, palette, modified: modified);
      ThemeProvider.instance.applySeedColorDirectly(
        palette.first,
        path,
        modified: modified,
      );
      return;
    }
    if (bytes == null) {
      _nowPlayingCoverBytes = null;
      _coverBytesLevel = 0;
      _dominantColor = null;
      _preExtractedPalette = null;
      _palettePath = null;
      _backgroundUsesCachedLargeCover = false;
    }
  }

  void updateCover() {
    final path = playbackService.nowPlaying?.path;
    if (path == null) {
      _clearCoverIfNeeded();
      return;
    }
    if (path == _nowPlayingCoverPath) return;
    _nowPlayingCoverPath = path;
    // Keep the previous frame visible until this track's artwork is ready.
    _backgroundUsesCachedLargeCover = false;
    // 旧字节只当占位，来源等级归零，等这首的封面按等级重新升。
    _coverBytesLevel = 0;
    _coverDebounceTimer?.cancel();
    _songChangeTrimTimer?.cancel();
    _coverRequestToken++;
    NowPlayingPerfProbe.instance.onSongChanged();
    final appliedCachedCover = _applyCachedCoverFrame(path);
    if (mounted) setState(() {});
    if (appliedCachedCover && _nowPlayingCoverBytes != null) {
      NowPlayingPerfProbe.instance.onCoverVisible(fromCache: true);
    }
    _songChangeTrimTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || playbackService.nowPlaying?.path != path) return;
      MemoryMonitorService.instance.trimAfterSongChange();
    });
    _scheduleCoverDetails();
  }

  void _clearCoverIfNeeded() {
    if (_nowPlayingCoverPath == null && _nowPlayingCoverBytes == null) return;
    _coverDebounceTimer?.cancel();
    _songChangeTrimTimer?.cancel();
    _coverRequestToken++;
    PaintingBinding.instance.imageCache.clear();
    setState(() {
      _nowPlayingCoverPath = null;
      _nowPlayingCoverBytes = null;
      _coverBytesLevel = 0;
      _dominantColor = null;
      _preExtractedPalette = null;
      _palettePath = null;
      _backgroundUsesCachedLargeCover = false;
    });
  }

  bool _applyCachedCoverFrame(String path) {
    // 首帧优先复用已解码的大封面，否则沿用小封面。
    final aud = playbackService.nowPlaying;
    if (aud == null) return false;
    final cachedPalette = _colorService.getCachedPaletteForPath(
      path,
      modified: aud.modified,
    );
    if (cachedPalette != null && cachedPalette.isNotEmpty) {
      _dominantColor = cachedPalette.first;
      _preExtractedPalette = cachedPalette;
      _palettePath = path;
    } else {
      final cached = _colorService.getCachedColorForPath(
        path,
        modified: aud.modified,
      );
      if (cached != null) {
        _dominantColor = cached;
      }
    }
    final cachedLargeCover = aud.cachedLargeCover;
    if (cachedLargeCover is MemoryImage) {
      _nowPlayingCoverBytes = cachedLargeCover.bytes;
      _coverBytesLevel = 3;
      _backgroundUsesCachedLargeCover = true;
      return true;
    }
    final smallBytes = aud.smallCoverBytes;
    // 切歌时保留上一首背景，等这首歌的 160px 封面就绪后一次替换；
    // 只有页面首次还没有任何背景时才用缩略图垫一帧。
    if (smallBytes != null && _nowPlayingCoverBytes == null) {
      _nowPlayingCoverBytes = smallBytes;
      _coverBytesLevel = 1;
      return true;
    }
    return false;
  }

  void _onViewModeChanged() {
    if (!mounted) return;
    if (nowPlayingViewMode.value == NowPlayingViewMode.withPlaylist) {
      // 进入播放列表：取消光标隐藏计时器，标题栏用ValueListenableBuilder 负责隐藏。
      _cursorHideTimer?.cancel();
    } else {
      // 退出播放列表：恢复标题栏和光标。
      _bumpCursor();
    }
  }

  /// 音量面板开合联动光标自动隐藏：展开时立即显示光标并暂停计时，收起后重新计时。
  void _onVolumePanelOpenChanged() {
    if (!mounted) return;
    if (nowPlayingVolumePanelOpen.value) {
      _cursorHideTimer?.cancel();
      _cursorHideTimer = null;
      _cursorHiddenNotifier.value = false;
      return;
    }
    _bumpCursor();
  }

  @override
  void initState() {
    super.initState();
    SleepBlocker.instance.setPageVisible(true);
    SleepBlocker.instance.reevaluate();
    _backgroundListenable = Listenable.merge([
      nowPlayingBackgroundModeNotifier,
      nowPlayingDynamicFlowingLightNotifier,
      nowPlayingAudioReactiveFlowNotifier,
      WindowRenderGate.instance.framesEnabled,
    ]);
    playbackService.nowPlayingNotifier.addListener(updateCover);
    nowPlayingViewMode.addListener(_onViewModeChanged);
    nowPlayingVolumePanelOpen.addListener(_onVolumePanelOpenChanged);
    updateCover();
    _bumpCursor();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shown = NowPlayingVisibility.shownOf(context);
    if (shown != _sessionShown) {
      _sessionShown = shown;
      SleepBlocker.instance.setPageVisible(shown);
      SleepBlocker.instance.reevaluate();
    }
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _routeAnimation)) {
      if (shown && _routeReady) _scheduleCoverDetails();
      return;
    }
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    _routeAnimation = animation;
    _routeAnimation?.addStatusListener(_onRouteAnimationStatus);
    _routeReady =
        animation == null || animation.status == AnimationStatus.completed;
    _routeReadyNotifier.value = _routeReady;
    if (_routeReady) {
      _scheduleCoverDetails();
    }
  }

  @override
  void dispose() {
    SleepBlocker.instance.setPageVisible(false);
    SleepBlocker.instance.reevaluate();
    playbackService.nowPlayingNotifier.removeListener(updateCover);
    nowPlayingViewMode.removeListener(_onViewModeChanged);
    nowPlayingVolumePanelOpen.removeListener(_onVolumePanelOpenChanged);
    // 页面销毁时复位面板状态，避免下一次进入播放页时光标一直可见。
    nowPlayingVolumePanelOpen.value = false;
    _coverDebounceTimer?.cancel();
    _songChangeTrimTimer?.cancel();
    _cursorHideTimer?.cancel();
    _cursorHiddenNotifier.dispose();
    _routeReadyNotifier.dispose();
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    CoverImageCache.instance.trimMemory(keepPath: _nowPlayingCoverPath);
    super.dispose();
  }

  Widget _buildBackground(Brightness brightness) {
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: _neutralBackgroundColor(brightness)),
          RepaintBoundary(
            child: ListenableBuilder(
              listenable: _backgroundListenable,
              builder: (context, _) => _flowBackground(brightness),
            ),
          ),
        ],
      ),
    );
  }

  Widget _flowBackground(Brightness brightness) {
    return NowPlayingBackground(
      mode: nowPlayingBackgroundModeNotifier.value,
      inputs: NowPlayingBackgroundInputs(
        albumCoverBytes: _nowPlayingCoverBytes,
        dominantColor: _dominantColor,
        spectrumStream: playbackService.spectrumStream,
        enableAnimation: nowPlayingDynamicFlowingLightNotifier.value,
        isVisible: _sessionShown,
        playerState: playbackService.playerStateNotifier.value,
        playerStateListenable: playbackService.playerStateNotifier,
        flowSpeed: 1.0,
        intensity: brightness == Brightness.dark ? 1.0 : 0.9,
        audioReactiveFlow: nowPlayingAudioReactiveFlowNotifier.value,
        preExtractedColors: _preExtractedPalette,
      ),
      fallbackColor: _neutralBackgroundColor(brightness),
    );
  }

  static Color _neutralBackgroundColor(Brightness brightness) {
    return brightness == Brightness.dark
        ? const Color(0xFF171717)
        : const Color(0xFFF0F0F0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final scheme = theme.colorScheme;

    final page = ListenableBuilder(
      listenable: ImmersiveModeController.instance,
      builder: (context, _) {
        final immersive = ImmersiveModeController.instance.enabled;
        if (immersive != _lastImmersive) {
          _lastImmersive = immersive;
        }
        return Scaffold(
          appBar: null,
          backgroundColor: Colors.transparent,
          drawer: const SizedBox(
            width: SideNav.expandedWidth,
            child: SideNav(),
          ),
          drawerEnableOpenDragGesture: !immersive,
          body: Listener(
            onPointerDown: (_) => _bumpCursor(),
            onPointerMove: (_) => _bumpCursor(),
            onPointerHover: (_) => _bumpCursor(),
            child: Stack(
              fit: StackFit.expand,
              alignment: AlignmentDirectional.center,
              children: [
                _buildBackground(brightness),
                _playbackLayer(scheme, immersive),
                const ConcertActCue(),
                if (immersive) const _ImmersiveHelpOverlay(),
                if (!immersive) _topChrome(),
                // Positioned 必须是 Stack 直接子节点，不能包在 Builder 里
                _hiddenCursorLayer(),
              ],
            ),
          ),
        );
      },
    );
    return FocusTraversalGroup(descendantsAreTraversable: false, child: page);
  }

  Widget _playbackLayer(ColorScheme scheme, bool immersive) {
    return ListenableBuilder(
      listenable: AppSettings.rebuildNotifier,
      builder: (context, _) {
        final useMonet = AppSettings.instance.useMaterialYouForControls;
        return IconButtonTheme(
          data: _playbackIconTheme(scheme, useMonet),
          child: ChangeNotifierProvider.value(
            value: PlayService.instance.playbackService,
            builder: (context, _) => _nowPlayingForeground(context, immersive),
          ),
        );
      },
    );
  }

  Widget _nowPlayingForeground(BuildContext context, bool immersive) {
    if (immersive) return const _NowPlayingImmersivePage();
    return ResponsiveBuilder2(
      largeMinWidth: _nowPlayingLargeLayoutMinWidth,
      builder: (context, screenType) {
        if (_usesCompactNowPlayingLayout(context, screenType)) {
          return _NowPlayingSmallPage(cursorHidden: _cursorHiddenNotifier);
        }
        return _NowPlayingLargePage(cursorHidden: _cursorHiddenNotifier);
      },
    );
  }

  IconButtonThemeData _playbackIconTheme(ColorScheme scheme, bool useMonet) {
    final foreground = playerThemeForeground(scheme, enabled: useMonet);
    final overlay = useMonet ? scheme.onSecondaryContainer : foreground;
    return IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(foreground),
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return overlay.withValues(alpha: 0.04);
          }
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return overlay.withValues(alpha: 0.02);
          }
          return Colors.transparent;
        }),
      ),
    );
  }

  Widget _topChrome() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: 56.0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: _topChromeVisibility(),
        ),
      ),
    );
  }

  Widget _topChromeVisibility() {
    return ValueListenableBuilder(
      valueListenable: _cursorHiddenNotifier,
      builder: (context, cursorHidden, _) {
        return ValueListenableBuilder(
          valueListenable: nowPlayingViewMode,
          builder: (context, viewMode, _) {
            final shouldHide =
                cursorHidden || viewMode == NowPlayingViewMode.withPlaylist;
            return AnimatedOpacity(
              duration: MotionDuration.xFast,
              curve: MotionCurve.standard,
              opacity: shouldHide ? 0.0 : 1.0,
              child: IgnorePointer(
                ignoring: shouldHide,
                child: _topChromeRow(),
              ),
            );
          },
        );
      },
    );
  }

  Widget _topChromeRow() {
    return Row(
      children: [
        ResponsiveBuilder2(
          largeMinWidth: _nowPlayingLargeLayoutMinWidth,
          builder: (context, screenType) {
            if (!_usesCompactNowPlayingLayout(context, screenType)) {
              return const SizedBox.shrink();
            }
            return Builder(
              builder: (context) => IconButton(
                tooltip: '侧边栏',
                onPressed: () => Scaffold.of(context).openDrawer(),
                icon: const Icon(Symbols.menu),
              ),
            );
          },
        ),
        const NavBackBtn(),
        const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
        const WindowControlls(),
      ],
    );
  }

  Widget _hiddenCursorLayer() {
    return Positioned.fill(
      child: ValueListenableBuilder<bool>(
        valueListenable: _cursorHiddenNotifier,
        builder: (context, cursorHidden, _) {
          if (!cursorHidden) return const SizedBox.shrink();
          return const MouseRegion(
            cursor: SystemMouseCursors.none,
            child: SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class _NowPlayingMoreAction extends StatefulWidget {
  const _NowPlayingMoreAction({this.showLyricSource = true});

  final bool showLyricSource;

  @override
  State<_NowPlayingMoreAction> createState() => _NowPlayingMoreActionState();
}

class _NowPlayingMoreActionState extends State<_NowPlayingMoreAction> {
  Audio? _addingAudioToPlaylist;
  Playlist? _addingTargetPlaylist;

  Future<void> _addNowPlayingToPlaylist(Audio audio, Playlist playlist) async {
    if (_addingAudioToPlaylist != null) {
      return;
    }

    if (playlist.containsPath(audio.path)) {
      showTextOnSnackBar('歌曲已在歌单中');
      return;
    }

    setState(() {
      _addingAudioToPlaylist = audio;
      _addingTargetPlaylist = playlist;
    });
    try {
      playlist.addPath(audio.path);
      final saved = await savePlaylists();
      if (!mounted) return;
      if (!saved) {
        playlist.removeByPath(audio.path);
        showTextOnSnackBar('保存歌单失败');
        return;
      }
      showTextOnSnackBar('已添加到歌单');
    } finally {
      _addingAudioToPlaylist = null;
      _addingTargetPlaylist = null;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final playbackService = context.watch<PlaybackService>();
    final nowPlaying = playbackService.nowPlaying;
    final menuStyle = appMenuStyle;
    final menuItemStyle = appMenuItemStyle;

    if (nowPlaying == null) {
      return IconButton(
        tooltip: '更多',
        onPressed: null,
        icon: const Icon(Symbols.more_vert),
        color: playerChromeForeground(context, enabled: useMonet),
      );
    }

    return MenuTheme(
      data: MenuThemeData(style: menuStyle),
      child: MenuAnchor(
        style: menuStyle,
        menuChildren: _menuChildren(context, nowPlaying, menuItemStyle),
        builder: (context, controller, _) => IconButton(
          tooltip: '更多',
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          icon: const Icon(Symbols.more_vert),
          color: playerChromeForeground(context, enabled: useMonet),
        ),
      ),
    );
  }

  List<Widget> _menuChildren(
    BuildContext context,
    Audio nowPlaying,
    ButtonStyle menuItemStyle,
  ) {
    return [
      ..._artistMenuItems(context, nowPlaying, menuItemStyle),
      _albumMenuItem(context, nowPlaying, menuItemStyle),
      _playlistMenuItem(nowPlaying, menuItemStyle),
      if (widget.showLyricSource)
        MenuItemButton(
          style: menuItemStyle,
          onPressed: () {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              showDialog<void>(
                context: context,
                builder: (context) => SetLyricSourceDialog(audio: nowPlaying),
              );
            });
          },
          leadingIcon: const Icon(Symbols.lyrics),
          child: const Text('歌词来源'),
        ),
      MenuItemButton(
        style: menuItemStyle,
        onPressed: () {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            showDialog<void>(
              context: context,
              builder: (context) => const SleepTimerDialog(),
            );
          });
        },
        leadingIcon: const Icon(Symbols.bedtime),
        child: const Text('睡眠定时'),
      ),
      MenuItemButton(
        style: menuItemStyle,
        onPressed: () {
          context.pushReplacement(
            app_paths.AUDIO_DETAIL_PAGE,
            extra: nowPlaying,
          );
        },
        leadingIcon: const Icon(Symbols.info),
        child: const Text('详细信息'),
      ),
    ];
  }

  VoidCallback? _openArtist(BuildContext context, String artistName) {
    final artist = AudioLibrary.instance.artistCollection[artistName];
    if (artist == null) return null;
    return () =>
        context.pushReplacement(app_paths.ARTIST_DETAIL_PAGE, extra: artist);
  }

  List<Widget> _artistMenuItems(
    BuildContext context,
    Audio nowPlaying,
    ButtonStyle menuItemStyle,
  ) {
    return [
      for (final artistName in nowPlaying.splitedArtists)
        MenuItemButton(
          style: menuItemStyle,
          onPressed: _openArtist(context, artistName),
          leadingIcon: const Icon(Symbols.people),
          child: Text(artistName),
        ),
    ];
  }

  Widget _albumMenuItem(
    BuildContext context,
    Audio nowPlaying,
    ButtonStyle menuItemStyle,
  ) {
    final album = AudioLibrary.instance.albumCollection[nowPlaying.album];
    return MenuItemButton(
      style: menuItemStyle,
      onPressed: album == null
          ? null
          : () {
              context.pushReplacement(
                app_paths.ALBUM_DETAIL_PAGE,
                extra: album,
              );
            },
      leadingIcon: const Icon(Symbols.album),
      child: Text(nowPlaying.album),
    );
  }

  Widget _playlistMenuItem(Audio nowPlaying, ButtonStyle menuItemStyle) {
    if (playlists.isEmpty) {
      return MenuItemButton(
        style: menuItemStyle,
        onPressed: null,
        leadingIcon: const Icon(Symbols.queue_music),
        child: const Text('添加到歌单'),
      );
    }
    return Builder(builder: (_) => _playlistSubmenu(nowPlaying, menuItemStyle));
  }

  Widget _playlistAddIcon(bool isAdding, List<bool> memberships) {
    if (isAdding) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Icon(
      memberships.every((alreadyIn) => alreadyIn)
          ? Symbols.check
          : Symbols.queue_music,
    );
  }

  Widget _playlistSubmenu(Audio nowPlaying, ButtonStyle menuItemStyle) {
    final playlistMemberships = playlists
        .map((playlist) => playlist.containsPath(nowPlaying.path))
        .toList(growable: false);
    final isAddingNowPlaying = identical(_addingAudioToPlaylist, nowPlaying);
    final canOpenAddMenu = canOpenSingleAudioAddToPlaylistMenu(
      hasAudio: true,
      isBusy: _addingAudioToPlaylist != null,
      alreadyInPlaylists: playlistMemberships,
    );
    if (!canOpenAddMenu) {
      return MenuItemButton(
        style: menuItemStyle,
        onPressed: null,
        leadingIcon: _playlistAddIcon(isAddingNowPlaying, playlistMemberships),
        child: Text(isAddingNowPlaying ? '添加中' : '添加到歌单'),
      );
    }
    return SubmenuButton(
      style: menuItemStyle,
      menuChildren: [
        for (var i = 0; i < playlists.length; i++)
          _playlistEntry(
            nowPlaying,
            playlists[i],
            playlistMemberships[i],
            menuItemStyle,
          ),
      ],
      child: Text(isAddingNowPlaying ? '添加中' : '添加到歌单'),
    );
  }

  Widget _playlistEntry(
    Audio nowPlaying,
    Playlist playlist,
    bool alreadyInPlaylist,
    ButtonStyle menuItemStyle,
  ) {
    final isAddingTarget =
        identical(_addingAudioToPlaylist, nowPlaying) &&
        identical(_addingTargetPlaylist, playlist);
    return MenuItemButton(
      style: menuItemStyle,
      onPressed: _addingAudioToPlaylist == null && !alreadyInPlaylist
          ? () => _addNowPlayingToPlaylist(nowPlaying, playlist)
          : null,
      leadingIcon: isAddingTarget
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(alreadyInPlaylist ? Symbols.check : Symbols.queue_music),
      child: Text(playlist.name),
    );
  }
}

class _NowPlayingPlaybackModeSwitch extends StatefulWidget {
  const _NowPlayingPlaybackModeSwitch();

  @override
  State<_NowPlayingPlaybackModeSwitch> createState() =>
      _NowPlayingPlaybackModeSwitchState();
}

class _NowPlayingPlaybackModeSwitchState
    extends State<_NowPlayingPlaybackModeSwitch> {
  bool _isSaving = false;

  Future<void> _changeMode({
    required bool shuffle,
    required PlayMode playMode,
  }) async {
    if (_isSaving) return;

    setState(() => _isSaving = true);
    try {
      final playbackService = PlayService.instance.playbackService;
      if (shuffle) {
        playbackService.useShuffle(false);
        playbackService.setPlayMode(PlayMode.forward);
      } else {
        switch (playMode) {
          case PlayMode.forward:
          case PlayMode.loop:
            playbackService.setPlayMode(PlayMode.listOnce);
            break;
          case PlayMode.listOnce:
            playbackService.setPlayMode(PlayMode.singleLoop);
            break;
          case PlayMode.singleLoop:
            playbackService.useShuffle(true);
            break;
        }
      }
      await AppPreference.instance.savePlaybackOnly();
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final color = playerChromeForeground(context, enabled: useMonet);
    final disabledColor = color.withValues(alpha: 0.38);
    final playbackService = PlayService.instance.playbackService;

    return ListenableBuilder(
      listenable: Listenable.merge([
        playbackService.shuffle,
        playbackService.playMode,
        ConcertSession.instance,
      ]),
      builder: (context, _) {
        final shuffle = playbackService.shuffle.value;
        final playMode = playbackService.playMode.value;
        final visuals = _modeVisuals(shuffle, playMode);
        // 演出模式靠固定队列推进，期间不接受切换播放顺序
        final concertLocked = ConcertSession.instance.isActive;
        return IconButton(
          tooltip: concertLocked
              ? '有处于演出模式，不要切换啦'
              : _isSaving
              ? '保存中'
              : visuals.text,
          onPressed: concertLocked || _isSaving
              ? null
              : () => _changeMode(shuffle: shuffle, playMode: playMode),
          icon: _modeIcon(visuals.icon, color),
          color: color,
          disabledColor: disabledColor,
        );
      },
    );
  }

  Widget _modeIcon(IconData icon, Color color) {
    if (!_isSaving) return Icon(icon, fill: 0.0, weight: 400.0);
    return SizedBox(
      width: 22,
      height: 22,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    );
  }

  ({String text, IconData icon}) _modeVisuals(bool shuffle, PlayMode playMode) {
    if (shuffle) {
      return (text: '随机播放', icon: Symbols.shuffle);
    }
    if (playMode == PlayMode.singleLoop) {
      return (text: '单曲循环', icon: Symbols.repeat_one);
    }
    if (playMode == PlayMode.listOnce) {
      return (text: '顺序播放', icon: Symbols.playlist_play);
    }
    return (text: '列表循环', icon: Symbols.repeat);
  }
}

class _ExclusiveModeSwitch extends StatelessWidget {
  const _ExclusiveModeSwitch();

  @override
  Widget build(BuildContext context) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    //
    return ValueListenableBuilder(
      valueListenable: PlayService.instance.playbackService.wasapiExclusive,
      builder: (context, exclusive, _) {
        // 激活态也只跟「主题色控件」：关=浅黑/深白，开才用主题色
        final foregroundColor = playerChromeForeground(
          context,
          enabled: useMonet,
        );

        return IconButton(
          tooltip: exclusive ? '关闭独占' : '打开独占',
          onPressed: () {
            PlayService.instance.playbackService.useExclusiveMode(!exclusive);
          },
          icon: Center(
            child: Text(
              exclusive ? 'Excl' : 'Shrd',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: foregroundColor,
              ),
            ),
          ),
          color: foregroundColor,
        );
      },
    );
  }
}

class _DesktopLyricSwitch extends StatefulWidget {
  const _DesktopLyricSwitch();

  @override
  State<_DesktopLyricSwitch> createState() => _DesktopLyricSwitchState();
}

class _DesktopLyricSwitchState extends State<_DesktopLyricSwitch> {
  bool _isStarting = false;

  Future<void> _startDesktopLyric() async {
    if (_isStarting) return;

    setState(() => _isStarting = true);
    try {
      await PlayService.instance.desktopLyricService.startDesktopLyric();
    } finally {
      if (mounted) {
        setState(() => _isStarting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    //
    return ListenableBuilder(
      listenable: PlayService.instance.desktopLyricService,
      builder: (context, _) {
        final desktopLyricService = PlayService.instance.desktopLyricService;
        final isRunning = desktopLyricService.isRunning;
        final isKilling = desktopLyricService.isKilling;

        if (_isStarting && !isRunning) {
          return _busyDesktopLyricButton(useMonet, '正在打开桌面歌词...');
        }
        if (isKilling) {
          return _busyDesktopLyricButton(useMonet, '正在关闭桌面歌词...');
        }
        return _desktopLyricButton(useMonet);
      },
    );
  }

  Widget _busyDesktopLyricButton(bool useMonet, String tooltip) {
    return IconButton(
      tooltip: tooltip,
      onPressed: null,
      icon: const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      color: playerChromeForeground(context, enabled: useMonet),
    );
  }

  Widget _desktopLyricButton(bool useMonet) {
    final desktopLyricService = PlayService.instance.desktopLyricService;
    final isRunning = desktopLyricService.isRunning;
    return IconButton(
      tooltip: !isRunning
          ? '打开桌面歌词'
          : desktopLyricService.isLocked
          ? '解锁桌面歌词'
          : '关闭桌面歌词',
      onPressed: !isRunning
          ? _startDesktopLyric
          : desktopLyricService.isLocked
          ? desktopLyricService.sendUnlockMessage
          : desktopLyricService.killDesktopLyric,
      icon: Icon(
        desktopLyricService.isLocked ? Symbols.lock : Symbols.toast,
        fill: isRunning ? 1 : 0,
      ),
      color: playerChromeForeground(context, enabled: useMonet),
    );
  }
}

class _NowPlayingVolDspSlider extends StatefulWidget {
  const _NowPlayingVolDspSlider();

  @override
  State<_NowPlayingVolDspSlider> createState() =>
      _NowPlayingVolDspSliderState();
}

class _NowPlayingVolDspSliderState extends State<_NowPlayingVolDspSlider> {
  /// 单格滚轮调节的步进比例。
  static const double _scrollStep = 0.01;

  final playbackService = PlayService.instance.playbackService;
  final systemVolumeService = SystemVolumeService.instance;
  final dragVolDsp = ValueNotifier(
    AppPreference.instance.playbackPref.volumeDsp,
  );
  final dragSystemVol = ValueNotifier(0.0);

  final MenuController _menuController = MenuController();

  bool isDragging = false;
  bool isSystemDragging = false;
  bool _isMenuOpen = false;
  bool _disposed = false;

  /// 面板展开是否由本控件触发；销毁时只复位本控件打开的全局状态。
  bool _panelOpenedByThisControl = false;
  double _lastVolumeDsp = -1;
  Timer? _systemVolBoostTimer;
  late final VoidCallback _systemVolValueListener;
  Timer? _indicatorTimer;
  Timer? _systemIndicatorTimer;
  bool _showCustomIndicator = false;
  bool _showSystemCustomIndicator = false;
  bool _isHovering = false;
  bool _isSystemHovering = false;

  /// 面板当前显示的行：false 为应用音量，true 为系统音量。
  bool _showSystemRow = false;

  /// 点击按钮后钉住面板，鼠标移开也不收起；再次点击取消。
  bool _pinned = false;
  Timer? _hoverOpenTimer;
  Timer? _hoverCloseTimer;

  /// 滚轮调节应用音量后的落盘防抖，连续滚动只在停止后写一次。
  Timer? _volumePersistTimer;

  /// 滚轮调节系统音量后的写入防抖，连续滚动只写最后一次目标值。
  Timer? _systemVolumePersistTimer;
  double? _pendingSystemVolumePersist;
  int _systemVolumePersistRevision = 0;

  /// 应用音量行同时响应本地拖动值与外部音量变化。
  late final Listenable _appVolumeListenable = Listenable.merge([
    dragVolDsp,
    playbackService,
  ]);
  late final VoidCallback _nowPlayingListener;

  /// 读取系统音量；失败返回 null 并记录日志，轮询按无数据降级。
  Future<double?> _readSystemVol({required Duration timeout}) async {
    try {
      return await systemVolumeService.read(timeout: timeout);
    } catch (error, stackTrace) {
      log.app.debug(
        'now_playing_system_volume_read_failed',
        '读取系统音量失败',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _lastVolumeDsp = playbackService.volumeDsp;
    _nowPlayingListener = () {
      if (_disposed || !mounted) return;
      final v = playbackService.volumeDsp;
      if ((v - _lastVolumeDsp).abs() <= 0.0001) return;
      _lastVolumeDsp = v;
      if (!isDragging && (v - dragVolDsp.value).abs() > 0.0001) {
        dragVolDsp.value = v;
      }
      if (_isMenuOpen && !isDragging) {
        _triggerIndicator();
      }
    };
    playbackService.nowPlayingNotifier.addListener(_nowPlayingListener);
    systemVolumeService.ensureBound();
    dragSystemVol.value = systemVolumeService.volume.value;
    _systemVolValueListener = () {
      if (!mounted || isSystemDragging) return;
      // 滚轮防抖写入期间系统音量仍是旧值，跳过轮询同步避免滑块被拉回。
      if (_pendingSystemVolumePersist != null) return;
      dragSystemVol.value = systemVolumeService.volume.value;
    };
    systemVolumeService.volume.addListener(_systemVolValueListener);
  }

  void _triggerIndicator() {
    // 气泡已显示时跳过 setState，避免拖动期间逐帧重建；每次调节都重置隐藏计时器。
    if (!_showCustomIndicator) {
      setState(() => _showCustomIndicator = true);
    }
    _indicatorTimer?.cancel();
    _indicatorTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) {
        setState(() => _showCustomIndicator = false);
      }
    });
  }

  void _triggerSystemIndicator() {
    // 气泡已显示时跳过 setState，避免滚轮与拖动期间逐帧重建；每次调节都重置隐藏计时器。
    if (!_showSystemCustomIndicator) {
      setState(() => _showSystemCustomIndicator = true);
    }
    _systemIndicatorTimer?.cancel();
    _systemIndicatorTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) {
        setState(() => _showSystemCustomIndicator = false);
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    // 只复位本控件打开的面板状态，避免路由切换期间旧控件销毁误关新页面的面板。
    if (_panelOpenedByThisControl) {
      _panelOpenedByThisControl = false;
      nowPlayingVolumePanelOpen.value = false;
    }
    final hasPendingVolumePersist = _volumePersistTimer?.isActive ?? false;
    final pendingSystemVolume = _pendingSystemVolumePersist;
    _systemVolBoostTimer?.cancel();
    _indicatorTimer?.cancel();
    _systemIndicatorTimer?.cancel();
    _hoverOpenTimer?.cancel();
    _hoverCloseTimer?.cancel();
    _volumePersistTimer?.cancel();
    _systemVolumePersistTimer?.cancel();
    playbackService.nowPlayingNotifier.removeListener(_nowPlayingListener);
    systemVolumeService.volume.removeListener(_systemVolValueListener);
    if (hasPendingVolumePersist) {
      // 离开页面时把滚轮调节但尚未落盘的应用音量补写一次；此处已无法 setState。
      _savePlaybackPreference();
    }
    if (pendingSystemVolume != null) {
      // 离开页面时把滚轮调节但尚未写入的系统音量补写一次。
      _writeSystemVolume(pendingSystemVolume);
    }
    dragSystemVol.dispose();
    dragVolDsp.dispose();
    super.dispose();
  }

  /// 只写播放偏好文件，不触发播放服务通知。
  void _savePlaybackPreference() {
    unawaited(
      AppPreference.instance.savePlaybackOnly().catchError((Object error) {
        log.app.debug(
          'now_playing_volume_persist_failed',
          '写入应用音量偏好失败',
          fields: {'error': error.runtimeType.toString()},
        );
        return false;
      }),
    );
  }

  /// 写入系统音量；失败只记录日志。
  void _writeSystemVolume(double value) {
    unawaited(
      systemVolumeService.set(value).catchError((Object error) {
        log.app.debug(
          'now_playing_system_volume_set_failed',
          '写入系统音量失败',
          fields: {'error': error.runtimeType.toString()},
        );
      }),
    );
  }

  /// 系统音量写入防抖：连续滚动只在停止后写入最后一次目标值；
  /// 拖动结束时传 `Duration.zero` 立即提交。
  void _scheduleSystemVolumePersist(
    double value, {
    Duration delay = const Duration(milliseconds: 150),
  }) {
    _pendingSystemVolumePersist = value;
    final revision = ++_systemVolumePersistRevision;
    _systemVolumePersistTimer?.cancel();
    _systemVolumePersistTimer = Timer(delay, () {
      _systemVolumePersistTimer = null;
      final target = _pendingSystemVolumePersist;
      if (target == null) return;
      unawaited(_commitSystemVolume(target, revision));
    });
  }

  /// 写入系统音量；完成前保持防抖标记，避免轮询用旧值覆盖滑块。
  Future<void> _commitSystemVolume(double target, int revision) async {
    try {
      await systemVolumeService.set(target);
    } catch (error) {
      log.app.debug(
        'now_playing_system_volume_set_failed',
        '写入系统音量失败',
        fields: {'error': error.runtimeType.toString()},
      );
    }
    if (revision != _systemVolumePersistRevision) return;
    _pendingSystemVolumePersist = null;
    if (!mounted || _disposed || !_isMenuOpen || !_showSystemRow) return;
    _startSystemVolumePolling();
  }

  @override
  Widget build(BuildContext context) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final scheme = Theme.of(context).colorScheme;
    // 可用宽度先扣掉菜单两侧留白，再限制上限；窄窗口下随窗口收窄。
    final availableWidth = max(
      0.0,
      MediaQuery.sizeOf(context).width - 48.0,
    );
    final menuWidth = min(availableWidth, 260.0);
    //

    return MenuAnchor(
      controller: _menuController,
      style: appMenuStyle,
      onOpen: _onVolumeMenuOpen,
      onClose: _onVolumeMenuClose,
      menuChildren: [_volumeMenuBody(scheme, menuWidth)],
      builder: (context, controller, _) {
        return _buildVolumeButton(context, controller, useMonet: useMonet);
      },
    );
  }

  /// 音量按钮：悬停打开面板、滚轮直接调节、点击钉住或关闭。
  Widget _buildVolumeButton(
    BuildContext context,
    MenuController controller, {
    required bool useMonet,
  }) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: (event) => _handleVolumeScroll(event, controller),
      child: MouseRegion(
        onEnter: (_) => _onVolumeButtonHoverEnter(controller),
        onExit: (_) => _onVolumeButtonHoverExit(controller),
        child: IconButton(
          tooltip: controller.isOpen ? null : '音量',
          onPressed: () => _toggleVolumePanel(controller),
          icon: const Icon(Symbols.volume_up),
          color: playerChromeForeground(context, enabled: useMonet),
        ),
      ),
    );
  }

  void _onVolumeButtonHoverEnter(MenuController controller) {
    _hoverCloseTimer?.cancel();
    _hoverOpenTimer?.cancel();
    if (controller.isOpen) return;
    _hoverOpenTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted || _disposed || controller.isOpen) return;
      controller.open();
    });
  }

  void _onVolumeButtonHoverExit(MenuController controller) {
    _hoverOpenTimer?.cancel();
    _scheduleHoverClose(controller);
  }

  void _scheduleHoverClose(MenuController controller) {
    _hoverCloseTimer?.cancel();
    _hoverCloseTimer = Timer(const Duration(milliseconds: 220), () {
      if (!mounted || _disposed || _pinned) return;
      if (controller.isOpen) {
        controller.close();
      }
    });
  }

  void _toggleVolumePanel(MenuController controller) {
    if (_pinned) {
      _pinned = false;
      controller.close();
      return;
    }
    _pinned = true;
    _hoverOpenTimer?.cancel();
    _hoverCloseTimer?.cancel();
    if (!controller.isOpen) {
      controller.open();
    }
  }

  void _handleVolumeScroll(
    PointerSignalEvent event,
    MenuController controller,
  ) {
    if (event is! PointerScrollEvent) return;
    if (event.scrollDelta.dy == 0) return;
    _hoverOpenTimer?.cancel();
    _hoverCloseTimer?.cancel();
    if (!controller.isOpen) {
      controller.open();
    }
    final step = -event.scrollDelta.dy.sign * _scrollStep;
    if (_showSystemRow) {
      final next = (dragSystemVol.value + step).clamp(0.0, 1.0).toDouble();
      // 防抖期间系统音量尚未改变，先停掉轮询，避免读回旧值覆盖滑块。
      _stopSystemVolumePolling();
      dragSystemVol.value = next;
      _scheduleSystemVolumePersist(next);
      _triggerSystemIndicator();
      return;
    }
    final next = (playbackService.volumeDsp + step)
        .clamp(0.0, 1.0)
        .toDouble();
    dragVolDsp.value = next;
    _lastVolumeDsp = next;
    playbackService.setVolumeDsp(next, persist: false);
    _triggerIndicator();
    _volumePersistTimer?.cancel();
    _volumePersistTimer = Timer(const Duration(milliseconds: 300), () {
      if (_disposed) return;
      try {
        playbackService.setVolumeDsp(playbackService.volumeDsp);
      } catch (error) {
        log.app.debug(
          'now_playing_volume_persist_failed',
          '滚轮调节后写入应用音量失败',
          fields: {'error': error.runtimeType.toString()},
        );
      }
    });
  }

  void _onVolumeMenuOpen() {
    _panelOpenedByThisControl = true;
    nowPlayingVolumePanelOpen.value = true;
    _isMenuOpen = true;
    _hoverOpenTimer?.cancel();
    _hoverCloseTimer?.cancel();
    if (!isDragging) {
      dragVolDsp.value = playbackService.volumeDsp;
    }
    if (_showSystemRow) {
      // 滚轮防抖写入中的目标值优先，避免被系统旧音量覆盖。
      dragSystemVol.value =
          _pendingSystemVolumePersist ?? systemVolumeService.volume.value;
      _startSystemVolumePolling();
    } else {
      _stopSystemVolumePolling();
    }
  }

  void _onVolumeMenuClose() {
    _panelOpenedByThisControl = false;
    nowPlayingVolumePanelOpen.value = false;
    _isMenuOpen = false;
    _pinned = false;
    _hoverOpenTimer?.cancel();
    _hoverCloseTimer?.cancel();
    _stopSystemVolumePolling();
    // 菜单子树移除时滑块的 onExit 不会触发，直接复位悬停状态。
    _isHovering = false;
    _isSystemHovering = false;
  }

  void _startSystemVolumePolling() {
    if (_systemVolBoostTimer?.isActive ?? false) return;
    // 滚轮防抖写入期间系统音量仍是旧值，等提交完成后再启动轮询。
    if (_pendingSystemVolumePersist != null) return;
    int ticks = 0;
    _systemVolBoostTimer = Timer.periodic(const Duration(milliseconds: 120), (
      _,
    ) async {
      // 页面销毁后定时器无法继续持有 notifier，直接停止轮询。
      if (!mounted || _disposed) {
        _stopSystemVolumePolling();
        return;
      }
      if (isSystemDragging) return;
      if (ticks++ > 25) {
        _stopSystemVolumePolling();
        return;
      }
      final v = await _readSystemVol(
        timeout: const Duration(milliseconds: 500),
      );
      // 读取期间可能已销毁、进入拖动或滚轮防抖写入，读回值不可信。
      if (!mounted ||
          _disposed ||
          isSystemDragging ||
          _pendingSystemVolumePersist != null) {
        return;
      }
      if (v != null && (v - dragSystemVol.value).abs() > 0.003) {
        dragSystemVol.value = v;
      }
    });
  }

  void _stopSystemVolumePolling() {
    _systemVolBoostTimer?.cancel();
    _systemVolBoostTimer = null;
  }

  void _toggleVolumeRow() {
    final showSystemRow = !_showSystemRow;
    setState(() {
      _showSystemRow = showSystemRow;
      _isHovering = false;
      _isSystemHovering = false;
    });
    if (showSystemRow) {
      // 滚轮防抖写入中的目标值优先，避免被系统旧音量覆盖。
      dragSystemVol.value =
          _pendingSystemVolumePersist ?? systemVolumeService.volume.value;
      _startSystemVolumePolling();
    } else {
      _stopSystemVolumePolling();
      dragVolDsp.value = playbackService.volumeDsp;
    }
  }

  Widget _volumeMenuBody(ColorScheme scheme, double menuWidth) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    // 窄菜单下压缩百分比文本宽度，把水平空间让给滑块。
    final percentWidth = menuWidth < 160.0 ? 36.0 : 44.0;
    return MouseRegion(
      onEnter: (_) {
        _hoverOpenTimer?.cancel();
        _hoverCloseTimer?.cancel();
      },
      onExit: (_) => _scheduleHoverClose(_menuController),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
        child: SizedBox(
          width: menuWidth,
          child: Row(
            children: [
              IconButton(
                tooltip: _showSystemRow ? '切换到应用音量' : '切换到系统音量',
                visualDensity: VisualDensity.compact,
                onPressed: _toggleVolumeRow,
                icon: Icon(
                  _showSystemRow ? Symbols.volume_mute : Symbols.volume_up,
                ),
                color: playerChromeForeground(context, enabled: useMonet),
              ),
              Expanded(
                child: SliderTheme(
                  data: const SliderThemeData(
                    showValueIndicator: ShowValueIndicator.never,
                  ),
                  child: _showSystemRow
                      ? _systemVolumeSlider(scheme)
                      : _appVolumeSlider(scheme),
                ),
              ),
              if (_showSystemRow)
                ValueListenableBuilder<double>(
                  valueListenable: dragSystemVol,
                  builder: (context, value, _) =>
                      _volumePercentLabel(value, scheme, percentWidth),
                )
              else
                ListenableBuilder(
                  listenable: _appVolumeListenable,
                  builder: (context, _) => _volumePercentLabel(
                    playbackService.volumeDsp,
                    scheme,
                    percentWidth,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _volumePercentLabel(
    double value,
    ColorScheme scheme,
    double width,
  ) {
    // 外部音量值可能越界，显示值与滑块位置保持一致。
    final safeValue = value.clamp(0.0, 1.0).toDouble();
    return SizedBox(
      width: width,
      child: Text(
        '${(safeValue * 100).round()}%',
        textAlign: TextAlign.end,
        style: TextStyle(color: scheme.onSurface, fontSize: 12),
      ),
    );
  }

  Widget _systemVolumeSlider(ColorScheme scheme) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    return ValueListenableBuilder(
      valueListenable: dragSystemVol,
      builder: (context, systemVolValue, _) {
        return _volumeSliderStack(
          scheme: scheme,
          value: systemVolValue.clamp(0.0, 1.0).toDouble(),
          color: useMonet
              ? scheme.secondary
              : playerThemeForeground(scheme, enabled: false),
          textColor: useMonet
              ? scheme.onSecondary
              : playerThemeOnForeground(scheme, enabled: false),
          showBubble: _showSystemCustomIndicator || _isSystemHovering,
          onHover: (hovering) => setState(() => _isSystemHovering = hovering),
          onChangeStart: (value) {
            // 拖动接管系统音量后，滚轮防抖的待写入值由拖动结束统一写入。
            _systemVolumePersistTimer?.cancel();
            _pendingSystemVolumePersist = null;
            _systemVolumePersistRevision += 1;
            isSystemDragging = true;
            dragSystemVol.value = value;
            _writeSystemVolume(value);
            _triggerSystemIndicator();
          },
          onChanged: (value) {
            dragSystemVol.value = value;
            _writeSystemVolume(value);
            if (isSystemDragging) _triggerSystemIndicator();
          },
          onChangeEnd: (value) {
            isSystemDragging = false;
            dragSystemVol.value = value;
            // 拖动结束后经提交队列写入，pending 标记在写入完成前阻止轮询读回旧值；
            // 提交完成后由 _commitSystemVolume 重启轮询。
            _stopSystemVolumePolling();
            _scheduleSystemVolumePersist(value, delay: Duration.zero);
          },
        );
      },
    );
  }

  Widget _appVolumeSlider(ColorScheme scheme) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    return ListenableBuilder(
      listenable: _appVolumeListenable,
      builder: (context, _) {
        return _volumeSliderStack(
          scheme: scheme,
          // 音量服务不保证入参在 0..1，先收敛再交给 Slider，避免断言。
          value: playbackService.volumeDsp.clamp(0.0, 1.0).toDouble(),
          color: playerThemeForeground(scheme, enabled: useMonet),
          textColor: playerThemeOnForeground(scheme, enabled: useMonet),
          showBubble: _showCustomIndicator || _isHovering,
          onHover: (hovering) => setState(() => _isHovering = hovering),
          onChangeStart: (value) {
            // 拖动接管音量后，滚轮防抖的待落盘值由拖动结束统一写入。
            _volumePersistTimer?.cancel();
            isDragging = true;
            dragVolDsp.value = value;
            playbackService.setVolumeDsp(value, persist: false);
            _triggerIndicator();
          },
          onChanged: (value) {
            dragVolDsp.value = value;
            playbackService.setVolumeDsp(value, persist: false);
            if (isDragging) _triggerIndicator();
          },
          onChangeEnd: (value) {
            _volumePersistTimer?.cancel();
            isDragging = false;
            dragVolDsp.value = value;
            _lastVolumeDsp = value;
            playbackService.setVolumeDsp(value);
            _triggerIndicator();
          },
        );
      },
    );
  }

  Widget _volumeSliderStack({
    required ColorScheme scheme,
    required double value,
    required Color color,
    required Color textColor,
    required bool showBubble,
    required ValueChanged<bool> onHover,
    required ValueChanged<double> onChangeStart,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const padding = 24.0;
        final trackWidth = max(0.0, constraints.maxWidth - (padding * 2));
        final leftOffset = padding + trackWidth * value;
        return MouseRegion(
          onEnter: (_) => onHover(true),
          onExit: (_) => onHover(false),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.centerLeft,
            children: [
              Slider(
                thumbColor: color,
                activeColor: color,
                inactiveColor: scheme.outline,
                min: 0,
                max: 1,
                value: value,
                onChangeStart: onChangeStart,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
              if (showBubble)
                _volumeBubble(leftOffset, value, color, textColor),
            ],
          ),
        );
      },
    );
  }

  Widget _volumeBubble(
    double leftOffset,
    double value,
    Color color,
    Color textColor,
  ) {
    return Positioned(
      left: leftOffset - 24.0,
      top: -40,
      child: IgnorePointer(
        child: _CustomValueIndicator(
          value: value * 100,
          suffix: '%',
          color: color,
          textColor: textColor,
        ),
      ),
    );
  }
}

class _CustomValueIndicator extends StatelessWidget {
  final double value;
  final String suffix;
  final Color color;
  final Color textColor;

  const _CustomValueIndicator({
    required this.value,
    this.suffix = '',
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 48,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '${value.toInt()}$suffix',
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ),
        CustomPaint(size: const Size(12, 6), painter: _TrianglePainter(color)),
      ],
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color color;

  _TrianglePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(0, 0);
    path.lineTo(size.width / 2, size.height);
    path.lineTo(size.width, 0);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _GlowingIconButton extends StatefulWidget {
  static final _glowBlurFilter = ImageFilter.blur(sigmaX: 10, sigmaY: 10);

  final String tooltip;
  final VoidCallback onPressed;
  final IconData iconData;
  final double size;
  final Color glowColor;
  final Color iconColor;

  const _GlowingIconButton({
    required this.tooltip,
    required this.onPressed,
    required this.iconData,
    required this.size,
    required this.glowColor,
    required this.iconColor,
  });

  @override
  State<_GlowingIconButton> createState() => _GlowingIconButtonState();
}

class _GlowingIconButtonState extends State<_GlowingIconButton> {
  bool _isHovering = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovering = true),
        onExit: (_) => setState(() => _isHovering = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _isPressed = true),
          onTapUp: (_) => setState(() => _isPressed = false),
          onTapCancel: () => setState(() => _isPressed = false),
          onTap: widget.onPressed,
          child: _glowStack(scheme),
        ),
      ),
    );
  }

  Widget _glowStack(ColorScheme scheme) {
    return SizedBox(
      width: widget.size + 16,
      height: widget.size + 16,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _hoverBackdrop(scheme, BorderRadius.circular(8)),
          if (_isHovering) _glowIconLayer(),
          AnimatedScale(
            duration: const Duration(milliseconds: 120),
            curve: const Cubic(0.4, 0, 0.2, 1),
            scale: _isPressed ? 0.97 : 1.0,
            child: Icon(
              widget.iconData,
              size: widget.size,
              color: widget.iconColor,
              fill: 0.0,
              weight: 400.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _hoverBackdrop(ColorScheme scheme, BorderRadius borderRadius) {
    final hoverBgAlpha = _isPressed ? 0.04 : 0.02;
    return AnimatedOpacity(
      duration: MotionDuration.fast,
      curve: MotionCurve.standard,
      opacity: (_isHovering || _isPressed) ? 1.0 : 0.0,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.onSecondaryContainer.withValues(alpha: hoverBgAlpha),
          borderRadius: borderRadius,
        ),
      ),
    );
  }

  Widget _glowIconLayer() {
    return Positioned.fill(
      child: ImageFiltered(
        imageFilter: _GlowingIconButton._glowBlurFilter,
        child: Center(
          child: Icon(
            widget.iconData,
            size: widget.size,
            color: widget.glowColor,
            fill: 0.0,
            weight: 400.0,
          ),
        ),
      ),
    );
  }
}

class _MorphPlayPauseButton extends StatefulWidget {
  static final _glowBlurFilter = ImageFilter.blur(sigmaX: 10, sigmaY: 10);

  const _MorphPlayPauseButton({
    required this.playerState,
    required this.onPlay,
    required this.onPause,
    required this.onReplay,
    required this.size,
    required this.glowColor,
    required this.color,
    required this.playerStateStream,
  });
  final PlayerState playerState;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onReplay;
  final double size;
  final Color glowColor;
  final Color color;
  final Stream<PlayerState> playerStateStream;

  @override
  State<_MorphPlayPauseButton> createState() => _MorphPlayPauseButtonState();
}

class _MorphPlayPauseButtonState extends State<_MorphPlayPauseButton>
    with SingleTickerProviderStateMixin {
  bool _isHovering = false;
  bool _isPressed = false;
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late PlayerState _state = widget.playerState;
  StreamSubscription<PlayerState>? _playerStateSubscription;

  @override
  void initState() {
    super.initState();
    _controller.value = _state == PlayerState.playing ? 1.0 : 0.0;
    _bindPlayerStateStream();
  }

  void _bindPlayerStateStream() {
    _playerStateSubscription?.cancel();
    _playerStateSubscription = widget.playerStateStream.listen((newState) {
      if (!mounted) return;
      _syncPlayerState(newState);
    });
  }

  void _syncPlayerState(PlayerState state) {
    if (!mounted || state == _state) return;
    setState(() {
      _state = state;
    });
    _controller.animateTo(
      state == PlayerState.playing ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 240),
      curve: const Cubic(0.2, 0.0, 0.0, 1.0),
    );
  }

  @override
  void didUpdateWidget(covariant _MorphPlayPauseButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playerStateStream != widget.playerStateStream) {
      _bindPlayerStateStream();
    }
    if (oldWidget.playerState != widget.playerState &&
        widget.playerState != _state) {
      _syncPlayerState(widget.playerState);
    }
  }

  @override
  void dispose() {
    _playerStateSubscription?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        child: _morphButton(scheme),
      ),
    );
  }

  VoidCallback get _morphAction {
    if (_state == PlayerState.playing) return widget.onPause;
    if (_state == PlayerState.completed) return widget.onReplay;
    return widget.onPlay;
  }

  Widget _morphButton(ColorScheme scheme) {
    final isPlaying = _state == PlayerState.playing;
    return SizedBox(
      width: widget.size + 16,
      height: widget.size + 16,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _hoverCircle(scheme),
          if (_isHovering) _morphGlow(),
          AnimatedScale(
            duration: const Duration(milliseconds: 120),
            curve: const Cubic(0.4, 0, 0.2, 1),
            scale: _isPressed ? 0.97 : 1.0,
            child: IconButton(
              tooltip: isPlaying ? '暂停' : '播放',
              onPressed: _morphAction,
              icon: AnimatedIcon(
                icon: AnimatedIcons.play_pause,
                progress: _controller,
                color: widget.color,
                size: widget.size,
              ),
              style: const ButtonStyle(
                backgroundColor: WidgetStatePropertyAll(Colors.transparent),
                overlayColor: WidgetStatePropertyAll(Colors.transparent),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hoverCircle(ColorScheme scheme) {
    final hoverBgAlpha = _isPressed ? 0.04 : 0.02;
    return AnimatedOpacity(
      duration: MotionDuration.fast,
      curve: MotionCurve.standard,
      opacity: (_isHovering || _isPressed) ? 1.0 : 0.0,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.onSecondaryContainer.withValues(alpha: hoverBgAlpha),
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  Widget _morphGlow() {
    return Positioned.fill(
      child: ImageFiltered(
        imageFilter: _MorphPlayPauseButton._glowBlurFilter,
        child: Center(
          child: AnimatedIcon(
            icon: AnimatedIcons.play_pause,
            progress: _controller,
            color: widget.glowColor,
            size: widget.size,
          ),
        ),
      ),
    );
  }
}

class _HotkeyPulseIconButton extends StatefulWidget {
  const _HotkeyPulseIconButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    required this.hotkeyAction,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final Widget icon;
  final HotkeyUiAction hotkeyAction;

  @override
  State<_HotkeyPulseIconButton> createState() => _HotkeyPulseIconButtonState();
}

class _HotkeyPulseIconButtonState extends State<_HotkeyPulseIconButton> {
  double _scale = 1.0;
  Timer? _timer;
  int _lastSerial = 0;
  late final VoidCallback _listener;

  void _pulse() {
    _timer?.cancel();
    setState(() => _scale = 0.92);
    _timer = Timer(MotionDuration.fast, () {
      if (mounted) setState(() => _scale = 1.0);
    });
  }

  @override
  void initState() {
    super.initState();
    _listener = () {
      final event = hotkeyUiFeedback.lastEvent;
      if (event == null) return;
      if (event.action != widget.hotkeyAction) return;
      if (event.serial == _lastSerial) return;
      _lastSerial = event.serial;
      _pulse();
    };
    hotkeyUiFeedback.addListener(_listener);
  }

  @override
  void dispose() {
    _timer?.cancel();
    hotkeyUiFeedback.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      duration: MotionDuration.fast,
      curve: MotionCurve.standard,
      scale: _scale,
      child: IconButton(
        tooltip: widget.tooltip,
        onPressed: widget.onPressed,
        icon: widget.icon,
      ),
    );
  }
}

/// glow slider
class _NowPlayingSlider extends StatefulWidget {
  final NowPlayingMode mode;
  const _NowPlayingSlider({required this.mode});

  @override
  State<_NowPlayingSlider> createState() => _NowPlayingSliderState();
}

class _NowPlayingSliderState extends State<_NowPlayingSlider>
    with TickerProviderStateMixin {
  final dragPosition = ValueNotifier(0.0);
  final livePosition = ValueNotifier(0.0);
  final livePositionSeconds = ValueNotifier(0);
  final isDragging = ValueNotifier(false);
  final isHovering = ValueNotifier(false);
  late final PlaybackService _playbackService;
  late final VoidCallback _playerStateListener;
  late final VoidCallback _nowPlayingListener;
  late final VoidCallback _positionSyncListener;
  Timer? _positionSyncTimer;
  Ticker? _progressTicker;
  Duration _lastProgressTickElapsed = Duration.zero;
  int _lastPositionMs = -1;
  bool _tickerModeEnabled = true;
  bool _isPlaying = false;
  double _trackLength = 1.0;
  late final AnimationController _wavyController;
  static const _wavyCycle = Duration(seconds: 4);
  bool _wavyActive = false;
  Duration? _lastWavyTick;
  late final VoidCallback _settingsListener;

  @override
  void initState() {
    super.initState();
    _wavyController = AnimationController(vsync: this, duration: _wavyCycle);
    _playbackService = context.read<PlaybackService>();
    _isPlaying = _playbackService.playerState == PlayerState.playing;
    _syncFromNative(force: true);
    _syncWavyAnimation(_playbackService.playerState);
    _syncProgressDriver(_playbackService.playerState);
    _playerStateListener = () {
      final state = _playbackService.playerState;
      _syncWavyAnimation(state);
      _syncProgressDriver(state);
    };
    _playbackService.playerStateNotifier.addListener(_playerStateListener);
    // 波浪开关对应的通知不经过 playerState，播放中切换设置也需要重新同步。
    _settingsListener = () {
      _syncWavyAnimation(_playbackService.playerState);
    };
    AppSettings.rebuildNotifier.addListener(_settingsListener);
    _nowPlayingListener = () {
      _syncFromNative(force: true);
      _syncProgressDriver(_playbackService.playerState);
      if (mounted) setState(() {});
    };
    _positionSyncListener = () {
      _lastProgressTickElapsed = Duration.zero;
      _lastWavyTick = null;
      _syncFromNative(force: true);
    };
    _playbackService.nowPlayingNotifier.addListener(_nowPlayingListener);
    _playbackService.positionSyncNotifier.addListener(_positionSyncListener);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    if (_tickerModeEnabled == tickerModeEnabled) return;
    _tickerModeEnabled = tickerModeEnabled;
    if (!tickerModeEnabled) return;
    _lastProgressTickElapsed = Duration.zero;
    _lastWavyTick = null;
    _syncFromNative(force: true);
    _syncWavyAnimation(_playbackService.playerState);
  }

  void _syncFromNative({bool force = false}) {
    if (isDragging.value) return;
    _trackLength = _playbackService.length;
    _syncLivePosition(_playbackService.position, force: force);
  }

  void _syncWavyAnimation(PlayerState state) {
    final enabled = AppSettings.instance.wavyBarEnabledModes.contains(
      widget.mode,
    );
    // 波浪不再自己跑 ticker，改由进度 ticker 逐帧推进相位
    final shouldRun = enabled && state == PlayerState.playing;
    if (shouldRun == _wavyActive) return;
    _wavyActive = shouldRun;
    _lastWavyTick = null;
  }

  void _syncProgressDriver(PlayerState state) {
    _syncFromNative(force: true);
    _isPlaying = state == PlayerState.playing;
    if (!_isPlaying) {
      _positionSyncTimer?.cancel();
      _positionSyncTimer = null;
      _progressTicker?.stop();
      return;
    }
    _positionSyncTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _syncFromNative(force: true);
    });
    _startProgressTicker();
  }

  void _startProgressTicker() {
    if (_progressTicker?.isActive == true) return;
    _lastProgressTickElapsed = Duration.zero;
    _lastWavyTick = null;
    _progressTicker ??= createTicker(_onProgressTick);
    _progressTicker!.start();
  }

  void _onProgressTick(Duration elapsed) {
    if (!_isPlaying) return;
    _advanceWavyBar(elapsed);
    if (isDragging.value) {
      _lastProgressTickElapsed = elapsed;
      return;
    }
    if (_lastProgressTickElapsed == Duration.zero) {
      _lastProgressTickElapsed = elapsed;
      return;
    }
    final delta = elapsed - _lastProgressTickElapsed;
    _lastProgressTickElapsed = elapsed;
    if (delta <= Duration.zero) return;
    final length = _trackLength;
    final next = livePosition.value + delta.inMicroseconds / 1000000.0;
    _syncLivePosition(length > 0 ? next.clamp(0.0, length).toDouble() : next);
  }

  void _advanceWavyBar(Duration elapsed) {
    if (!_wavyActive) return;
    final last = _lastWavyTick;
    final delta = last == null ? Duration.zero : elapsed - last;
    _lastWavyTick = elapsed;
    if (delta <= Duration.zero) return;
    final step = delta.inMicroseconds / _wavyCycle.inMicroseconds;
    _wavyController.value = (_wavyController.value + step) % 1.0;
  }

  void _syncLivePosition(double position, {bool force = false}) {
    final nowMs = (position * 1000).round();
    if (!force && nowMs == _lastPositionMs) return;
    _lastPositionMs = nowMs;
    livePosition.value = position;
    final seconds = position.floor();
    if (livePositionSeconds.value != seconds) {
      livePositionSeconds.value = seconds;
    }
  }

  @override
  void activate() {
    super.activate();
    _syncFromNative(force: true);
    _syncProgressDriver(_playbackService.playerState);
  }

  @override
  void dispose() {
    _positionSyncTimer?.cancel();
    _progressTicker?.dispose();
    AppSettings.rebuildNotifier.removeListener(_settingsListener);
    _playbackService.playerStateNotifier.removeListener(_playerStateListener);
    _playbackService.nowPlayingNotifier.removeListener(_nowPlayingListener);
    _playbackService.positionSyncNotifier.removeListener(_positionSyncListener);
    dragPosition.dispose();
    livePosition.dispose();
    livePositionSeconds.dispose();
    isDragging.dispose();
    isHovering.dispose();
    _wavyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playbackService = context.read<PlaybackService>();
    return ListenableBuilder(
      listenable: AppSettings.rebuildNotifier,
      builder: (context, _) {
        final nowPlayingLength = playbackService.length;
        final useMonetBar = AppSettings.instance.useMaterialYouForProgressBar;
        final useWavyBar = AppSettings.instance.wavyBarEnabledModes.contains(
          widget.mode,
        );
        final barColor = playerChromeForeground(context, enabled: useMonetBar);
        final barGlow = useMonetBar
            ? scheme.primaryContainer
            : playerThemeForeground(
                scheme,
                enabled: false,
              ).withValues(alpha: 0.3);
        final showSpectrum =
            widget.mode != NowPlayingMode.immersive &&
            AppSettings.instance.showSpectrumBar;

        if (showSpectrum) {
          return _spectrumProgressArea(
            scheme: scheme,
            playbackService: playbackService,
            nowPlayingLength: nowPlayingLength,
            barColor: barColor,
            barGlow: barGlow,
            useWavyBar: useWavyBar,
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _timeRow(scheme, nowPlayingLength),
            _progressArea(
              scheme: scheme,
              playbackService: playbackService,
              nowPlayingLength: nowPlayingLength,
              barColor: barColor,
              barGlow: barGlow,
              useWavyBar: useWavyBar,
            ),
          ],
        );
      },
    );
  }

  Widget _spectrumProgressArea({
    required ColorScheme scheme,
    required PlaybackService playbackService,
    required double nowPlayingLength,
    required Color barColor,
    required Color barGlow,
    required bool useWavyBar,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 50.0),
            child: _seekBarTrack(
              scheme: scheme,
              playbackService: playbackService,
              nowPlayingLength: nowPlayingLength,
              barColor: barColor,
              barGlow: barGlow,
              useWavyBar: useWavyBar,
            ),
          ),
          SizedBox(
            height: 46.0,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _PlaybackPositionText(
                  secondsListenable: livePositionSeconds,
                  color: scheme.onSurface,
                ),
                const SizedBox(width: 8.0),
                Expanded(
                  child: SpectrumBar(
                    height: 42.0,
                    color: playerChromeForeground(
                      context,
                      enabled:
                          AppSettings.instance.useMaterialYouForSpectrumBar,
                    ),
                  ),
                ),
                const SizedBox(width: 8.0),
                Text(
                  Duration(
                    milliseconds: (nowPlayingLength * 1000).toInt(),
                  ).toStringMSS(),
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _progressArea({
    required ColorScheme scheme,
    required PlaybackService playbackService,
    required double nowPlayingLength,
    required Color barColor,
    required Color barGlow,
    required bool useWavyBar,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: _seekBarTrack(
        scheme: scheme,
        playbackService: playbackService,
        nowPlayingLength: nowPlayingLength,
        barColor: barColor,
        barGlow: barGlow,
        useWavyBar: useWavyBar,
      ),
    );
  }

  Widget _seekBarTrack({
    required ColorScheme scheme,
    required PlaybackService playbackService,
    required double nowPlayingLength,
    required Color barColor,
    required Color barGlow,
    required bool useWavyBar,
  }) {
    return SizedBox(
      height: 24,
      child: LayoutBuilder(
        builder: (context, constraints) => _seekBar(
          context,
          scheme,
          playbackService,
          constraints.maxWidth,
          nowPlayingLength > 0 ? nowPlayingLength : 1.0,
          barColor,
          barGlow,
          useWavyBar,
        ),
      ),
    );
  }

  Widget _timeRow(ColorScheme scheme, double nowPlayingLength) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _PlaybackPositionText(
            secondsListenable: livePositionSeconds,
            color: scheme.onSurface,
          ),
          Text(
            Duration(
              milliseconds: (nowPlayingLength * 1000).toInt(),
            ).toStringMSS(),
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  double _seekValue(double dx, double width, double max) {
    return (dx / width).clamp(0.0, 1.0) * max;
  }

  Widget _seekBar(
    BuildContext context,
    ColorScheme scheme,
    PlaybackService playbackService,
    double width,
    double max,
    Color barColor,
    Color barGlow,
    bool useWavyBar,
  ) {
    return MouseRegion(
      onEnter: (_) => isHovering.value = true,
      onExit: (_) => isHovering.value = false,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (details) {
          isDragging.value = true;
          final value = _seekValue(details.localPosition.dx, width, max);
          dragPosition.value = value;
          _syncLivePosition(value, force: true);
        },
        onHorizontalDragUpdate: (details) {
          final value = _seekValue(details.localPosition.dx, width, max);
          dragPosition.value = value;
          _syncLivePosition(value, force: true);
        },
        onHorizontalDragEnd: (details) {
          isDragging.value = false;
          _syncLivePosition(dragPosition.value, force: true);
          playbackService.seek(dragPosition.value);
        },
        // 点击抬起才落 seek：拖动由 onHorizontalDragEnd 落 seek，
        // 用 onTapDown 会在拖动开始时先 seek 一次，造成重复定位。
        onTapUp: (details) {
          final value = _seekValue(details.localPosition.dx, width, max);
          _syncLivePosition(value, force: true);
          playbackService.seek(value);
        },
        child: _progressPaint(
          scheme,
          width,
          max,
          barColor,
          barGlow,
          useWavyBar,
        ),
      ),
    );
  }

  Color _inactiveBarColor(ColorScheme scheme) {
    if (scheme.brightness == Brightness.dark) {
      return scheme.surfaceContainerHighest;
    }
    return const Color(0x33FFFFFF);
  }

  Widget _progressPaint(
    ColorScheme scheme,
    double width,
    double max,
    Color barColor,
    Color barGlow,
    bool useWavyBar,
  ) {
    return ListenableBuilder(
      listenable: Listenable.merge([isDragging, isHovering]),
      builder: (context, _) {
        final reduceMotion = MediaQuery.disableAnimationsOf(context);
        final thumbRadius = isDragging.value
            ? 10.0
            : (isHovering.value ? 8.0 : 6.0);
        return TweenAnimationBuilder<double>(
          duration: reduceMotion ? Duration.zero : MotionDuration.xFast,
          curve: MotionCurve.entrance,
          tween: Tween(begin: thumbRadius, end: thumbRadius),
          builder: (context, radius, _) {
            return CustomPaint(
              painter: _ProgressSliderPainter(
                livePosition: livePosition,
                dragPosition: dragPosition,
                isDragging: isDragging,
                max: max,
                color: barColor,
                glowColor: barGlow,
                inactiveColor: _inactiveBarColor(scheme),
                useWavyBar: useWavyBar,
                wavyController: _wavyController,
                thumbRadius: radius,
              ),
              size: Size(width, 24),
            );
          },
        );
      },
    );
  }
}

class _PlaybackPositionText extends StatefulWidget {
  const _PlaybackPositionText({
    required this.secondsListenable,
    required this.color,
  });

  final ValueListenable<int> secondsListenable;
  final Color color;

  @override
  State<_PlaybackPositionText> createState() => _PlaybackPositionTextState();
}

class _PlaybackPositionTextState extends State<_PlaybackPositionText> {
  late int _displaySeconds;

  @override
  void initState() {
    super.initState();
    _displaySeconds = widget.secondsListenable.value;
    widget.secondsListenable.addListener(_onPositionChanged);
  }

  void _onPositionChanged() {
    final nextSeconds = widget.secondsListenable.value;
    if (nextSeconds == _displaySeconds || !mounted) return;
    setState(() {
      _displaySeconds = nextSeconds;
    });
  }

  @override
  void didUpdateWidget(covariant _PlaybackPositionText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.secondsListenable != widget.secondsListenable) {
      oldWidget.secondsListenable.removeListener(_onPositionChanged);
      widget.secondsListenable.addListener(_onPositionChanged);
      _displaySeconds = widget.secondsListenable.value;
    }
  }

  @override
  void dispose() {
    widget.secondsListenable.removeListener(_onPositionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      Duration(seconds: _displaySeconds).toStringMSS(),
      style: TextStyle(
        color: widget.color,
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _ProgressSliderPainter extends CustomPainter {
  final ValueListenable<double> livePosition;
  final ValueListenable<double> dragPosition;
  final ValueListenable<bool> isDragging;
  final double max;
  final Color color;
  final Color glowColor;
  final Color inactiveColor;
  final bool useWavyBar;
  final Animation<double> wavyController;
  final double thumbRadius;
  final Paint _paint = Paint()
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.fill;
  final Paint _thumbGlowPaint = Paint()
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
  final Path _wavePath = Path();

  _ProgressSliderPainter({
    required this.livePosition,
    required this.dragPosition,
    required this.isDragging,
    required this.max,
    required this.color,
    required this.glowColor,
    required this.inactiveColor,
    required this.useWavyBar,
    required this.wavyController,
    this.thumbRadius = 6.0,
  }) : super(
         repaint: Listenable.merge([
           livePosition,
           dragPosition,
           isDragging,
           if (useWavyBar) wavyController,
         ]),
       );

  double get _fraction {
    final position = isDragging.value
        ? dragPosition.value
        : livePosition.value > max
        ? max
        : livePosition.value;
    return max > 0 ? (position / max).clamp(0.0, 1.0) : 0.0;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final fraction = _fraction;
    if (useWavyBar) {
      _paintWavy(canvas, size, fraction, wavyController.value * 2 * pi);
      return;
    }
    _paintSolid(canvas, size, fraction);
  }

  void _paintSolid(Canvas canvas, Size size, double fraction) {
    const height = 4.0;
    final centerY = size.height / 2;
    final activeWidth = size.width * fraction;
    _paint
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round
      ..shader = null
      ..maskFilter = null
      ..color = inactiveColor;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, centerY - height / 2, size.width, height),
        const Radius.circular(height / 2),
      ),
      _paint,
    );
    if (activeWidth > 0) {
      _paint
        ..color = color
        ..shader = null;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, centerY - height / 2, activeWidth, height),
          const Radius.circular(height / 2),
        ),
        _paint,
      );
    }
    _paint
      ..shader = null
      ..color = color;
    _thumbGlowPaint.color = glowColor.withValues(alpha: 0.15);
    canvas.drawCircle(
      Offset(activeWidth, centerY),
      thumbRadius - 1,
      _thumbGlowPaint,
    );
    canvas.drawCircle(Offset(activeWidth, centerY), thumbRadius, _paint);
  }

  void _paintWavy(Canvas canvas, Size size, double fraction, double phase) {
    const double strokeWidth = 3.5;
    final double centerY = size.height / 2;
    final double activeWidth = size.width * fraction;

    final paint = _paint
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = null
      ..maskFilter = null;

    // Inactive track: straight line
    paint.color = inactiveColor;
    canvas.drawLine(
      Offset(activeWidth, centerY),
      Offset(size.width, centerY),
      paint,
    );

    if (activeWidth <= 0) return;

    paint.color = color;
    canvas.drawPath(_wavePathFor(centerY, activeWidth, phase), paint);

    paint
      ..style = PaintingStyle.fill
      ..color = glowColor.withValues(alpha: 0.15)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawCircle(Offset(activeWidth, centerY), thumbRadius - 1, paint);

    paint
      ..shader = null
      ..maskFilter = null
      ..color = color;
    canvas.drawCircle(Offset(activeWidth, centerY), thumbRadius, paint);
  }

  Path _wavePathFor(double centerY, double activeWidth, double phase) {
    const amplitude = 2.5;
    const wavelength = 44.0;
    const sampleStep = 1.5;
    const freq = 2 * pi / wavelength;
    final wavePath = _wavePath..reset();
    wavePath.moveTo(0, centerY + amplitude * sin(phase));
    for (double x = 0.0; x <= activeWidth; x += sampleStep) {
      wavePath.lineTo(x, centerY + amplitude * sin(phase + x * freq));
    }
    if (activeWidth > 0) {
      wavePath.lineTo(
        activeWidth,
        centerY + amplitude * sin(phase + activeWidth * freq),
      );
    }
    return wavePath;
  }

  @override
  bool shouldRepaint(covariant _ProgressSliderPainter oldDelegate) {
    return oldDelegate.livePosition != livePosition ||
        oldDelegate.dragPosition != dragPosition ||
        oldDelegate.isDragging != isDragging ||
        oldDelegate.max != max ||
        oldDelegate.color != color ||
        oldDelegate.glowColor != glowColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.useWavyBar != useWavyBar ||
        oldDelegate.wavyController != wavyController ||
        oldDelegate.thumbRadius != thumbRadius;
  }
}

const _playbackCoverRotationPeriod = Duration(seconds: 24);

class _PlaybackCoverRotationMemory {
  static String? _path;
  static double _offsetTurns = 0.0;
  static int _generation = 0;

  static double initialTurns({
    required String? path,
    required double position,
  }) {
    final baseTurns = _positionTurns(position);
    if (_path != path) {
      _path = path;
      _offsetTurns = 0.0;
      _generation++;
    }
    return _wrapTurns(baseTurns + _offsetTurns);
  }

  static int get generation => _generation;

  static void remember({
    required String path,
    required double position,
    required double turns,
    required int generation,
  }) {
    if (_path != path || _generation != generation) return;
    _path = path;
    _offsetTurns = _wrapTurns(turns - _positionTurns(position));
  }

  static double _positionTurns(double position) {
    if (!position.isFinite || position < 0) return 0.0;
    return position / (_playbackCoverRotationPeriod.inMilliseconds / 1000.0);
  }

  static double _wrapTurns(double turns) {
    final wrapped = turns % 1.0;
    return wrapped < 0 ? wrapped + 1.0 : wrapped;
  }
}

// 播放中封面为 1，暂停、停止、播完缩到 0.88。圆形封面播放时旋转，暂停时减速收停。
class _PlaybackCoverMotion extends StatefulWidget {
  const _PlaybackCoverMotion({
    required this.child,
    required this.rotate,
    required this.identity,
  });

  final Widget child;
  final bool rotate;
  final String? identity;

  @override
  State<_PlaybackCoverMotion> createState() => _PlaybackCoverMotionState();
}

class _PlaybackCoverMotionState extends State<_PlaybackCoverMotion>
    with TickerProviderStateMixin {
  static const _pausedCoverScale = 0.88;
  static const _pauseSettleDuration = Duration(milliseconds: 180);
  static const _pauseSettleTurns = 0.018;

  final playback = PlayService.instance.playbackService;
  late final AnimationController _rotationController;
  late PlayerState _playerState;
  bool _reduceMotion = false;
  bool _isSettling = false;
  int _rotationMemoryGeneration = 0;
  Ticker? _rotationTicker;
  Duration? _lastRotationTick;
  bool? _tickerModeEnabled;

  bool get _isPlaying => _playerState == PlayerState.playing;

  @override
  void initState() {
    super.initState();
    final initialTurns = _PlaybackCoverRotationMemory.initialTurns(
      path: widget.identity,
      position: playback.position,
    );
    _rotationMemoryGeneration = _PlaybackCoverRotationMemory.generation;
    _rotationController = AnimationController(
      vsync: this,
      duration: _playbackCoverRotationPeriod,
      value: initialTurns,
    );
    _playerState = playback.playerStateNotifier.value;
    playback.playerStateNotifier.addListener(_onPlayerStateChanged);
    _syncRotation(immediate: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    if (tickerModeResumed(
      previousEnabled: _tickerModeEnabled,
      enabled: tickerModeEnabled,
    )) {
      // 静音期间 Ticker 不回调，恢复后的 elapsed 含整段静音时长，丢弃旧基准。
      _lastRotationTick = null;
    }
    _tickerModeEnabled = tickerModeEnabled;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion == reduceMotion) return;
    _reduceMotion = reduceMotion;
    _syncRotation(immediate: reduceMotion);
  }

  void _onPlayerStateChanged() {
    final nextState = playback.playerStateNotifier.value;
    if (_playerState == nextState) return;
    _playerState = nextState;
    if (mounted) setState(() {});
    _syncRotation(immediate: false);
  }

  void _syncRotation({required bool immediate}) {
    if (!widget.rotate || _reduceMotion) {
      _stopRotationTicker();
      _rotationController.stop(canceled: false);
      _isSettling = false;
      return;
    }

    if (_isPlaying) {
      if (_isSettling) {
        _rotationController.stop(canceled: false);
        _isSettling = false;
      }
      _startRotationTicker();
      return;
    }

    final rotating = _rotationTicker?.isActive == true;
    if (!rotating || _isSettling) return;
    _stopRotationTicker();
    _rotationController.stop(canceled: false);
    if (immediate) return;

    final current = _rotationController.value;
    final target = min(1.0, current + _pauseSettleTurns);
    if (target <= current) return;
    _isSettling = true;
    _rotationController
        .animateTo(
          target,
          duration: _pauseSettleDuration,
          curve: Curves.easeOutCubic,
        )
        .whenCompleteOrCancel(() => _isSettling = false);
  }

  void _startRotationTicker() {
    if (_rotationTicker?.isActive == true) return;
    _lastRotationTick = null;
    _rotationTicker ??= createTicker(_onRotationTick);
    _rotationTicker!.start();
  }

  void _stopRotationTicker() {
    _rotationTicker?.stop();
    _lastRotationTick = null;
  }

  void _onRotationTick(Duration elapsed) {
    final last = _lastRotationTick;
    final delta = tickerFrameDelta(last, elapsed);
    _lastRotationTick = elapsed;
    if (delta <= Duration.zero) return;
    final step =
        delta.inMicroseconds / _playbackCoverRotationPeriod.inMicroseconds;
    _rotationController.value = (_rotationController.value + step) % 1.0;
  }

  @override
  void didUpdateWidget(covariant _PlaybackCoverMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rotate != widget.rotate) {
      _syncRotation(immediate: !widget.rotate);
    }
    if (oldWidget.identity != widget.identity) {
      _stopRotationTicker();
      _rotationController.stop(canceled: false);
      _rotationController.value = _PlaybackCoverRotationMemory.initialTurns(
        path: widget.identity,
        position: playback.position,
      );
      _rotationMemoryGeneration = _PlaybackCoverRotationMemory.generation;
      _syncRotation(immediate: true);
    }
  }

  @override
  void dispose() {
    final nowPlaying = playback.nowPlaying;
    if (widget.identity != null && nowPlaying?.path == widget.identity) {
      _PlaybackCoverRotationMemory.remember(
        path: widget.identity!,
        position: playback.position,
        turns: _rotationController.value,
        generation: _rotationMemoryGeneration,
      );
    }
    playback.playerStateNotifier.removeListener(_onPlayerStateChanged);
    _rotationTicker?.dispose();
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active =
        _playerState == PlayerState.playing ||
        _playerState == PlayerState.stalled;
    return SpringProgress(
      target: active ? 1.0 : _pausedCoverScale,
      spring: MotionSpring.layout,
      child: widget.child,
      builder: (context, scale, child) => AnimatedBuilder(
        animation: _rotationController,
        child: child,
        builder: (context, child) {
          final rotation = widget.rotate
              ? _rotationController.value * 2 * pi
              : 0.0;
          return Transform.rotate(
            angle: rotation,
            child: Transform.scale(scale: scale, child: child),
          );
        },
      ),
    );
  }
}

class _PlaybackCoverFrame extends StatelessWidget {
  const _PlaybackCoverFrame({required this.scheme, required this.child});

  final ColorScheme scheme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final circle = AppSettings.instance.circlePlaybackCover;
    final borderRadius = BorderRadius.circular(12.0);
    // 封面旋转 / 暂停回弹只改这一层的变换，阴影、圆角和图片采样结果留在
    // 自己的绘制缓存里，不必每帧重绘。
    return RepaintBoundary(
      child: Container(
        decoration: BoxDecoration(
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: circle ? null : borderRadius,
          border: circle
              ? Border.all(
                  color: scheme.onSurface.withValues(alpha: 0.09),
                  width: 1.0,
                )
              : null,
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.2),
              spreadRadius: 0,
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: circle
            ? ClipOval(child: child)
            : ClipRRect(borderRadius: borderRadius, child: child),
      ),
    );
  }
}

/// 按实际显示像素解码封面，避免切歌/切换封面时把源图按原始分辨率送入采样。
ImageProvider<Object> _resizedCoverProvider(
  ImageProvider<Object> provider,
  double coverSize,
  double devicePixelRatio,
) {
  final pixelWidth = (coverSize * devicePixelRatio).round();
  if (pixelWidth <= 0) return provider;
  return ResizeImage(
    provider,
    width: pixelWidth,
    height: pixelWidth,
    allowUpscaling: false,
  );
}

/// title, artist, album, cover
class _NowPlayingInfo extends StatefulWidget {
  const _NowPlayingInfo({
    this.usePortraitCoverSize = false,
    this.coverSizeOverride,
  });

  final bool usePortraitCoverSize;
  final double? coverSizeOverride;

  @override
  State<_NowPlayingInfo> createState() => __NowPlayingInfoState();
}

class __NowPlayingInfoState extends State<_NowPlayingInfo> {
  final playbackService = PlayService.instance.playbackService;
  ImageProvider<Object>? _hiResCover;
  String? _hiResCoverPath;
  Timer? _hiResDebounceTimer;
  Animation<double>? _routeAnimation;
  int _coverRequestToken = 0;
  Uint8List? _immediateCover;
  String? _immediateCoverPath;
  MemoryImage? _cachedImmediateCoverImage;
  double? _coverSizeForPrefetch;
  String? _prefetchedCoverPath;

  bool get _routeReady {
    final animation = ModalRoute.of(context)?.animation;
    return animation == null || animation.status == AnimationStatus.completed;
  }

  void _removeRouteAnimationListener() {
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    _routeAnimation = null;
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _removeRouteAnimationListener();
    if (mounted) _onPlaybackChange();
  }

  void _waitForRouteReady() {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      _removeRouteAnimationListener();
      _onPlaybackChange();
      return;
    }
    if (identical(animation, _routeAnimation)) return;
    _removeRouteAnimationListener();
    _routeAnimation = animation;
    animation.addStatusListener(_onRouteAnimationStatus);
  }

  void _onPlaybackChange() {
    _coverRequestToken += 1;
    final token = _coverRequestToken;
    _hiResDebounceTimer?.cancel();
    final nextAudio = playbackService.nowPlaying;
    if (nextAudio == null) {
      _clearInfoCovers();
      return;
    }
    final path = nextAudio.path;
    final cachedLargeCover = nextAudio.cachedLargeCover;
    _applyImmediateCover(nextAudio, path, cachedLargeCover);
    if (_immediateCover == null) {
      _loadSmallCover(nextAudio, token, path);
    }
    if (!_routeReady) {
      _waitForRouteReady();
      return;
    }
    _removeRouteAnimationListener();
    if (cachedLargeCover != null) {
      // 当前封面已是解码缓存，直接预取下一首；否则等大图就绪后再预取，
      // 避免两首封面同时解码抢同一帧。
      _prefetchNextCover(nextAudio);
      return;
    }
    _scheduleHiResCover(nextAudio, token, path);
  }

  void _clearInfoCovers() {
    _removeRouteAnimationListener();
    if (_hiResCoverPath == null && _immediateCoverPath == null) return;
    setState(() {
      _hiResCover = null;
      _hiResCoverPath = null;
      _immediateCover = null;
      _immediateCoverPath = null;
      _cachedImmediateCoverImage = null;
    });
  }

  void _applyImmediateCover(
    Audio nextAudio,
    String path,
    ImageProvider? cachedLargeCover,
  ) {
    setState(() {
      _immediateCover = nextAudio.smallCoverBytes;
      _immediateCoverPath = path;
      _hiResCover = cachedLargeCover;
      _hiResCoverPath = cachedLargeCover == null ? null : path;
      _cachedImmediateCoverImage = _immediateCover != null
          ? MemoryImage(_immediateCover!)
          : null;
    });
  }

  void _loadSmallCover(Audio nextAudio, int token, String path) {
    nextAudio.loadSmallCoverBytes().then((bytes) {
      if (!mounted || token != _coverRequestToken) return;
      if (playbackService.nowPlaying?.path != path) return;
      setState(() {
        _immediateCover = bytes;
        _cachedImmediateCoverImage = bytes != null ? MemoryImage(bytes) : null;
      });
    });
  }

  void _scheduleHiResCover(Audio nextAudio, int token, String path) {
    _hiResDebounceTimer = Timer(MotionDuration.xFast, () {
      if (!mounted || token != _coverRequestToken) return;
      nextAudio.largeCover.then((image) async {
        if (!mounted || token != _coverRequestToken) return;
        if (playbackService.nowPlaying?.path != path) return;
        if (image != null) {
          try {
            await precacheImage(_prefetchProvider(image), context);
          } catch (error) {
            // 预缓存失败记录为 debug 日志，封面由 Image 的 errorBuilder 兜底。
            log.app.debug(
              'now_playing_cover_precache_failed',
              '当前播放封面预加载失败',
              fields: {'error': error.runtimeType.toString()},
            );
          }
        }
        if (!mounted || token != _coverRequestToken) return;
        setState(() {
          _hiResCover = image;
          _hiResCoverPath = image == null ? null : path;
        });
        _prefetchNextCover(nextAudio);
      });
    });
  }

  /// 预取当前显示尺寸的解码缓存，命中后再交给 [ResizeImage] 直接复用。
  ImageProvider<Object> _prefetchProvider(ImageProvider<Object> provider) {
    return _resizedCoverProvider(
      provider,
      _coverSizeForPrefetch ?? 420.0,
      MediaQuery.devicePixelRatioOf(context),
    );
  }

  /// 队列下一首的封面先解码进 ImageCache，下一次切歌不再在过渡动画里解码。
  void _prefetchNextCover(Audio current) {
    if (_prefetchedCoverPath == current.path) return;
    final playlist = playbackService.playlist.value;
    if (playlist.length < 2) return;
    final index = playbackService.playlistIndex;
    if (index < 0 || index >= playlist.length) return;
    final int? nextIndex = switch (playbackService.playMode.value) {
      PlayMode.forward || PlayMode.loop => (index + 1) % playlist.length,
      PlayMode.singleLoop => index,
      PlayMode.listOnce => index + 1 < playlist.length ? index + 1 : null,
    };
    if (nextIndex == null) return;
    final next = playlist[nextIndex];
    if (identical(next, current)) return;
    _prefetchedCoverPath = current.path;
    unawaited(
      next.largeCover
          .then((image) {
            if (!mounted || image == null) return;
            if (playbackService.nowPlaying?.path != current.path) return;
            unawaited(
              precacheImage(_prefetchProvider(image), context).catchError((
                Object error,
              ) {
                log.app.debug(
                  'now_playing_cover_prefetch_failed',
                  '下一首封面预加载失败',
                  fields: {'error': error.runtimeType.toString()},
                );
              }),
            );
          })
          .catchError((Object error) {
            log.app.debug(
              'now_playing_cover_prefetch_failed',
              '下一首封面读取失败',
              fields: {'error': error.runtimeType.toString()},
            );
          }),
    );
  }

  @override
  void initState() {
    super.initState();
    playbackService.nowPlayingNotifier.addListener(_onPlaybackChange);

    final audio = playbackService.nowPlaying;
    if (audio != null) {
      _immediateCover = audio.smallCoverBytes;
      _immediateCoverPath = audio.path;
      _hiResCover = audio.cachedLargeCover;
      _hiResCoverPath = _hiResCover == null ? null : audio.path;
      _cachedImmediateCoverImage = _immediateCover != null
          ? MemoryImage(_immediateCover!)
          : null;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _onPlaybackChange();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final nowPlaying = playbackService.nowPlaying;
    final nowPlayingPath = nowPlaying?.path;
    final heroEnabled = !playbackService.nowPlayingChangedRecently;

    return LayoutBuilder(
      builder: (context, constraints) => _infoBody(
        scheme,
        nowPlaying,
        nowPlayingPath,
        heroEnabled,
        constraints,
      ),
    );
  }

  Widget _infoBody(
    ColorScheme scheme,
    Audio? nowPlaying,
    String? nowPlayingPath,
    bool heroEnabled,
    BoxConstraints constraints,
  ) {
    final coverSize = _coverSizeFor(constraints);
    _coverSizeForPrefetch = coverSize;
    final textWidth = _textWidthFor(constraints, coverSize);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      switchInCurve: Curves.easeOutQuart,
      switchOutCurve: Curves.easeInQuart,
      transitionBuilder: _coverTransition,
      child: Container(
        key: ValueKey(nowPlayingPath ?? 'now_playing_none'),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _coverBox(scheme, nowPlayingPath, coverSize, heroEnabled),
            const SizedBox(height: 24.0),
            const ConcertActLabel(),
            _infoText(
              nowPlaying == null ? 'Pure Music' : nowPlaying.title,
              scheme.onSurface,
              24,
              FontWeight.bold,
              textWidth,
            ),
            const SizedBox(height: 8),
            _infoText(
              nowPlaying == null ? 'Enjoy Music' : nowPlaying.artist,
              scheme.onSurface.withValues(alpha: 0.7),
              16,
              FontWeight.normal,
              textWidth,
            ),
          ],
        ),
      ),
    );
  }

  double _textWidthFor(BoxConstraints constraints, double coverSize) {
    final maxWidth = constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : MediaQuery.sizeOf(context).width;
    return min(maxWidth, max(coverSize, min(maxWidth, 240.0)));
  }

  Widget _coverBox(
    ColorScheme scheme,
    String? nowPlayingPath,
    double coverSize,
    bool heroEnabled,
  ) {
    final framed = _coverImage(scheme, nowPlayingPath, coverSize, framed: true);
    final motion = _PlaybackCoverMotion(
      rotate: AppSettings.instance.circlePlaybackCover,
      identity: nowPlayingPath,
      // 封面内容单独成层，旋转/缩放时只做合成，不重画图片和阴影
      child: RepaintBoundary(child: framed),
    );
    return SizedBox(
      width: coverSize,
      height: coverSize,
      child: heroEnabled && nowPlayingPath != null
          ? Hero(
              tag: nowPlayingPath,
              curve: AppSettings.instance.enableNowPlayingOpenMotion
                  ? nowPlayingOpenCurve
                  : Curves.fastOutSlowIn,
              reverseCurve: AppSettings.instance.enableNowPlayingOpenMotion
                  ? nowPlayingCloseCurve
                  : Curves.fastOutSlowIn.flipped,
              child: motion,
            )
          : motion,
    );
  }

  double _coverSizeFor(BoxConstraints constraints) {
    final viewportSize = MediaQuery.sizeOf(context);
    final maxWidth = constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : viewportSize.width;
    final maxHeight = constraints.maxHeight.isFinite
        ? constraints.maxHeight
        : viewportSize.height;
    return widget.coverSizeOverride ??
        (widget.usePortraitCoverSize
            ? _portraitNowPlayingCoverSize(
                maxWidth: maxWidth,
                maxHeight: maxHeight,
              )
            : _responsiveNowPlayingCoverSize(
                maxWidth: maxWidth,
                maxHeight: maxHeight,
              ));
  }

  Widget _coverTransition(Widget child, Animation<double> animation) {
    final offsetAnimation = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(animation);
    final scaleAnimation = Tween<double>(
      begin: 0.92,
      end: 1.0,
    ).animate(animation);
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: offsetAnimation,
        child: ScaleTransition(scale: scaleAnimation, child: child),
      ),
    );
  }

  Widget _coverImage(
    ColorScheme scheme,
    String? nowPlayingPath,
    double coverSize, {
    bool framed = false,
  }) {
    final placeholder = Icon(
      Symbols.queue_music,
      size: coverSize * 0.42,
      color: scheme.onSurface.withAlpha(60),
    );
    final currentCover = _hiResCoverPath == nowPlayingPath ? _hiResCover : null;
    final fallbackCover =
        currentCover == null &&
            playbackService.nowPlaying != null &&
            _immediateCoverPath == nowPlayingPath
        ? _cachedImmediateCoverImage
        : null;
    final provider = currentCover ?? fallbackCover;
    final image = provider == null
        ? ColoredBox(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.28),
            child: Center(child: placeholder),
          )
        : Image(
            image: _resizedCoverProvider(
              provider,
              coverSize,
              MediaQuery.devicePixelRatioOf(context),
            ),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: _routeReady
                ? FilterQuality.high
                : FilterQuality.medium,
            errorBuilder: (_, _, _) =>
                FittedBox(fit: BoxFit.contain, child: placeholder),
          );
    if (!framed) return image;
    return _PlaybackCoverFrame(scheme: scheme, child: image);
  }

  Widget _infoText(
    String text,
    Color color,
    double fontSize,
    FontWeight weight,
    double width,
  ) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontWeight: weight,
          fontSize: fontSize,
          height: 1.2,
        ),
      ),
    );
  }

  @override
  void dispose() {
    playbackService.nowPlayingNotifier.removeListener(_onPlaybackChange);
    _hiResDebounceTimer?.cancel();
    _removeRouteAnimationListener();
    super.dispose();
  }
}
