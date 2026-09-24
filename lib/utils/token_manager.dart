import 'token_storage.dart';

class TokenManager {
  TokenManager({TokenStorage? storage})
      : _storage = storage ?? SharedPreferencesTokenStorage();

  final TokenStorage _storage;
  Future<void>? _initialization;
  int _sessionVersion = 0;

  int get sessionVersion => _sessionVersion;

  Future<void> init() {
    final Future<void>? initialization = _initialization;
    if (initialization != null) {
      return initialization;
    }

    late final Future<void> newInitialization;
    newInitialization = Future<void>.sync(_storage.load).then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_initialization, newInitialization)) {
          _initialization = null;
        }
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _initialization = newInitialization;
    return newInitialization;
  }

  String getToken() {
    return _storage.token;
  }

  String getRefreshToken() {
    return _storage.refreshToken;
  }

  Future<bool> setToken(
    String token, {
    String refreshToken = '',
  }) async {
    final bool saved = await _storage.write(token, refreshToken);
    if (saved) {
      _sessionVersion++;
    }
    return saved;
  }

  /// 清除持久化的登录凭证。
  ///
  /// 返回 false 表示磁盘上的凭证**可能仍然存在**：此时内存已被清空，但重启后
  /// 它们会被重新读回。调用方必须处理这个结果，不能当作登出已完成。
  ///
  /// 会话版本只在真正清除成功时推进。版本号代表存储中凭证的代次，清除失败
  /// 时存储内容未变，推进它会让并发中的重放判定以为「凭证已经换过一代」。
  Future<bool> deleteToken() async {
    final bool cleared = await _storage.clear();
    if (cleared) {
      _sessionVersion++;
    }
    return cleared;
  }

  /// 只让本进程立刻失去可用凭证，不触碰持久化存储，也不推进会话版本。
  ///
  /// 用于 [deleteToken] 失败后的兜底：界面必须马上退出登录态，但磁盘清理
  /// 失败这件事要如实保留，交由调用方重试或提示用户。
  void invalidateLocalSession() {
    _storage.invalidate();
  }
}

final TokenManager tokenManager = TokenManager();
