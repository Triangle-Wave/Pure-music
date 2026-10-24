import 'dart:async';
import 'dart:io';

import 'package:pure_music/component/index_progress_view.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:pure_music/core/utils.dart';
import 'package:flutter/material.dart';

typedef IndexBuilder =
    Stream<IndexActionState> Function({
      required List<String> folders,
      required String indexPath,
    });

class BuildIndexStateView extends StatefulWidget {
  const BuildIndexStateView({
    super.key,
    required this.indexPath,
    required this.folders,
    required this.whenIndexBuilt,
    this.buildIndex = buildIndexFromFoldersRecursively,
  });

  final Directory indexPath;
  final List<String> folders;
  final FutureOr<void> Function() whenIndexBuilt;
  final IndexBuilder buildIndex;

  @override
  State<BuildIndexStateView> createState() => _BuildIndexStateViewState();
}

class _BuildIndexStateViewState extends State<BuildIndexStateView> {
  Stream<IndexActionState>? _buildIndexStream;
  bool _done = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _startBuild();
  }

  void _startBuild() {
    final stream = widget.buildIndex(
      folders: widget.folders,
      indexPath: widget.indexPath.path,
    );
    void apply() {
      _done = false;
      _errorMessage = null;
      _buildIndexStream = stream;
    }

    if (mounted && _buildIndexStream != null) {
      setState(apply);
    } else {
      apply();
    }
  }

  Future<void> _completeBuild() async {
    try {
      await widget.whenIndexBuilt();
    } catch (error, stackTrace) {
      log.app.error(
        'legacy',
        '曲库索引完成后的加载失败',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _errorMessage = '曲库加载失败，请查看日志');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: _buildIndexStream,
      builder: (context, snapshot) => _buildSnapshot(snapshot),
    );
  }

  Widget _buildSnapshot(AsyncSnapshot<IndexActionState> snapshot) {
    if (snapshot.hasError) {
      return IndexProgressView(
        errorMessage: '曲库索引构建失败，请查看日志',
        onRetry: _startBuild,
      );
    }
    final errorMessage = _errorMessage;
    if (errorMessage != null) {
      return IndexProgressView(
        errorMessage: errorMessage,
        onRetry: _startBuild,
      );
    }
    if (snapshot.hasData) {
      log.app.info(
        'legacy',
        '[build index] ${snapshot.data!.progress}: ${snapshot.data!.message}',
      );
    }
    if (!_done && snapshot.connectionState == ConnectionState.done) {
      _done = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_completeBuild());
      });
    }
    // 阶段文案、不可读计数与完成态统一走共享扫描视图；
    return IndexProgressView(state: snapshot.hasData ? snapshot.data : null);
  }
}
