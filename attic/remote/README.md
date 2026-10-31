# 归档：远程曲库

远程曲库（Navidrome / WebDAV / SMB 来源的同步与播放）的完整实现。目录内代码保留备查，不参与构建与分析。

- `attic/**` 在 `analysis_options.yaml` 中排除，`flutter analyze` 与构建都不涉及。
- 恢复步骤：`attic/remote/*.dart` 移回 `lib/remote/`，`page/` 下两个文件移回 `lib/page/`，并删除 `analysis_options.yaml` 中的 `attic/**` 排除项。
- 入口与分支同步恢复：`lib/core/paths.dart` 的 `REMOTE_PAGE`、`lib/component/side_nav.dart` 的侧栏入口、`lib/entry.dart` 的路由分支、`lib/main.dart` 的 `RemoteLibrary.instance.init()`，以及播放、封面、详情、统计中的远程分支。
- Rust 侧 SMB 远程索引入口与生成的 Dart 绑定（`buildRemoteIndexFromFoldersRecursively`）保持不变，恢复时无需重跑 codegen。
- 用户已有的远程来源数据保留在曲库数据库中，恢复后可直接使用。
