import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/utils/harmony_token_storage.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Channel mocks exercise the production Dart boundary, not the device keystore.
class _PreferencesWithRemovalFailure implements SharedPreferences {
  _PreferencesWithRemovalFailure(this.delegate);
  final SharedPreferences delegate;
  bool fail = true;
  bool throws = false;
  @override
  Future<bool> remove(String key) async {
    if (key == GlobalVariable.tokenKey && throws) {
      throw StateError('unavailable');
    }
    return fail && key == GlobalVariable.tokenKey
        ? false
        : delegate.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('haven_hub/secure_tokens');
  const empty = '{"version":1,"token":"","refreshToken":""}';
  String? persisted;
  Object? failure;
  final methods = <String>[];
  Completer<void>? entered;
  Completer<void>? release;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    persisted = empty;
    failure = null;
    entered = null;
    release = null;
    methods.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      final error = failure;
      if (error != null) throw error;
      switch (call.method) {
        case 'read':
          final snapshot = persisted;
          entered?.complete();
          await release?.future;
          return snapshot;
        case 'write':
          persisted = (call.arguments as Map)['payload'] as String;
          entered?.complete();
          await release?.future;
          return null;
        case 'clear':
          persisted = empty;
          return null;
        default:
          throw MissingPluginException();
      }
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Harmony default selects the system bridge', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.ohos;
    final manager = TokenManager();
    await manager.loadTokens();
    expect(await manager.setToken('access', refreshToken: 'refresh'), isTrue);
    expect(methods, <String>['read', 'write']);
    expect(manager.getToken(), 'access');
  });

  test('both tokens survive restart and clear leaves an empty session',
      () async {
    final storage = HarmonyTokenStorage();
    expect(await storage.write('access', 'refresh'), isTrue);
    expect(jsonDecode(persisted!), <String, Object>{
      'version': 1,
      'token': 'access',
      'refreshToken': 'refresh',
    });
    final restarted = HarmonyTokenStorage();
    await restarted.load();
    expect(restarted.token, 'access');
    expect(restarted.refreshToken, 'refresh');
    expect(await restarted.clear(), isTrue);
    final signedOut = HarmonyTokenStorage();
    await signedOut.load();
    expect(signedOut.token, isEmpty);
    expect(signedOut.refreshToken, isEmpty);
  });

  test('legacy plaintext is deleted and never imported or resurrected',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      GlobalVariable.tokenKey: 'legacy',
      GlobalVariable.refreshTokenKey: 'legacy-refresh',
      'other_setting': 'preserved',
    });
    final storage = HarmonyTokenStorage();
    await storage.load();
    expect(storage.token, isEmpty);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(GlobalVariable.tokenKey), isNull);
    expect(preferences.getString(GlobalVariable.refreshTokenKey), isNull);
    expect(preferences.getString('other_setting'), 'preserved');
    await storage.write('new', 'new-refresh');
    await storage.clear();
    await storage.load();
    expect(storage.token, isEmpty);
  });

  test('cleanup failure blocks load and write but still clears the asset',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      GlobalVariable.tokenKey: 'legacy',
      GlobalVariable.refreshTokenKey: 'legacy-refresh',
    });
    final preferences =
        _PreferencesWithRemovalFailure(await SharedPreferences.getInstance());
    final storage =
        HarmonyTokenStorage(preferencesLoader: () async => preferences);
    await expectLater(storage.load(), throwsA(isA<PlatformException>()));
    expect(await storage.write('new', 'refresh'), isFalse);
    expect(methods, isEmpty);
    expect(await storage.clear(), isFalse);
    expect(methods, <String>['clear']);
    expect(
        preferences.delegate.getString(GlobalVariable.refreshTokenKey), isNull);
    preferences.fail = false;
    await storage.load();
    expect(await storage.write('new', 'refresh'), isTrue);
  });

  test('system failure and missing plugin never fall back to plaintext',
      () async {
    final storage = HarmonyTokenStorage();
    failure = PlatformException(code: 'secure_storage_failed');
    await expectLater(storage.load(), throwsA(isA<PlatformException>()));
    expect(await storage.write('secret', 'refresh-secret'), isFalse);
    expect(await storage.clear(), isFalse);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(GlobalVariable.tokenKey), isNull);
    failure = MissingPluginException();
    expect(await storage.write('secret', 'refresh-secret'), isFalse);
    failure = null;
    await storage.load();
    expect(await storage.write('secret', 'refresh-secret'), isTrue);
  });

  test('a thrown legacy removal still attempts the second credential',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      GlobalVariable.tokenKey: 'old',
      GlobalVariable.refreshTokenKey: 'old-refresh',
    });
    final preferences =
        _PreferencesWithRemovalFailure(await SharedPreferences.getInstance())
          ..throws = true;
    final storage =
        HarmonyTokenStorage(preferencesLoader: () async => preferences);
    expect(await storage.clear(), isFalse);
    expect(preferences.delegate.getString(GlobalVariable.tokenKey), 'old');
    expect(
        preferences.delegate.getString(GlobalVariable.refreshTokenKey), isNull);
    expect(methods, <String>['clear']);
  });

  for (final payload in <String?>[
    null,
    '',
    '{}',
    '{broken secret',
    '{"version":2,"token":"secret","refreshToken":"refresh"}',
    '{"version":1,"token":1,"refreshToken":"refresh"}',
  ]) {
    test(
        'invalid system payload is rejected without exposing its value ${payload?.length}',
        () async {
      persisted = payload;
      final storage = HarmonyTokenStorage();
      await expectLater(
          storage.load(),
          throwsA(isA<FormatException>().having(
            (error) => error.toString(),
            'message',
            isNot(contains('secret')),
          )));
      expect(storage.token, isEmpty);
    });
  }

  test('UTF8 payload limit is enforced before the native write', () async {
    final storage = HarmonyTokenStorage();
    expect(
        await storage.write(List.filled(400, '中').join(), 'refresh'), isFalse);
    expect(methods, isEmpty);
    expect(await storage.write('small', 'refresh'), isTrue);
    final bytes = utf8.encode(persisted!).length;
    expect(await storage.write('x' * (1024 - bytes + 5), 'refresh'), isTrue);
    expect(utf8.encode(persisted!).length, 1024);
    expect(await storage.write('x' * (1025 - bytes + 5), 'refresh'), isFalse);
    expect(utf8.encode(persisted!).length, 1024);
  });

  test('failed startup can retry through TokenManager', () async {
    final manager = TokenManager(storage: HarmonyTokenStorage());
    failure = PlatformException(code: 'secure_storage_failed');
    await expectLater(manager.loadTokens(), throwsA(isA<PlatformException>()));
    failure = null;
    await manager.loadTokens();
    expect(await manager.setToken('retry', refreshToken: 'refresh'), isTrue);
  });

  test('logout after a delayed refresh persists an empty session', () async {
    final manager = TokenManager(storage: HarmonyTokenStorage());
    entered = Completer<void>();
    release = Completer<void>();
    final refresh =
        manager.setRefreshedToken('late', refreshToken: 'late-refresh');
    await entered!.future;
    manager.invalidateLocalSession();
    final logout = manager.deleteToken();
    release!.complete();
    expect(await refresh, isFalse);
    expect(await logout, isTrue);
    release = null;
    entered = null;
    final restarted = HarmonyTokenStorage();
    await restarted.load();
    expect(restarted.token, isEmpty);
  });

  test('late load cannot restore credentials after invalidation', () async {
    final storage = HarmonyTokenStorage();
    await storage.write('old', 'old-refresh');
    entered = Completer<void>();
    release = Completer<void>();
    final loading = storage.load();
    await entered!.future;
    storage.invalidate();
    release!.complete();
    await loading;
    expect(storage.token, isEmpty);
  });

  test('queued account switch wins over an older read', () async {
    final storage = HarmonyTokenStorage();
    await storage.write('old', 'old-refresh');
    entered = Completer<void>();
    release = Completer<void>();
    final loading = storage.load();
    await entered!.future;
    final writing = storage.write('new', 'new-refresh');
    final gate = release!;
    // Later writes need no second gate.
    entered = null;
    release = null;
    gate.complete();
    await loading;
    expect(await writing, isTrue);
    expect(storage.token, 'new');
  });
}
