import 'package:shared_preferences/shared_preferences.dart';

import '../constant/index.dart';

class TokenManager {
  SharedPreferences? _preferences;
  String _token = '';
  String _refreshToken = '';

  Future<void> init() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
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
