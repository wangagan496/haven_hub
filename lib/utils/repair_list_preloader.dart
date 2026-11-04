import '../models/repair.dart';
import 'app_exception.dart';
import 'token_manager.dart';

/// 首页提前加载一次，报修页首次打开时取走结果；后续刷新仍请求接口。
class RepairPreloader<T> {
  RepairPreloader({
    required this.loader,
    TokenManager? tokens,
    DateTime Function()? now,
    this.maxAge = const Duration(seconds: 30),
  })  : _tokens = tokens ?? tokenManager,
        _now = now ?? DateTime.now;

  final Future<T> Function() loader;
  final TokenManager _tokens;
  final DateTime Function() _now;
  final Duration maxAge;
  Future<T>? _preloaded;
  DateTime? _completedAt;
  int? _sessionId;

  void invalidate() {
    _preloaded = null;
    _completedAt = null;
    _sessionId = null;
  }

  void _checkSession() {
    if (_tokens.getToken().isEmpty || _sessionId != _tokens.sessionId) {
      invalidate();
    }
  }

  Future<void> preload() async {
    _checkSession();
    if (_tokens.getToken().isEmpty || _preloaded != null) return;

    final int sessionId = _tokens.sessionId;
    _sessionId = sessionId;
    late final Future<T> request;
    request = Future<T>.sync(loader).then((records) {
      if (_tokens.sessionId != sessionId || _tokens.getToken().isEmpty) {
        throw const SessionChangedException();
      }
      if (identical(_preloaded, request)) _completedAt = _now();
      return records;
    });
    _preloaded = request;
    try {
      await request;
    } on Object {
      // 预加载失败不打扰首页；报修页进入后按原有逻辑加载和提示。
      if (identical(_preloaded, request)) invalidate();
    }
  }

  Future<T> load() {
    _checkSession();
    final Future<T>? preloaded = _preloaded;
    final DateTime? completedAt = _completedAt;
    final bool fresh =
        completedAt == null || _now().difference(completedAt) < maxAge;
    // 只消费一次：下拉刷新、重试及提交后刷新不会反复拿到旧记录。
    invalidate();
    return preloaded != null && fresh ? preloaded : loader();
  }
}

/// 保留完整列表预加载的既有调用约定；分页入口使用同一套过期/会话逻辑。
class RepairListPreloader extends RepairPreloader<List<RepairRecord>> {
  RepairListPreloader({
    required Future<List<RepairRecord>> Function() loader,
    super.tokens,
    super.now,
    super.maxAge,
  }) : super(loader: () async => List<RepairRecord>.unmodifiable(await loader()));
}
