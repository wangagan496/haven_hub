import 'app_exception.dart';
import 'token_manager.dart';

/// 暂存写接口返回的完整列表，交给返回后的列表页消费一次。
/// 不把普通分页结果当完整列表，也不让旧账号或迟到的读取覆盖新结果。
class MutationList<T> {
  MutationList(this.parse, {TokenManager? tokens, DateTime Function()? now})
      : _tokens = tokens ?? tokenManager,
        _now = now ?? DateTime.now;

  final T Function(Map<String, dynamic>) parse;
  final TokenManager _tokens;
  final DateTime Function() _now;
  List<T>? _rows;
  DateTime? _savedAt;
  int? _sessionId;
  int _revision = 0;
  int _activeWrites = 0;
  bool _overlapping = false;

  List<T>? get pending {
    if (_sessionId != _tokens.sessionId ||
        _tokens.getToken().isEmpty ||
        _savedAt == null ||
        _now().difference(_savedAt!) >= const Duration(seconds: 30)) {
      _rows = null;
    }
    return _rows;
  }

  Future<void> write(Future<dynamic> Function() operation) async {
    final int session = _tokens.sessionId;
    _rows = null;
    _revision++;
    _activeWrites++;
    if (_activeWrites > 1) _overlapping = true;
    try {
      final dynamic data = await operation();
      if (session != _tokens.sessionId) {
        throw const SessionChangedException();
      }
      // 并发写的响应顺序不代表提交顺序，无法确定时让列表重新查询。
      if (!_overlapping && _tokens.getToken().isNotEmpty) {
        _rows = _decode(data);
        _sessionId = session;
        _savedAt = _now();
      }
    } finally {
      _revision++;
      _activeWrites--;
      if (_activeWrites == 0) _overlapping = false;
    }
  }

  List<T>? _decode(dynamic data) {
    // 响应不符合完整列表契约时，保留原先重新查询的行为。
    if (data is! Map || data['complete'] != true || data['rows'] is! List) {
      return null;
    }
    try {
      final List<dynamic> rows = data['rows'] as List<dynamic>;
      if (data['total'] is! int || data['total'] != rows.length) return null;
      final Set<String> ids = <String>{};
      final List<T> parsed = <T>[];
      for (final dynamic row in rows) {
        if (row is! Map) return null;
        final Map<String, dynamic> value = Map<String, dynamic>.from(row);
        final String id = value['id']?.toString().trim() ?? '';
        if (id.isEmpty || !ids.add(id)) return null;
        parsed.add(parse(value));
      }
      return List<T>.unmodifiable(parsed);
    } on Object {
      // 写入已确认成功；响应列表无法解析不能变成“提交失败，请重试”。
      return null;
    }
  }

  Future<List<T>> load(Future<List<T>> Function() fetch) async {
    final int session = _tokens.sessionId;
    while (true) {
      if (session != _tokens.sessionId) throw const SessionChangedException();
      final List<T>? saved = pending;
      if (saved != null) {
        _rows = null;
        return saved;
      }
      final int revision = _revision;
      try {
        final List<T> rows = await fetch();
        if (session != _tokens.sessionId) throw const SessionChangedException();
        if (revision == _revision) return rows;
      } on Object {
        if (session != _tokens.sessionId) throw const SessionChangedException();
        if (revision == _revision) rethrow;
      }
      // 查询期间发生写入：使用新的完整响应，或重新取数，不交付旧列表。
    }
  }
}
