import 'package:shared_preferences/shared_preferences.dart';

import '../constant/index.dart';

typedef SharedPreferencesLoader = Future<SharedPreferences> Function();

class TokenManager {
  TokenManager({SharedPreferencesLoader? preferencesLoader})
      : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  final SharedPreferencesLoader _preferencesLoader;

  SharedPreferences? _preferences;
  Future<void>? _initialization;
  String _token = '';
  String _refreshToken = '';

  Future<void> init() {
    final Future<void>? initialization = _initialization;
    if (initialization != null) {
      return initialization;
    }

    late final Future<void> newInitialization;
    newInitialization = Future<void>.sync(_loadPreferences).then<void>(
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

  Future<void> _loadPreferences() async {
    final SharedPreferences preferences = await _preferencesLoader();
    _preferences = preferences;
    _token = preferences.getString(GlobalVariable.tokenKey) ?? '';
    _refreshToken = preferences.getString(GlobalVariable.refreshTokenKey) ?? '';
  }

  String getToken() {
    return _token;
  }

  String getRefreshToken() {
    return _refreshToken;
  }

  Future<bool> setToken(
    String token, {
    String refreshToken = '',
  }) async {
    final SharedPreferences preferences = await _getPreferences();
    final List<bool> saved = await Future.wait(<Future<bool>>[
      preferences.setString(GlobalVariable.tokenKey, token),
      preferences.setString(
        GlobalVariable.refreshTokenKey,
        refreshToken,
      ),
    ]);

    final bool didSave = saved.every((bool result) => result);
    if (didSave) {
      _token = token;
      _refreshToken = refreshToken;
    }
    return didSave;
  }

  Future<bool> deleteToken() async {
    final SharedPreferences preferences = await _getPreferences();
    final List<bool> removed = await Future.wait(<Future<bool>>[
      preferences.remove(GlobalVariable.tokenKey),
      preferences.remove(GlobalVariable.refreshTokenKey),
    ]);
    _token = '';
    _refreshToken = '';
    return removed.every((bool result) => result);
  }

  Future<SharedPreferences> _getPreferences() async {
    final SharedPreferences? preferences = _preferences;
    if (preferences != null) {
      return preferences;
    }

    await init();
    return _preferences!;
  }
}

final TokenManager tokenManager = TokenManager();
