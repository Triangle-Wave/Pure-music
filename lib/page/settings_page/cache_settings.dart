import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/cache_paths.dart';
import 'package:pure_music/core/cover_disk_cache.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/services/online_album/online_album_service.dart';
import 'package:pure_music/services/online_album/online_artist_image_service.dart';
import 'package:pure_music/services/online_lyric/lyric_candidate_cache.dart';

/// 缓存位置与缓存清理设置。
class CacheDirectorySettingsPanel extends StatefulWidget {
  const CacheDirectorySettingsPanel({super.key});

  @override
  State<CacheDirectorySettingsPanel> createState() =>
      _CacheDirectorySettingsPanelState();
}

class _CacheDirectorySettingsPanelState
    extends State<CacheDirectorySettingsPanel> {
  String _cachePath = '读取中…';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPath());
  }

  Future<void> _loadPath() async {
    try {
      final directory = await getCacheRoot();
      if (!mounted) return;
      setState(() => _cachePath = directory.path);
    } catch (error, trace) {
      log.settings.warn(
        'legacy',
        '读取缓存目录失败',
        error: error,
        stackTrace: trace,
      );
      if (!mounted) return;
      setState(() => _cachePath = '缓存目录不可用');
    }
  }

  Future<void> _pickDirectory() async {
    if (_busy) return;
    try {
      final selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择缓存目录',
      );
      if (selected == null || selected.trim().isEmpty) return;
      await _applyDirectory(p.normalize(selected.trim()));
    } catch (error, trace) {
      log.settings.warn(
        'legacy',
        '选择缓存目录失败',
        error: error,
        stackTrace: trace,
      );
      if (mounted) {
        showTextOnSnackBar('选择缓存目录失败，请查看日志', variant: ToastVariant.error);
      }
    }
  }

  Future<void> _applyDirectory(String path) async {
    if (_busy) return;
    final problem = await validateCacheDirectory(path);
    if (!mounted) return;
    if (problem != null) {
      showTextOnSnackBar(problem, variant: ToastVariant.error);
      return;
    }
    await _saveAndRefresh(path, defaultPosition: false);
  }

  Future<void> _useDefaultDirectory() {
    return _saveAndRefresh('', defaultPosition: true);
  }

  Future<void> _saveAndRefresh(
    String path, {
    required bool defaultPosition,
  }) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    final settings = AppSettings.instance;
    final previous = settings.cacheDirectory;
    settings.cacheDirectory = path;
    final saved = await settings.saveSettings();
    if (!mounted) return;
    if (!saved) {
      settings.cacheDirectory = previous;
      setState(() => _busy = false);
      showTextOnSnackBar('设置保存失败', variant: ToastVariant.error);
      return;
    }
    try {
      resetCacheRoot();
      CoverDiskCache.instance.invalidateRoot();
      OnlineAlbumService.instance.invalidateCacheRoot();
      OnlineArtistImageService.instance.invalidateCacheRoot();
      await ensureCacheDirectories();
      final directory = await getCacheRoot();
      if (!mounted) return;
      setState(() {
        _cachePath = directory.path;
        _busy = false;
      });
      showTextOnSnackBar(
        defaultPosition
            ? '已恢复默认缓存位置，原位置的缓存保留，可手动删除'
            : '缓存位置已切换，旧缓存保留在原位置，可手动删除',
        variant: ToastVariant.success,
      );
    } catch (error, trace) {
      log.settings.warn(
        'legacy',
        '切换缓存目录失败',
        error: error,
        stackTrace: trace,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      showTextOnSnackBar('缓存目录切换失败，请查看日志', variant: ToastVariant.error);
    }
  }

  Future<void> _openDirectory() async {
    final opened = await openCacheDirectory();
    if (!mounted) return;
    showTextOnSnackBar(
      opened ? '已打开缓存目录' : '缓存目录打开失败',
      variant: opened ? ToastVariant.success : ToastVariant.error,
    );
  }

  Future<void> _clearCache() async {
    if (_busy) return;
    final confirmed = await showDangerConfirmDialog(
      context: context,
      title: '清理缓存',
      message: '将删除封面、歌词候选、在线信息、AMLL 索引与 SACD 提取文件。'
          '设置、数据库与日志不受影响。正在播放的 SACD 缓存可能无法删除。',
      confirmLabel: '清理',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final report = await clearCache();
      await LyricCandidateCache.instance.clearAll();
      PlayService.instance.lyricService.forgetCachedCandidates();
      await OnlineAlbumService.instance.clearCache();
      await OnlineArtistImageService.instance.clearCache();
      CoverDiskCache.instance.invalidateRoot();
      if (!mounted) return;
      setState(() => _busy = false);
      final released = _formatBytes(report.bytes);
      final suffix = report.failed > 0
          ? '，${report.failed} 个文件被占用未删除'
          : '';
      showTextOnSnackBar(
        '已清理 ${report.files} 个缓存文件，释放 $released$suffix',
        variant: report.failed > 0 ? ToastVariant.info : ToastVariant.success,
      );
    } catch (error, trace) {
      log.settings.warn(
        'legacy',
        '清理缓存失败',
        error: error,
        stackTrace: trace,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      showTextOnSnackBar('清理缓存失败，请查看日志', variant: ToastVariant.error);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SettingsTile(
          description: '缓存位置',
          subtitle: _cachePath,
          action: Wrap(
            spacing: 4.0,
            runSpacing: 8.0,
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _openDirectory,
                icon: const Icon(Symbols.folder_open),
                label: const Text('打开'),
              ),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _pickDirectory,
                icon: const Icon(Symbols.folder),
                label: const Text('选择目录'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: '恢复默认位置',
          subtitle: '回到数据根下的 cache 目录；原位置缓存保留',
          action: TextButton(
            onPressed: _busy ? null : _useDefaultDirectory,
            child: const Text('恢复'),
          ),
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: '清理缓存',
          subtitle: '封面、歌词候选、在线信息、AMLL 索引与 SACD 提取缓存',
          action: FilledButton.tonalIcon(
            onPressed: _busy ? null : _clearCache,
            icon: const Icon(Symbols.delete_sweep),
            label: Text(_busy ? '处理中' : '清理'),
          ),
        ),
      ],
    );
  }
}
