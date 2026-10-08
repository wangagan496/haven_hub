import 'dart:async';

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
  Future<void> Function()? beforeWrite;

  @override
  Future<void> load() async {}

  @override
  Future<bool> write(String token, String refreshToken) async {
    await beforeWrite?.call();
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
  test('queued old refresh cannot overwrite a newer login', () async {
    final _FakeTokenStorage storage =
        _FakeTokenStorage(token: 'a', refreshToken: 'ra');
    final TokenManager manager = TokenManager(storage: storage);
    final int oldSessionId = manager.sessionId;
    final int oldVersion = manager.sessionVersion;
    final Completer<void> writing = Completer<void>();
    final Completer<void> release = Completer<void>();
    storage.beforeWrite = () async {
      if (!writing.isCompleted) writing.complete();
      await release.future;
    };
    final Future<bool> login = manager.setToken('b', refreshToken: 'rb');
    await writing.future;
    final Future<bool> staleRefresh = manager.setRefreshedToken('refreshed-a',
        refreshToken: 'refreshed-ra',
        expectedSessionId: oldSessionId,
        expectedSessionVersion: oldVersion);
    release.complete();
    expect(await login, isTrue);
    expect(await staleRefresh, isFalse);
    expect(manager.getToken(), 'b');
    expect(manager.getRefreshToken(), 'rb');
  });

  test('queued old cleanup cannot erase a newer login', () async {
    final _FakeTokenStorage storage =
        _FakeTokenStorage(token: 'a', refreshToken: 'ra');
    final TokenManager manager = TokenManager(storage: storage);
    final int oldSessionId = manager.sessionId;
    final Completer<void> writing = Completer<void>();
    final Completer<void> release = Completer<void>();
    storage.beforeWrite = () async {
      if (!writing.isCompleted) writing.complete();
      await release.future;
    };
    final Future<bool> login = manager.setToken('b', refreshToken: 'rb');
    await writing.future;
    final Future<bool> oldCleanup =
        manager.deleteToken(expectedSessionId: oldSessionId);
    release.complete();
    expect(await login, isTrue);
    expect(await oldCleanup, isFalse);
    expect(manager.getToken(), 'b');
    expect(storage.clearCalls, 0);
  });

  test('invalidation while saving credentials cannot restore local login',
      () async {
    final _FakeTokenStorage storage =
        _FakeTokenStorage(token: 'a', refreshToken: 'ra');
    final TokenManager manager = TokenManager(storage: storage);
    final Completer<void> writing = Completer<void>();
    final Completer<void> release = Completer<void>();
    storage.beforeWrite = () async {
      writing.complete();
      await release.future;
    };
    final Future<bool> refresh =
        manager.setRefreshedToken('new-a', refreshToken: 'new-ra');
    await writing.future;
    manager.invalidateLocalSession();
    release.complete();
    expect(await refresh, isFalse);
    expect(manager.getToken(), isEmpty);
    expect(manager.getRefreshToken(), isEmpty);
  });

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

    test('failed disk cleanup still ends the in-memory session', () async {
      final _FakeTokenStorage storage = _FakeTokenStorage(
        token: 'token-a',
        refreshToken: 'refresh-a',
        clearSucceeds: false,
      );
      final TokenManager manager = TokenManager(storage: storage);
      final int sessionId = manager.sessionId;
      expect(await manager.deleteToken(), isFalse);
      expect(manager.sessionId, sessionId + 1);
      expect(manager.getToken(), isEmpty);
      expect(manager.refreshSessionVersion, isNull);
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
