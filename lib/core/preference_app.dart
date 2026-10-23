part of 'preference.dart';

class AppPreference {
  static const defaultUpdateRepoSlug = 'Triangle-Wave/Pure-music';
  static const defaultUpdateCheckUrls = [
    'https://raw.githubusercontent.com/Triangle-Wave/Pure-music/main/update/version.json',
  ];

  /// 上游仓库发布的更新源，只用于识别老配置。
  static const legacyUpdateRepoSlug = 'qingyueyin/Pure-music';
  static const legacyUpdateCheckUrls = [
    'https://raw.githubusercontent.com/qingyueyin/Pure-music/main/update/version.json',
    'https://gitee.com/qingyueyin/Pure-music/raw/main/update/version.json',
  ];

  static const updateSourceMigratedKey = 'updateSourceMigrated';

  var audiosPagePref = PagePreference(0, SortOrder.ascending, ContentView.list);

  var artistsPagePref = PagePreference(
    0,
    SortOrder.ascending,
    ContentView.table,
  );

  var artistDetailPagePref = PagePreference(
    0,
    SortOrder.ascending,
    ContentView.list,
  );

  var albumsPagePref = PagePreference(
    0,
    SortOrder.ascending,
    ContentView.table,
  );

  var albumDetailPagePref = PagePreference(
    2,
    SortOrder.ascending,
    ContentView.list,
  );

  var foldersPagePref = PagePreference(
    0,
    SortOrder.ascending,
    ContentView.list,
  );

  var folderDetailPagePref = PagePreference(
    0,
    SortOrder.ascending,
    ContentView.list,
  );

  var playlistsPagePref = PagePreference(
    0,
    SortOrder.ascending,
    ContentView.list,
  );

  var playlistDetailPagePref = PagePreference(
    0,
    SortOrder.ascending,
    ContentView.list,
  );

  int startPage = 0;

  bool sidebarExpanded = true;

  bool taskbarPlaybackControls = true;
  bool taskbarCoverPreview = false;
  double taskbarCoverScale = 1.0;

  var playbackPref = PlaybackPreference(
    PlayMode.forward,
    1.0,
    List.filled(10, 0.0),
    [],
  );

  var nowPlayingPagePref = NowPlayingPagePreference(
    NowPlayingViewMode.withLyric,
    LyricTextAlign.left,
    22.0,
    18.0,
    true,
    400,
    false,
  );

  String customCpFeedbackKey = '';
  String updateRepoSlug = defaultUpdateRepoSlug;
  String? updateChannel;
  bool autoCheckUpdate = true;
  String? lastUpdateCheckTime;
  String? lastSeenUpdateTag;
  List<String> updateCheckUrls = List.of(defaultUpdateCheckUrls);

  /// 更新源迁移是否已写回配置文件；读取到旧配置时按存储值重新判定。
  bool updateSourceMigrated = true;
  bool _updateSourceMigrationPending = false;

  /// 用户手动添加的文件夹路径列表（不包括自动发现的子文件夹）
  List<String> userFolders = [];

  List<String> excludedFolderPaths = [];

  /// 用户为曲库根文件夹设置的自定义别名，key 为 pendingFolderKey 规范化路径
  Map<String, String> folderAliases = {};

  /// 保存失败时把 aliases 恢复为快照 old；saved 为 true 时什么都不做。
  /// 独立成纯函数，便于单测覆盖「保存失败回滚」路径。
  static void restoreFolderAliasesOnSaveFailure(
    Map<String, String> current,
    Map<String, String> old,
    bool saved,
  ) {
    if (saved) return;
    current
      ..clear()
      ..addAll(old);
  }

  /// 上次读取的原始 JSON，保存时保留未知字段
  Map<String, dynamic>? _rawPrefMap;

  void applyStoredMap(Map<String, dynamic> prefMap) {
    _rawPrefMap = prefMap;
    _applyPagePrefs(prefMap);
    _applyChromePrefs(prefMap);
    _applyNowPlayingPrefs(prefMap);
    _applyUpdatePrefs(prefMap);
    _applyFolderPrefs(prefMap);
  }

  void _applyPagePrefs(Map<String, dynamic> prefMap) {
    audiosPagePref = PagePreference.fromMap(prefMap['audiosPagePref']);
    artistsPagePref = PagePreference.fromMap(prefMap['artistsPagePref']);
    artistDetailPagePref = PagePreference.fromMap(
      prefMap['artistDetailPagePref'],
    );
    albumsPagePref = PagePreference.fromMap(prefMap['albumsPagePref']);
    albumDetailPagePref = PagePreference.fromMap(
      prefMap['albumDetailPagePref'],
    );
    foldersPagePref = PagePreference.fromMap(prefMap['foldersPagePref']);
    folderDetailPagePref = PagePreference.fromMap(
      prefMap['folderDetailPagePref'],
    );
    playlistsPagePref = PagePreference.fromMap(prefMap['playlistsPagePref']);
    playlistDetailPagePref = PagePreference.fromMap(
      prefMap['playlistDetailPagePref'],
    );
  }

