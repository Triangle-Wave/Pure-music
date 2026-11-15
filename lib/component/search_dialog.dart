import 'dart:async';

import 'package:pure_music/component/album_tile.dart';
import 'package:pure_music/component/artist_tile.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/search_dialog_layout.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/search_action_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/library/union_search_result.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/core/utils.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return QuietEmptyState(
      icon: icon,
      title: title,
      message: message,
      maxWidth: 380.0,
    );
  }
}

class SearchDialog extends StatefulWidget {
  const SearchDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => const SearchDialog(),
    );
  }

  @override
  State<SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<SearchDialog> {
  late final TextEditingController _searchController = TextEditingController();
  late final ValueNotifier<UnionSearchResult> _result = ValueNotifier(
    UnionSearchResult(''),
  );
  late final ValueNotifier<bool> _isSearching = ValueNotifier(false);
  Timer? _debounce;
  Timer? _persistDebounce;
  Timer? _queuedNextResetTimer;
  Timer? _libraryReadyPoll;
  Audio? _queuedNextAudio;
  Audio? _addingAudioToPlaylist;
  Playlist? _addingTargetPlaylist;
  late final ValueNotifier<bool> _awaitingLibraryReady = ValueNotifier(false);
  String _lastPersistedQuery = '';
  String _pendingPersistQuery = '';
  Future<void> _persistChain = Future<void>.value();
  int _libraryReadyPollsLeft = 0;
  String _restoredQuery = '';
  VoidCallback? _libraryVersionListener;

  @override
  void initState() {
    super.initState();
    _restoreLastQuery();
    WidgetsBinding.instance.addPostFrameCallback(_runRestoredSearch);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _persistDebounce?.cancel();
    _queuedNextResetTimer?.cancel();
    _libraryReadyPoll?.cancel();
    _libraryReadyPoll = null;
    final listener = _libraryVersionListener;
    if (listener != null) {
      AudioLibrary.libraryVersion.removeListener(listener);
      _libraryVersionListener = null;
    }
    try {
      _persistLastQuery(normalizedSearchQuery(_searchController.text));
    } catch (error, trace) {
      log.settings.warn(
        'search_query_persist_dispose_failed',
        '关闭搜索框时落盘异常，保留内存值',
        error: error,
        stackTrace: trace,
      );
    }
    _searchController.dispose();
    _result.dispose();
    _isSearching.dispose();
    _awaitingLibraryReady.dispose();
    super.dispose();
  }

  void _onQueryChanged(String raw) {
    final query = normalizedSearchQuery(raw);
    _debounce?.cancel();
    _schedulePersist(query);
    if (_awaitingLibraryReady.value) {
      _stopLibraryReadyWait();
    }
    if (query.isEmpty) {
      _result.value = UnionSearchResult('');
      _isSearching.value = false;
      return;
    }

    _isSearching.value = true;
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      try {
        _search(query);
      } catch (error, trace) {
        log.library.warn(
          'union_search_debounce_failed',
          '搜索防抖回调异常，按空结果降级',
          error: error,
          stackTrace: trace,
        );
        _result.value = UnionSearchResult(query);
      } finally {
        _isSearching.value = false;
      }
    });
  }

  void _search(String query) {
    _result.value = UnionSearchResult.search(query);
  }

  void _restoreLastQuery() {
    try {
      final query = normalizedSearchQuery(AppSettings.instance.lastSearchQuery);
      _lastPersistedQuery = query;
      _pendingPersistQuery = query;
      _restoredQuery = query;
      if (query.isEmpty) return;
      _searchController.text = query;
    } catch (error, trace) {
      log.library.warn(
        'search_query_restore_failed',
        '回显上次搜索词失败，按空关键词继续',
        error: error,
        stackTrace: trace,
      );
    }
  }

  void _runRestoredSearch(Duration _) {
    if (!mounted || _restoredQuery.isEmpty) return;
    if (normalizedSearchQuery(_searchController.text) != _restoredQuery) return;
    try {
      if (AudioLibrary.instance.audioCollection.isNotEmpty) {
        _search(_restoredQuery);
        return;
      }
      _result.value = UnionSearchResult(_restoredQuery);
      _awaitingLibraryReady.value = true;
      _isSearching.value = true;
      _libraryReadyPollsLeft = 10;
      final listener = _onLibraryVersionChanged;
      _libraryVersionListener = listener;
      AudioLibrary.libraryVersion.addListener(listener);
      _pollLibraryReady();
    } catch (error, trace) {
      log.library.warn(
        'search_query_restore_search_failed',
        '首帧恢复搜索异常，按空结果降级',
        error: error,
        stackTrace: trace,
      );
      _awaitingLibraryReady.value = false;
      _isSearching.value = false;
    }
  }

  void _onLibraryVersionChanged() {
    if (!mounted || !_awaitingLibraryReady.value) return;
    if (AudioLibrary.instance.audioCollection.isEmpty) return;
    _finishRestoredSearch();
  }

  void _pollLibraryReady() {
    _libraryReadyPoll?.cancel();
    _libraryReadyPoll = Timer(const Duration(milliseconds: 500), () {
      if (!mounted || !_awaitingLibraryReady.value) return;
      try {
        if (AudioLibrary.instance.audioCollection.isNotEmpty) {
          _finishRestoredSearch();
          return;
        }
        _libraryReadyPollsLeft--;
        if (_libraryReadyPollsLeft > 0) {
          _pollLibraryReady();
        } else {
          _stopLibraryReadyWait();
          log.library.warn(
            'search_query_restore_timeout',
            '曲库就绪等待超时，保留回显词与中性提示',
          );
        }
      } catch (error, trace) {
        _stopLibraryReadyWait();
        log.library.warn(
          'search_query_restore_poll_failed',
          '曲库就绪轮询异常，停止补搜',
          error: error,
          stackTrace: trace,
        );
      }
    });
  }

  void _finishRestoredSearch() {
    final listener = _libraryVersionListener;
    if (listener != null) {
      AudioLibrary.libraryVersion.removeListener(listener);
      _libraryVersionListener = null;
    }
    _libraryReadyPoll?.cancel();
    _libraryReadyPoll = null;
    if (normalizedSearchQuery(_searchController.text) != _restoredQuery) {
      _stopLibraryReadyWait();
      return;
    }
    try {
      _search(_restoredQuery);
    } catch (error, trace) {
      log.library.warn(
        'search_query_restore_retry_failed',
        '曲库就绪后补搜异常，按空结果降级',
        error: error,
        stackTrace: trace,
      );
      _result.value = UnionSearchResult(_restoredQuery);
    } finally {
      _awaitingLibraryReady.value = false;
      _isSearching.value = false;
    }
  }

  void _stopLibraryReadyWait() {
    final listener = _libraryVersionListener;
    if (listener != null) {
      AudioLibrary.libraryVersion.removeListener(listener);
      _libraryVersionListener = null;
    }
    _libraryReadyPoll?.cancel();
    _libraryReadyPoll = null;
    _awaitingLibraryReady.value = false;
    _isSearching.value = false;
  }

  void _schedulePersist(String query) {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      try {
        _persistLastQuery(query);
      } catch (error, trace) {
        log.settings.warn(
          'search_query_persist_debounce_failed',
          '搜索词落盘防抖回调异常，保留内存值等待关闭时兜底',
          error: error,
          stackTrace: trace,
        );
      }
    });
  }

  void _persistLastQuery(String query) {
    if (query == _lastPersistedQuery && query == _pendingPersistQuery) return;
    try {
      AppSettings.instance.lastSearchQuery = query;
      _pendingPersistQuery = query;
    } catch (error, trace) {
      log.settings.warn(
        'search_query_persist_failed',
        '更新上次搜索词异常，跳过本次落盘',
        error: error,
        stackTrace: trace,
      );
      return;
    }
    final previous = _persistChain;
    _persistChain = _enqueuePersist(previous, query);
    unawaited(_persistChain);
  }

  Future<void> _enqueuePersist(Future<void> previous, String query) async {
    try {
      await previous;
    } catch (error, trace) {
      log.settings.warn(
        'search_query_persist_chain_failed',
        '前一次落盘链异常，继续尝试写入最新搜索词',
        error: error,
        stackTrace: trace,
      );
    }
    await _saveLastQuery(query);
  }

  Future<void> _saveLastQuery(String query) async {
    try {
      final saved = await AppSettings.instance.saveSettings();
      if (!saved) {
        log.settings.warn(
          'search_query_persist_failed',
          '保存上次搜索词未成功，去重基准保持旧值等待重试',
        );
        return;
      }
      if (query == _pendingPersistQuery) {
        _lastPersistedQuery = query;
      }
    } catch (error, trace) {
      log.settings.warn(
        'search_query_persist_failed',
        '保存上次搜索词异常，去重基准保持旧值等待重试',
        error: error,
        stackTrace: trace,
      );
    }
  }

  void _addSearchResultToNext(Audio audio) {
    PlayService.instance.playbackService.addToNext(audio);
    _queuedNextResetTimer?.cancel();
    setState(() => _queuedNextAudio = audio);
    _queuedNextResetTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() => _queuedNextAudio = null);
    });
  }

  Future<void> _addSearchResultToPlaylist(
    Audio audio,
    Playlist playlist,
  ) async {
    if (_addingAudioToPlaylist != null) {
      return;
    }

    final added = playlist.containsPath(audio.path);
    if (added) {
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
        showTextOnSnackBar('保存歌单失败', variant: ToastVariant.error);
        return;
      }
      showTextOnSnackBar('已添加到歌单');
    } finally {
      _addingAudioToPlaylist = null;
      _addingTargetPlaylist = null;
      if (mounted) setState(() {});
    }
  }

  Widget _musicActionBar(Audio audio) {
    final isAddingThisAudio = identical(_addingAudioToPlaylist, audio);
    final isQueuedNext = identical(_queuedNextAudio, audio);
    final hasNowPlaying =
        PlayService.instance.playbackService.nowPlaying != null;
    final playlistMemberships = playlists
        .map((playlist) => playlist.containsPath(audio.path))
        .toList(growable: false);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _addNextButton(audio, isQueuedNext, hasNowPlaying),
        _playlistMenuButton(audio, isAddingThisAudio, playlistMemberships),
      ],
    );
  }

  Widget _addNextButton(Audio audio, bool isQueuedNext, bool hasNowPlaying) {
    final canAddNext = canAddAudioToNext(
      hasNowPlaying: hasNowPlaying,
      isPendingFeedback: isQueuedNext,
    );
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: isQueuedNext
          ? '已加入下一首'
          : hasNowPlaying
          ? '下一首播放'
          : '先播放一首歌',
      style: IconButton.styleFrom(
        backgroundColor: isQueuedNext ? scheme.primaryContainer : null,
        disabledBackgroundColor: isQueuedNext ? scheme.primaryContainer : null,
        disabledForegroundColor: isQueuedNext
            ? scheme.onPrimaryContainer
            : null,
      ),
      onPressed: canAddNext ? () => _addSearchResultToNext(audio) : null,
      icon: AnimatedSwitcher(
        duration: MotionDuration.xFast,
        switchInCurve: MotionCurve.standard,
        switchOutCurve: MotionCurve.standard,
        child: Icon(
          isQueuedNext ? Symbols.check : Symbols.plus_one,
          key: ValueKey(isQueuedNext),
        ),
      ),
    );
  }


  void _toggleMenu(MenuController controller) {
    if (controller.isOpen) {
      controller.close();
    } else {
      controller.open();
    }
  }

  Widget _playlistMenuIcon(bool isAdding, bool alreadyInAll) {
    if (isAdding) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Icon(alreadyInAll ? Symbols.check : Symbols.queue_music);
  }

  Widget _playlistMenuButton(
    Audio audio,
    bool isAddingThisAudio,
    List<bool> playlistMemberships,
  ) {
    final canOpenPlaylistMenu = canOpenSingleAudioAddToPlaylistMenu(
      hasAudio: true,
      isBusy: _addingAudioToPlaylist != null,
      alreadyInPlaylists: playlistMemberships,
    );
    final alreadyInAllPlaylists =
        playlists.isNotEmpty && playlistMemberships.every((value) => value);
    return MenuAnchor(
      consumeOutsideTap: true,
      menuChildren: _playlistMenuItems(audio, isAddingThisAudio),
      builder: (context, controller, _) {
        return IconButton(
          tooltip: isAddingThisAudio
              ? '添加中'
              : alreadyInAllPlaylists
              ? '已存在于所有歌单'
              : '添加到歌单',
          onPressed: canOpenPlaylistMenu
              ? () => _toggleMenu(controller)
              : null,
          icon: _playlistMenuIcon(isAddingThisAudio, alreadyInAllPlaylists),
        );
      },
    );
  }

  List<Widget> _playlistMenuItems(Audio audio, bool isAddingThisAudio) {
    return List.generate(playlists.length, (playlistIndex) {
      final playlist = playlists[playlistIndex];
      final isAddingTarget =
          isAddingThisAudio && identical(_addingTargetPlaylist, playlist);
      final alreadyInPlaylist = playlist.containsPath(audio.path);
      return MenuItemButton(
        onPressed: _addingAudioToPlaylist == null && !alreadyInPlaylist
            ? () => _addSearchResultToPlaylist(audio, playlist)
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
    });
  }

  @override
  Widget build(BuildContext context) {
    return SearchDialogFrame(
      title: const Text('搜索'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _searchField(Theme.of(context).colorScheme),
          _searchingIndicator(),
          Expanded(child: _resultBody()),
        ],
      ),
    );
  }

  Widget _searchField(ColorScheme scheme) {
    return Focus(
      onFocusChange: HotkeysHelper.onFocusChanges,
      child: TextField(
        controller: _searchController,
        autofocus: true,
        style: TextStyle(color: scheme.onSurface),
        decoration: InputDecoration(
          prefixIcon: const Icon(Symbols.search),
          hintText: '搜索歌曲、艺术家、专辑',
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _searchController,
            builder: (context, value, _) {
              if (!canShowSearchClearAction(value.text)) {
                return const SizedBox.shrink();
              }
              return IconButton(
                tooltip: '清除',
                onPressed: () {
                  _debounce?.cancel();
                  _searchController.clear();
                  _result.value = UnionSearchResult('');
                  _stopLibraryReadyWait();
                  _persistDebounce?.cancel();
                  _persistLastQuery('');
                },
                icon: const Icon(Symbols.close),
              );
            },
          ),
        ),
        onChanged: _onQueryChanged,
        onSubmitted: (_) {},
      ),
    );
  }

  Widget _searchingIndicator() {
    return ValueListenableBuilder(
      valueListenable: _isSearching,
      builder: (context, searching, _) => AnimatedSwitcher(
        duration: MotionDuration.xFast,
        switchInCurve: MotionCurve.standard,
        switchOutCurve: MotionCurve.standard,
        child: searching
            ? const Padding(
                padding: EdgeInsets.only(top: 8.0),
                child: LinearProgressIndicator(minHeight: 2.0),
              )
            : const SizedBox(height: 12.0),
      ),
    );
  }


  Widget _resultBody() {
    return ValueListenableBuilder<bool>(
      valueListenable: _awaitingLibraryReady,
      builder: (context, awaitingLibrary, _) {
        return ValueListenableBuilder<UnionSearchResult>(
          valueListenable: _result,
          builder: (context, value, _) {
            final query = value.query.trim();
            if (query.isEmpty) {
              return const _SearchEmptyState(
                icon: Symbols.search,
                title: '输入关键词开始搜索',
                message: '支持搜索歌曲、艺术家、专辑。',
              );
            }
            final items = value.mixedItems;
            if (items.isEmpty) {
              if (awaitingLibrary) {
                return const _SearchEmptyState(
                  icon: Symbols.library_music,
                  title: '曲库加载中',
                  message: '正在等待曲库就绪，将自动重新搜索上次关键词。',
                );
              }
              return const _SearchEmptyState(
                icon: Symbols.search,
                title: '没有找到相关内容',
                message: '换个关键词，或检查曲库是否已收录。',
              );
            }
            return CustomScrollView(
              slivers: [
                SliverList.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) => _mixedTile(value, items[i]),
                ),
                const SliverPadding(padding: EdgeInsets.only(bottom: 12.0)),
              ],
            );
          },
        );
      },
    );
  }

  Widget _mixedTile(UnionSearchResult value, UnionSearchItem item) {
    switch (item.kind) {
      case UnionSearchItemKind.music:
        {
          final audio = item.audio;
          if (audio == null) return const SizedBox.shrink();
          return AudioTile(
            key: ValueKey('music_${audio.path}'),
            audioIndex: item.audioIndex,
            playlist: value.audios,
            action: _musicActionBar(audio),
          );
        }
      case UnionSearchItemKind.artist:
        {
          final artist = item.artist;
          if (artist == null) return const SizedBox.shrink();
          return ArtistTile(
            key: ValueKey('artist_${artist.name}'),
            artist: artist,
          );
        }
      case UnionSearchItemKind.album:
        {
          final album = item.album;
          if (album == null) return const SizedBox.shrink();
          return AlbumTile(
            key: ValueKey('album_${album.name}'),
            album: album,
          );
        }
    }
  }
}
