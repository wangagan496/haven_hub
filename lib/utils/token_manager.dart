import 'token_storage.dart';

class TokenManager {
  TokenManager({TokenStorage? storage})
      : _storage = storage ?? SharedPreferencesTokenStorage();

  final TokenStorage _storage;
  Future<void>? _initialization;

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
    return _storage.write(token, refreshToken);
  }

  Future<bool> deleteToken() {
    return _storage.clear();
  }
}

final TokenManager tokenManager = TokenManager();
