/// 更新下载线路：决定安装包、便携包与 version.json 的候选地址顺序。
///
/// 本文件只生成地址并聚合失败，不发起网络请求，便于单元测试。
enum UpdateDownloadRoute {
  auto,
  github,
  gitee,
  proxy;

  static UpdateDownloadRoute parse(Object? value) => switch (value) {
    'github' => UpdateDownloadRoute.github,
    'gitee' => UpdateDownloadRoute.gitee,
    'proxy' => UpdateDownloadRoute.proxy,
    _ => UpdateDownloadRoute.auto,
  };

  String get label => switch (this) {
    UpdateDownloadRoute.auto => '自动',
    UpdateDownloadRoute.github => 'GitHub 直连',
    UpdateDownloadRoute.gitee => 'Gitee',
    UpdateDownloadRoute.proxy => '加速代理',
  };

  String get description => switch (this) {
    UpdateDownloadRoute.auto => '自动：优先直连，失败时依次尝试 Gitee 与加速代理',
    UpdateDownloadRoute.github => '仅从 GitHub 直连下载，失败即停止',
    UpdateDownloadRoute.gitee => '仅从 Gitee 镜像下载',
    UpdateDownloadRoute.proxy => '仅经加速代理下载，不直连 GitHub 或 Gitee',
  };
}

/// 内置加速代理前缀；代理地址按「前缀 + 原始 GitHub URL」拼接。
const defaultUpdateProxyPrefixes = <String>[
  'https://ghfast.top/',
  'https://gh-proxy.com/',
  'https://ghproxy.net/',
];

enum UpdateDownloadSource { direct, gitee, proxy, custom }

class UpdateDownloadCandidate {
  const UpdateDownloadCandidate({
    required this.source,
    required this.label,
    required this.url,
    this.proxyPrefix,
  });

  final UpdateDownloadSource source;
  final String label;
  final String url;
  final String? proxyPrefix;

  bool get isDirect => source == UpdateDownloadSource.direct;

  String get host => Uri.tryParse(url)?.host ?? '';
}

/// 按线路生成候选地址；同一地址只保留第一次出现的位置。
List<UpdateDownloadCandidate> updateDownloadCandidates({
  required UpdateDownloadRoute route,
  required String? directUrl,
  required String? giteeUrl,
  List<String> extraUrls = const [],
  List<String> proxyPrefixes = defaultUpdateProxyPrefixes,
}) {
  final direct = _trimmed(directUrl);
  final gitee = _trimmed(giteeUrl);
  final extras = _customCandidates(extraUrls);
  final proxies = <UpdateDownloadCandidate>[
    for (final prefix in proxyPrefixes)
      if (direct != null)
        UpdateDownloadCandidate(
          source: UpdateDownloadSource.proxy,
          label: _proxyLabel(prefix),
          url: _proxyUrl(prefix, direct),
          proxyPrefix: prefix,
        ),
  ];

  final ordered = switch (route) {
    UpdateDownloadRoute.auto => [
      if (direct != null) _directCandidate(direct),
      ...extras,
      if (gitee != null) _giteeCandidate(gitee),
      ...proxies,
    ],
    UpdateDownloadRoute.github => [
      if (direct != null) _directCandidate(direct),
    ],
    UpdateDownloadRoute.gitee => [if (gitee != null) _giteeCandidate(gitee)],
    UpdateDownloadRoute.proxy => [...proxies],
  };

  return _dedupeCandidates(ordered);
}

/// version.json 只从官方源读取：GitHub 直连与 Gitee 镜像。
///
/// 第三方下载代理能改写返回内容，清单一经代理即可自洽伪造校验值，
/// 因此元数据候选不包含任何代理前缀；[UpdateDownloadRoute.proxy] 也只
/// 从两个官方源读取清单，代理仅用于安装包传输。
List<UpdateDownloadCandidate> updateMetadataCandidates({
  required UpdateDownloadRoute route,
  required String? directUrl,
  required String? giteeUrl,
  List<String> extraUrls = const [],
}) {
  final direct = _trimmed(directUrl);
  final gitee = _trimmed(giteeUrl);
  final extras = _customCandidates(extraUrls)
      .where((candidate) => updateProxyInnerUri(candidate.url) == null)
      .toList();

  final ordered = switch (route) {
    UpdateDownloadRoute.auto => [
      if (direct != null) _directCandidate(direct),
      ...extras,
      if (gitee != null) _giteeCandidate(gitee),
    ],
    UpdateDownloadRoute.github => [
      if (direct != null) _directCandidate(direct),
    ],
    UpdateDownloadRoute.gitee => [if (gitee != null) _giteeCandidate(gitee)],
    UpdateDownloadRoute.proxy => [
      if (direct != null) _directCandidate(direct),
      if (gitee != null) _giteeCandidate(gitee),
    ],
  };

  return _dedupeCandidates(ordered);
}

List<UpdateDownloadCandidate> _customCandidates(List<String> urls) {
  final candidates = <UpdateDownloadCandidate>[];
  for (final url in urls) {
    final extra = _trimmed(url);
    if (extra == null) continue;
    candidates.add(
      UpdateDownloadCandidate(
        source: UpdateDownloadSource.custom,
        label: '自定义更新源',
        url: extra,
      ),
    );
  }
  return candidates;
}

List<UpdateDownloadCandidate> _dedupeCandidates(
  List<UpdateDownloadCandidate> candidates,
) {
  final seen = <String>{};
  return [
    for (final candidate in candidates)
      if (seen.add(candidate.url)) candidate,
  ];
}

