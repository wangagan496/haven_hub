import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/utils/token_storage.dart';

/// 可控的凭证存储，用来复现「磁盘清理失败」这类真实设备上很难制造的状态。
class _FakeTokenStorage implements TokenStorage {
  _FakeTokenStorage({
    this.token = '',
    this.refreshToken = '',
    this.clearSucceeds = true,
  });

  @override
  String token;

  @override
  String refreshToken;

  /// clear() 是否报告成功。设备上 SharedPreferences 删除失败时即为 false。
  bool clearSucceeds;

  int clearCalls = 0;
  int invalidateCalls = 0;

  @override
  Future<void> load() async {}

  @override
  Future<bool> write(String token, String refreshToken) async {
    this.token = token;
    this.refreshToken = refreshToken;
    return true;
  }

  @override
  Future<bool> clear() async {
    clearCalls++;
    // 真实实现会先清内存再删磁盘；这里照搬「内存已空」的行为。
    token = '';
    refreshToken = '';
    return clearSucceeds;
  }

  @override
  void invalidate() {
    invalidateCalls++;
    token = '';
    refreshToken = '';
  }
}

void main() {
  group('TokenManager.deleteToken', () {
    test('clears stored credentials and reports success', () async {
      final _FakeTokenStorage storage = _FakeTokenStorage(
        token: 'token-a',
        refreshToken: 'refresh-a',
      );
      final TokenManager manager = TokenManager(storage: storage);

      expect(await manager.deleteToken(), isTrue);
      expect(manager.getToken(), isEmpty);
      expect(manager.getRefreshToken(), isEmpty);
    });

    test('reports failure when the credential store cannot delete', () async {
      final _FakeTokenStorage storage = _FakeTokenStorage(
        token: 'token-a',
        refreshToken: 'refresh-a',
        clearSucceeds: false,
      );
      final TokenManager manager = TokenManager(storage: storage);

      // 返回 false 是给调用方的信号：磁盘上的凭证可能还在，重启会读回来。
      expect(await manager.deleteToken(), isFalse);
    });

    test('does not advance the session version when clearing fails', () async {
      final _FakeTokenStorage storage = _FakeTokenStorage(
        token: 'token-a',
        refreshToken: 'refresh-a',
        clearSucceeds: false,
      );
      final TokenManager manager = TokenManager(storage: storage);
      final int before = manager.sessionVersion;

      await manager.deleteToken();

      // 版本号代表存储中凭证的代次。清理失败时存储内容没变，推进它会让正在
      // 进行的重放判定以为凭证已经换过一代。
      expect(manager.sessionVersion, before);
    });

    test('advances the session version when clearing succeeds', () async {
      final _FakeTokenStorage storage = _FakeTokenStorage(
        token: 'token-a',
        refreshToken: 'refresh-a',
      );
      final TokenManager manager = TokenManager(storage: storage);
      final int before = manager.sessionVersion;

      await manager.deleteToken();

      expect(manager.sessionVersion, before + 1);
    });
  });

  group('TokenManager.setToken', () {
    test('advances the session version so in-flight replays are invalidated',
        () async {
      final _FakeTokenStorage storage = _FakeTokenStorage();
      final TokenManager manager = TokenManager(storage: storage);
      final int before = manager.sessionVersion;

      expect(
        await manager.setToken('token-b', refreshToken: 'refresh-b'),
        isTrue,
      );
      expect(manager.sessionVersion, before + 1);
      expect(manager.getToken(), 'token-b');
    });

    test('tracks refresh credentials separately from a normal login', () async {
      final _FakeTokenStorage storage = _FakeTokenStorage();
      final TokenManager manager = TokenManager(storage: storage);

      expect(
        await manager.setRefreshedToken(
          'refreshed-token',
          refreshToken: 'refreshed-refresh',
        ),
        isTrue,
      );
      expect(manager.refreshSessionVersion, manager.sessionVersion);

      await manager.setToken('login-token', refreshToken: 'login-refresh');
      expect(manager.refreshSessionVersion, isNull);
    });
  });

  group('TokenManager.invalidateLocalSession', () {
    test('drops in-memory credentials without touching the store', () async {
      final _FakeTokenStorage storage = _FakeTokenStorage(
        token: 'token-a',
        refreshToken: 'refresh-a',
      );
      final TokenManager manager = TokenManager(storage: storage);
      final int before = manager.sessionVersion;

      manager.invalidateLocalSession();

      expect(manager.getToken(), isEmpty);
      expect(manager.getRefreshToken(), isEmpty);
      // 不碰持久化，也不改版本：磁盘上仍留着凭证这件事必须保持可见，
      // 由调用方决定重试还是提示用户。
      expect(storage.clearCalls, 0);
      expect(manager.sessionVersion, before);
    });
  });
}
