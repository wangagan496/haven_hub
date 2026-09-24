import 'package:shared_preferences/shared_preferences.dart';

import '../constant/index.dart';

/// Persistence boundary for authentication credentials.
///
/// The app talks to this abstraction instead of coupling pages to a concrete
/// storage implementation. On HarmonyOS the bundled SharedPreferences plugin
/// is sandboxed; a native keystore-backed implementation can be injected here
/// without changing TokenManager or any page code.
abstract interface class TokenStorage {
  Future<void> load();

  String get token;

  String get refreshToken;

  Future<bool> write(String token, String refreshToken);

  Future<bool> clear();

  /// 只失效本进程内存中的凭证，不触碰持久化存储。
  ///
  /// 供「磁盘清理失败但仍必须立刻退出登录态」的场景兜底：调用方拿到
  /// [clear] 的 false 后，界面仍要立刻不再持有可用的 token。
  void invalidate();
}

class SharedPreferencesTokenStorage implements TokenStorage {
  SharedPreferencesTokenStorage({
    SharedPreferencesLoader? preferencesLoader,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  final SharedPreferencesLoader _preferencesLoader;
  SharedPreferences? _preferences;
  String _token = '';
  String _refreshToken = '';

  @override
  String get token => _token;

  @override
  String get refreshToken => _refreshToken;

  @override
  Future<void> load() async {
    final SharedPreferences preferences = await _getPreferences();
    _token = preferences.getString(GlobalVariable.tokenKey) ?? '';
    _refreshToken = preferences.getString(GlobalVariable.refreshTokenKey) ?? '';
  }

  @override
  Future<bool> write(String token, String refreshToken) async {
    final SharedPreferences preferences = await _getPreferences();
    final bool tokenSaved = await preferences.setString(
      GlobalVariable.tokenKey,
      token,
    );
    if (!tokenSaved) {
      return false;
    }
    final bool refreshTokenSaved = await preferences.setString(
      GlobalVariable.refreshTokenKey,
      refreshToken,
    );
    if (!refreshTokenSaved) {
      await clear();
      return false;
    }
    _token = token;
    _refreshToken = refreshToken;
    return true;
  }

  @override
  Future<bool> clear() async {
    invalidate();

    try {
      final SharedPreferences preferences = await _getPreferences();
      final bool tokenRemoved =
          await preferences.remove(GlobalVariable.tokenKey);
      final bool refreshTokenRemoved =
          await preferences.remove(GlobalVariable.refreshTokenKey);
      return tokenRemoved && refreshTokenRemoved;
    } on Object {
      return false;
    }
  }

  @override
  void invalidate() {
    _token = '';
    _refreshToken = '';
  }

  Future<SharedPreferences> _getPreferences() async {
    final SharedPreferences? preferences = _preferences;
    if (preferences != null) {
      return preferences;
    }
    final SharedPreferences loaded = await _preferencesLoader();
    _preferences = loaded;
    return loaded;
  }
}

typedef SharedPreferencesLoader = Future<SharedPreferences> Function();