UpdateDownloadCandidate _directCandidate(String url) => UpdateDownloadCandidate(
  source: UpdateDownloadSource.direct,
  label: 'GitHub 直连',
  url: url,
);

UpdateDownloadCandidate _giteeCandidate(String url) => UpdateDownloadCandidate(
  source: UpdateDownloadSource.gitee,
  label: 'Gitee 镜像',
  url: url,
);

String? _trimmed(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String _proxyUrl(String prefix, String url) {
  final base = prefix.endsWith('/') ? prefix : '$prefix/';
  return '$base$url';
}

/// 剥离代理前缀，返回其后的原始地址；只接受 https 内层地址。
///
/// 候选生成与地址校验共用同一前缀集合与拼接规则，避免两处判断不一致。
Uri? updateProxyInnerUri(
  String url, {
  List<String> proxyPrefixes = defaultUpdateProxyPrefixes,
}) {
  final trimmed = url.trim();
  for (final prefix in proxyPrefixes) {
    final base = prefix.endsWith('/') ? prefix : '$prefix/';
    if (!trimmed.startsWith(base)) continue;
    final inner = Uri.tryParse(trimmed.substring(base.length));
    if (inner != null && inner.scheme == 'https' && inner.host.isNotEmpty) {
      return inner;
    }
  }
  return null;
}

String _proxyLabel(String prefix) {
  final host = Uri.tryParse(prefix)?.host;
  return host == null || host.isEmpty ? '加速代理' : '加速代理 $host';
}

enum UpdateDownloadFailureReason {
  timeout,
  notFound,
  connection,
  server,
  checksum,
  disk,
  invalidUrl,
  empty,
  incomplete,
  cancelled,
  unknown,
}

/// 单条线路的失败原因；[cause] 保留原始异常用于取消等需要向上传递的场景。
class UpdateDownloadAttemptException implements Exception {
  const UpdateDownloadAttemptException(
    this.reason, {
    this.statusCode,
    this.cause,
  });

  final UpdateDownloadFailureReason reason;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() =>
      'UpdateDownloadAttemptException(${reason.name}, status=$statusCode)';
}

class UpdateDownloadAttemptFailure {
  const UpdateDownloadAttemptFailure({
    required this.candidate,
    required this.reason,
    this.statusCode,
  });

  final UpdateDownloadCandidate candidate;
  final UpdateDownloadFailureReason reason;
  final int? statusCode;

  String get detail => switch (reason) {
    UpdateDownloadFailureReason.timeout => '连接超时',
    UpdateDownloadFailureReason.notFound => '返回 404',
    UpdateDownloadFailureReason.connection => '无法连接',
    UpdateDownloadFailureReason.server =>
      '服务异常（HTTP ${statusCode ?? '未知'}）',
    UpdateDownloadFailureReason.checksum => 'SHA256 校验不通过',
    UpdateDownloadFailureReason.disk => '写入文件失败',
    UpdateDownloadFailureReason.invalidUrl => '下载地址不可信',
    UpdateDownloadFailureReason.empty => '下载文件为空',
    UpdateDownloadFailureReason.incomplete => '下载未完成',
    UpdateDownloadFailureReason.cancelled => '已取消',
    UpdateDownloadFailureReason.unknown => '下载失败',
  };
}

/// 汇总消息以直连失败为主因，并列出其余线路的原因。
String describeUpdateDownloadFailures(
  List<UpdateDownloadAttemptFailure> failures,
) {
  if (failures.isEmpty) return '下载失败，请稍后再试';
  final primary = failures.firstWhere(
    (failure) => failure.candidate.isDirect,
    orElse: () => failures.first,
  );
  final buffer = StringBuffer(
    '下载失败：${primary.candidate.label} ${primary.detail}',
  );
  final others = failures.where((failure) => !identical(failure, primary));
  final details = others
      .map((failure) => '${failure.candidate.label} ${failure.detail}')
      .join('、');
  if (details.isNotEmpty) buffer.write('；$details');
  buffer.write('（已尝试 ${failures.length} 条线路）');
  return buffer.toString();
}

class UpdateDownloadAggregateException implements Exception {
  const UpdateDownloadAggregateException(this.failures);

  final List<UpdateDownloadAttemptFailure> failures;

  String get message => describeUpdateDownloadFailures(failures);

  @override
  String toString() => message;
}

/// 依次尝试候选线路；只有 [UpdateDownloadAttemptException] 会触发回退，
/// 取消则直接抛出原始异常，其它异常由调用方包装。
Future<T> runUpdateDownloadAttempts<T>({
  required List<UpdateDownloadCandidate> candidates,
  required Future<T> Function(UpdateDownloadCandidate candidate) attempt,
  required void Function(UpdateDownloadAttemptFailure failure) onFailure,
}) async {
  final failures = <UpdateDownloadAttemptFailure>[];
  for (final candidate in candidates) {
    try {
      final result = await attempt(candidate);
      return result;
    } on UpdateDownloadAttemptException catch (error) {
      if (error.reason == UpdateDownloadFailureReason.cancelled) {
        final cause = error.cause;
        if (cause != null) {
          Error.throwWithStackTrace(cause, StackTrace.current);
        }
        rethrow;
      }
      final failure = UpdateDownloadAttemptFailure(
        candidate: candidate,
        reason: error.reason,
        statusCode: error.statusCode,
      );
      failures.add(failure);
      onFailure(failure);
    }
  }
  throw UpdateDownloadAggregateException(List.unmodifiable(failures));
}