  void _applyChromePrefs(Map<String, dynamic> prefMap) {
    startPage = _normalizedBoundedInt(
      prefMap['startPage'],
      defaultValue: 0,
      min: 0,
      max: app_paths.START_PAGES.length - 1,
    );
    sidebarExpanded = _normalizedBool(
      prefMap['sidebarExpanded'],
      defaultValue: true,
    );
    taskbarPlaybackControls = _normalizedBool(
      prefMap.containsKey('taskbarPlaybackControls')
          ? prefMap['taskbarPlaybackControls']
          : prefMap['taskbarThumbnailCover'],
      defaultValue: true,
    );
    taskbarCoverPreview = _normalizedBool(
      prefMap['taskbarCoverPreview'],
      defaultValue: false,
    );
    taskbarCoverScale = _normalizedBoundedDouble(
      prefMap['taskbarCoverScale'],
      defaultValue: 1.0,
      min: 0.5,
      max: 2.0,
    );
  }

  void _applyNowPlayingPrefs(Map<String, dynamic> prefMap) {
    playbackPref = PlaybackPreference.fromMap(prefMap['playbackPref']);
    nowPlayingPagePref = NowPlayingPagePreference.fromMap(
      prefMap['nowPlayingPagePref'],
    );
    _nowPlayingBackgroundModeNotifier?.value =
        nowPlayingPagePref.backgroundMode;
    _nowPlayingDynamicFlowingLightNotifier?.value =
        nowPlayingPagePref.dynamicFlowingLight;
    _nowPlayingAudioReactiveFlowNotifier?.value =
        nowPlayingPagePref.audioReactiveFlow;
  }

  static bool isLegacyUpdateRepoSlug(String slug) =>
      slug.trim().toLowerCase() == legacyUpdateRepoSlug.toLowerCase();

  static bool isLegacyUpdateCheckUrl(String url) {
    final key = _updateUrlKey(url).toLowerCase();
    return legacyUpdateCheckUrls.any(
      (legacy) => _updateUrlKey(legacy).toLowerCase() == key,
    );
  }

  /// 只替换上游默认值，用户自定义的仓库 slug 原样保留。
  static String migrateUpdateRepoSlug(String stored) {
    final normalized = stored.trim();
    if (normalized.isEmpty) return defaultUpdateRepoSlug;
    return isLegacyUpdateRepoSlug(normalized)
        ? defaultUpdateRepoSlug
        : normalized;
  }

  /// 逐条替换上游默认 URL，用户自定义的地址保留并参与去重。
  static List<String> migrateUpdateCheckUrls(Iterable<String> stored) {
    final result = <String>[];
    final seen = <String>{};
    for (final url in stored) {
      final migrated = isLegacyUpdateCheckUrl(url)
          ? defaultUpdateCheckUrls.first
          : url;
      if (seen.add(_updateUrlKey(migrated))) result.add(migrated);
    }
    if (result.isEmpty) result.addAll(defaultUpdateCheckUrls);
    return result;
  }

  /// Gitee 渠道已下线，历史选择回到 GitHub。
  static String? migrateUpdateChannel(String? stored) {
    if (stored == null) return null;
    return stored.trim().toLowerCase() == 'gitee' ? 'github' : stored;
  }

  void _applyUpdatePrefs(Map<String, dynamic> prefMap) {
    customCpFeedbackKey = _normalizedString(prefMap['customCpFeedbackKey']);
    final storedRepoSlug = _normalizedNonEmptyString(
      prefMap['updateRepoSlug'],
      defaultValue: defaultUpdateRepoSlug,
    );
    final storedChannel = _normalizedNullableString(prefMap['updateChannel']);
    final storedUpdateUrls = _normalizedUpdateCheckUrls(
      prefMap['updateCheckUrls'],
    );
    final alreadyMigrated = _normalizedBool(
      prefMap[updateSourceMigratedKey],
      defaultValue: false,
    );
    if (alreadyMigrated) {
      updateRepoSlug = storedRepoSlug;
      updateChannel = storedChannel;
      updateCheckUrls = storedUpdateUrls.isEmpty
          ? List.of(defaultUpdateCheckUrls)
          : storedUpdateUrls;
      updateSourceMigrated = true;
    } else {
      updateRepoSlug = migrateUpdateRepoSlug(storedRepoSlug);
      updateChannel = migrateUpdateChannel(storedChannel);
      updateCheckUrls = migrateUpdateCheckUrls(
        storedUpdateUrls.isEmpty ? defaultUpdateCheckUrls : storedUpdateUrls,
      );
      updateSourceMigrated = true;
      _updateSourceMigrationPending = true;
    }
    autoCheckUpdate = _normalizedBool(
      prefMap['autoCheckUpdate'],
      defaultValue: true,
    );
    lastUpdateCheckTime = _normalizedNullableString(
      prefMap['lastUpdateCheckTime'],
    );
    lastSeenUpdateTag = _normalizedNullableString(prefMap['lastSeenUpdateTag']);
  }

