import 'token_storage.dart';

class TokenManager {
  TokenManager({TokenStorage? storage})
      : _storage = storage ?? SharedPreferencesTokenStorage();

  final TokenStorage _storage;
  Future<void>? _initialization;
  int _sessionVersion = 0;
  int? _refreshSessionVersion;

  /// 会话身份。只在**登录、登出**时变化，刷新不动它。
  ///
  /// 与 [sessionVersion] 分开是必要的：版本号回答「凭证换到第几代了」，这个
  /// 回答「现在是谁的会话」。两者混用会让「同一会话内刷新两次」和「换了账号
  /// 又刷新」变得无法区分——前者该重放，后者绝不能重放。
  int _sessionId = 0;

  int get sessionVersion => _sessionVersion;

  /// 见 [_sessionId]。请求在发出时记下它，处理 401 时比对。
  int get sessionId => _sessionId;

  /// Returns the session version most recently created by a token refresh.
  ///
  /// A normal login or logout clears this marker so an in-flight request from
  /// an earlier account can never be mistaken for a refresh replay.
  int? get refreshSessionVersion => _refreshSessionVersion;

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
  }) {
    return _writeToken(token, refreshToken, fromRefresh: false);
  }

  /// Stores credentials returned by the refresh endpoint.
  Future<bool> setRefreshedToken(
    String token, {
    required String refreshToken,
  }) {
    return _writeToken(token, refreshToken, fromRefresh: true);
  }

  Future<bool> _writeToken(
    String token,
    String refreshToken, {
    required bool fromRefresh,
  }) async {
    final bool saved = await _storage.write(token, refreshToken);
    if (saved) {
      _sessionVersion++;
      _refreshSessionVersion = fromRefresh ? _sessionVersion : null;
      // 只有登录换会话；刷新沿用当前会话，否则飞行中的请求会被误判成换了人。
      if (!fromRefresh) {
        _sessionId++;
      }
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
      _refreshSessionVersion = null;
      _sessionId++;
    }
    return cleared;
  }

  /// 只让本进程立刻失去可用凭证，不触碰持久化存储，也不推进会话版本。
  ///
  /// 用于 [deleteToken] 失败后的兜底：界面必须马上退出登录态，但磁盘清理
  /// 失败这件事要如实保留，交由调用方重试或提示用户。
  void invalidateLocalSession() {
    _storage.invalidate();
    _refreshSessionVersion = null;
    // 内存凭证作废等于本会话已经结束：飞行中的请求不能再按它重放。
    _sessionId++;
  }
}

final TokenManager tokenManager = TokenManager();
