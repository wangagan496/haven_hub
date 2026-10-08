import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/utils/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 使用实际的凭证存储实现，在写入偏好设置后、返回管理器前暂停。
// SharedPreferences 后端仍是测试 mock，不代表设备存储故障已复现。
class _DelayedTokenStorage extends SharedPreferencesTokenStorage {
  final written = Completer<void>();
  final release = Completer<void>();
  bool clearSucceeds = true;

  @override
  Future<bool> write(String token, String refreshToken) async {
    final saved = await super.write(token, refreshToken);
    if (!written.isCompleted) written.complete();
    await release.future;
    return saved;
  }

  @override
  Future<bool> clear() async {
    if (clearSucceeds) return super.clear();
    invalidate();
    return false;
  }
}

Future<TokenManager> _reload() async {
  final manager = TokenManager(storage: SharedPreferencesTokenStorage());
  await manager.init();
  return manager;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('queued logout removes late refresh credentials before reload',
      () async {
    final storage = _DelayedTokenStorage();
    final tokens = TokenManager(storage: storage);
    final refresh = tokens.setRefreshedToken('late-a', refreshToken: 'late-ra');
    await storage.written.future;
    tokens.invalidateLocalSession();
    final logout = tokens.deleteToken(expectedSessionId: tokens.sessionId);
    storage.release.complete();
    expect(await refresh, isFalse);
    expect(await logout, isTrue);
    final restarted = await _reload();
    expect(restarted.getToken(), isEmpty);
    expect(restarted.getRefreshToken(), isEmpty);
  });

  test('memory invalidation alone does not claim persistent logout', () async {
    final storage = _DelayedTokenStorage();
    final tokens = TokenManager(storage: storage);
    final refresh = tokens.setRefreshedToken('late-a', refreshToken: 'late-ra');
    await storage.written.future;
    tokens.invalidateLocalSession();
    storage.release.complete();
    expect(await refresh, isFalse);
    expect(tokens.getToken(), isEmpty);
    final restarted = await _reload();
    expect(restarted.getToken(), 'late-a');
    expect(restarted.getRefreshToken(), 'late-ra');
    // 完成退出必须执行并检查持久化清理，不能仅推进版本号。
    expect(await tokens.deleteToken(), isTrue);
    expect((await _reload()).getToken(), isEmpty);
  });

  test('failed cleanup reports residual credentials and a retry clears them',
      () async {
    final storage = _DelayedTokenStorage()..clearSucceeds = false;
    final tokens = TokenManager(storage: storage);
    final refresh = tokens.setRefreshedToken('late-a', refreshToken: 'late-ra');
    await storage.written.future;
    tokens.invalidateLocalSession();
    final logout = tokens.deleteToken(expectedSessionId: tokens.sessionId);
    storage.release.complete();
    expect(await refresh, isFalse);
    expect(await logout, isFalse);
    expect(tokens.getToken(), isEmpty);
    expect(tokens.sessionVersion, 0);
    final restarted = await _reload();
    expect(restarted.getToken(), 'late-a');
    expect(restarted.getRefreshToken(), 'late-ra');
    storage.clearSucceeds = true;
    expect(await tokens.deleteToken(), isTrue);
    final cleaned = await _reload();
    expect(cleaned.getToken(), isEmpty);
    expect(cleaned.getRefreshToken(), isEmpty);
  });

  test('login queued after late refresh cleanup survives reload', () async {
    final storage = _DelayedTokenStorage();
    final tokens = TokenManager(storage: storage);
    final refresh = tokens.setRefreshedToken('late-a', refreshToken: 'late-ra');
    await storage.written.future;
    tokens.invalidateLocalSession();
    final logout = tokens.deleteToken(expectedSessionId: tokens.sessionId);
    final login = tokens.setToken('account-b', refreshToken: 'refresh-b');
    storage.release.complete();
    expect(await refresh, isFalse);
    expect(await logout, isTrue);
    expect(await login, isTrue);
    final restarted = await _reload();
    expect(restarted.getToken(), 'account-b');
    expect(restarted.getRefreshToken(), 'refresh-b');
  });
}