  void _applyFolderPrefs(Map<String, dynamic> prefMap) {
    userFolders = _normalizedFolderPathList(prefMap['userFolders']);
    excludedFolderPaths = _normalizedFolderPathList(
      prefMap['excludedFolderPaths'],
    );
    folderAliases = _folderAliasesFromStoredValue(prefMap['folderAliases']);
  }

  /// 读取到需要迁移的老配置时返回 true 并清标记，调用方应立即保存。
  bool consumeUpdateSourceMigration() {
    if (!_updateSourceMigrationPending) return false;
    _updateSourceMigrationPending = false;
    return true;
  }

  Future<bool> save() async {
    try {
      final settingsDir = await getSettingsDir();
      final appPreferencePath = path.join(
        settingsDir.path,
        'app_preference.json',
      );

      final prefMap = _rawPrefMap != null
          ? Map<String, dynamic>.from(_rawPrefMap!)
          : <String, dynamic>{};
      prefMap.remove('taskbarThumbnailCover');
      prefMap['version'] = AppSettings.version;
      prefMap.addAll({
        'audiosPagePref': audiosPagePref.toMap(),
        'artistsPagePref': artistsPagePref.toMap(),
        'artistDetailPagePref': artistDetailPagePref.toMap(),
        'albumsPagePref': albumsPagePref.toMap(),
        'albumDetailPagePref': albumDetailPagePref.toMap(),
        'foldersPagePref': foldersPagePref.toMap(),
        'folderDetailPagePref': folderDetailPagePref.toMap(),
        'playlistsPagePref': playlistsPagePref.toMap(),
        'playlistDetailPagePref': playlistDetailPagePref.toMap(),
        'startPage': startPage,
        'sidebarExpanded': sidebarExpanded,
        'taskbarPlaybackControls': taskbarPlaybackControls,
        'taskbarCoverPreview': taskbarCoverPreview,
        'taskbarCoverScale': taskbarCoverScale,
        'playbackPref': playbackPref.toMap(),
        'nowPlayingPagePref': nowPlayingPagePref.toMap(),
        'customCpFeedbackKey': customCpFeedbackKey,
        'updateRepoSlug': updateRepoSlug,
        'updateChannel': updateChannel,
        'autoCheckUpdate': autoCheckUpdate,
        'lastUpdateCheckTime': lastUpdateCheckTime,
        'lastSeenUpdateTag': lastSeenUpdateTag,
        'updateCheckUrls': updateCheckUrls,
        updateSourceMigratedKey: updateSourceMigrated,
        'userFolders': userFolders,
        'excludedFolderPaths': excludedFolderPaths,
        'folderAliases': folderAliases,
      });

      final prefJson = json.encode(prefMap);
      await writeTextFileAtomically(appPreferencePath, prefJson);
      return true;
    } catch (err, trace) {
      log.settings.error('legacy', err.toString(), stackTrace: trace);
      return false;
    }
  }

  Future<bool> savePlaybackOnly() async {
    try {
      final settingsDir = await getSettingsDir();
      final playbackPrefPath = path.join(
        settingsDir.path,
        'playback_pref.json',
      );

      final prefJson = json.encode(playbackPref.toMap());
      await writeTextFileAtomically(playbackPrefPath, prefJson);
      return true;
    } catch (err, trace) {
      log.settings.error('legacy', err.toString(), stackTrace: trace);
      return false;
    }
  }

  Future<void> loadPlaybackOnly() async {
    try {
      final settingsDir = await getSettingsDir();
      final playbackPrefPath = path.join(
        settingsDir.path,
        'playback_pref.json',
      );

      if (File(playbackPrefPath).existsSync()) {
        final prefJson = await File(playbackPrefPath).readAsString();
        final prefMap = json.decode(prefJson);
        instance.playbackPref = PlaybackPreference.fromMap(prefMap);
      }
    } catch (err, trace) {
      log.settings.error('legacy', err.toString(), stackTrace: trace);
    }
  }

  static Future<void> read() async {
    try {
      final settingsDir = await getSettingsDir();
      final appPreferencePath = path.join(
        settingsDir.path,
        'app_preference.json',
      );

      final prefJson = await File(appPreferencePath).readAsString();
      final Map<String, dynamic> prefMap = json.decode(prefJson);
      instance.applyStoredMap(prefMap);
      if (instance.consumeUpdateSourceMigration()) {
        await instance.save();
      }
      // 用独立保存的 playback_pref.json 覆盖最新播放状态
      // （_persistLastSession 写入的是 playback_pref.json 而非 app_preference.json）
      await instance.loadPlaybackOnly();

      if (instance.userFolders.isEmpty) {
        log.settings.info(
          'legacy',
          'userFolders is empty, will be set after first folder scan',
        );
      }
    } catch (err, trace) {
      log.settings.error('legacy', err.toString(), stackTrace: trace);
    }
  }

  static final AppPreference instance = AppPreference();
}
