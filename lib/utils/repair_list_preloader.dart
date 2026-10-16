import '../models/repair.dart';
import 'app_exception.dart';
import 'token_manager.dart';

/// 首页提前加载一次，报修页首次打开时取走结果；后续刷新仍请求接口。
class RepairListPreloader {
  RepairListPreloader({
    required this.loader,
    TokenManager? tokens,
    DateTime Function()? now,
    this.maxAge = const Duration(seconds: 30),
  })  : _tokens = tokens ?? tokenManager,
        _now = now ?? DateTime.now;

  final Future<List<RepairRecord>> Function() loader;
  final TokenManager _tokens;
  final DateTime Function() _now;
  final Duration maxAge;
  Future<List<RepairRecord>>? _preloaded;
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
    late final Future<List<RepairRecord>> request;
    request = Future<List<RepairRecord>>.sync(loader).then((records) {
      if (_tokens.sessionId != sessionId || _tokens.getToken().isEmpty) {
        throw const SessionChangedException();
      }
      if (identical(_preloaded, request)) _completedAt = _now();
      return List<RepairRecord>.unmodifiable(records);
    });
    _preloaded = request;
    try {
      await request;
    } on Object {
      // 预加载失败不打扰首页；报修页进入后按原有逻辑加载和提示。
      if (identical(_preloaded, request)) invalidate();
    }
  }

  Future<List<RepairRecord>> load() {
    _checkSession();
    final Future<List<RepairRecord>>? preloaded = _preloaded;
    final DateTime? completedAt = _completedAt;
    final bool fresh =
        completedAt == null || _now().difference(completedAt) < maxAge;
    // 只消费一次：下拉刷新、重试及提交后刷新不会反复拿到旧记录。
    invalidate();
    return preloaded != null && fresh ? preloaded : loader();
  }
}
