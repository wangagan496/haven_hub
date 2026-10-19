import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/utils/push_subscription.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    preferences = await SharedPreferences.getInstance();
    await tokenManager.init();
  });
  setUp(() async { await preferences.clear(); await tokenManager.setToken('account-a'); });

  test('permission denial never registers or claims enabled', () async {
    var registrations = 0;
    final push = PushSubscription(
      platform: (_) async => throw const FormatException('denied'),
      config: () async => <String, dynamic>{'profileId':'profile'},
      register: (_) async { registrations++; },
    );
    await expectLater(push.enable(), throwsFormatException);
    expect(registrations, 0);
    expect(preferences.getBool('push_enabled'), isNull);
  });

  test('logout revokes again after a late registration response', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    var revocations = 0;
    final push = PushSubscription(
      platform: (request) async => request['action'] == 'enable'
          ? <String, dynamic>{'platform':'harmony','token':'device'} : <String, dynamic>{},
      config: () async => <String, dynamic>{'profileId':'profile'},
      register: (_) async { started.complete(); await release.future; },
      unregister: (_) async { revocations++; },
    );
    final enabled = push.enable();
    final failed = expectLater(enabled, throwsFormatException);
    await started.future;
    await tokenManager.deleteToken();
    await push.disable();
    expect(revocations, 1);
    release.complete();
    await failed;
    expect(revocations, 2);
    expect(preferences.getBool('push_enabled'), isFalse);
    expect(preferences.getString('registered_push_installation'), isNull);
  });

  test('failed server revocation persists and resumes without re-enabling', () async {
    var offline = true;
    var registrations = 0;
    final push = PushSubscription(
      platform: (request) async => request['action'] == 'enable'
          ? <String, dynamic>{'platform':'harmony','token':'device'} : <String, dynamic>{},
      config: () async => <String, dynamic>{'profileId':'profile'},
      register: (_) async { registrations++; },
      unregister: (_) async { if (offline) throw const FormatException('offline'); },
    );
    await push.enable();
    await expectLater(push.disable(), throwsFormatException);
    expect(preferences.getBool('push_revoke_pending'), isTrue);
    expect(preferences.getString('registered_push_installation'), isNotNull);
    offline = false;
    await push.resume();
    expect(registrations, 1);
    expect(preferences.getBool('push_revoke_pending'), isNull);
    expect(preferences.getBool('push_enabled'), isFalse);
  });

  test('manual disable during platform registration cancels enable', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    var registrations = 0;
    var disables = 0;
    final push = PushSubscription(
      platform: (request) async {
        if (request['action'] == 'disable') disables++;
        if (request['action'] == 'enable') {
          started.complete(); await release.future;
          return <String, dynamic>{'platform':'harmony','token':'device'};
        }
        return <String, dynamic>{};
      },
      config: () async => <String, dynamic>{'profileId':'profile'},
      register: (_) async { registrations++; },
    );
    final failed = expectLater(push.enable(), throwsFormatException);
    await started.future; await push.disable(); release.complete(); await failed;
    expect(registrations, 0);
    expect(disables, 2);
    expect(preferences.getBool('push_enabled'), isFalse);
  });

  test('new account cannot bind until the old server registration is revoked', () async {
    await preferences.setBool('push_revoke_pending', true);
    await preferences.setString('registered_push_installation', 'old-installation');
    await preferences.setString('registered_push_profile', 'old-profile');
    var registrations = 0;
    final push = PushSubscription(
      platform: (_) async => <String, dynamic>{},
      config: () async => <String, dynamic>{'profileId':'new-profile'},
      register: (_) async { registrations++; },
      unregister: (_) async => throw const FormatException('offline'),
    );
    await expectLater(push.enable(), throwsFormatException);
    expect(registrations, 0);
    expect(preferences.getString('registered_push_installation'), 'old-installation');
    expect(preferences.getBool('push_revoke_pending'), isTrue);
  });

  test('a persistently failing platform unbind no longer blocks enabling', () async {
    await preferences.setBool('push_revoke_pending', true);
    await preferences.setString('registered_push_profile', 'old-profile');
    var registrations = 0;
    final disabled = <String>[];
    final push = PushSubscription(
      platform: (request) async {
        if (request['action'] == 'disable') {
          disabled.add(request['profileId'] as String);
          throw const FormatException('profile never bound');
        }
        if (request['action'] == 'enable') return <String, dynamic>{'platform':'harmony','token':'device'};
        return <String, dynamic>{};
      },
      config: () async => <String, dynamic>{'profileId':'new-profile'},
      register: (_) async { registrations++; },
    );
    // 第一次：服务端无需解绑，平台解绑失败只记为旧 profile，待解绑状态解除。
    await expectLater(push.enable(), throwsFormatException);
    expect(preferences.getBool('push_revoke_pending'), isNull);
    expect(preferences.getString('push_stale_profile'), 'old-profile');
    // 第二次：先尽力清理旧 profile，再正常登记。
    await push.enable();
    expect(registrations, 1);
    expect(disabled, <String>['old-profile', 'old-profile']);
    expect(preferences.getString('push_stale_profile'), isNull);
    expect(preferences.getBool('push_enabled'), isTrue);
  });

  test('a transient resume failure keeps push enabled and reports the problem', () async {
    var offline = false;
    var registrations = 0;
    var revocations = 0;
    final push = PushSubscription(
      platform: (request) async => request['action'] == 'disable'
          ? <String, dynamic>{} : <String, dynamic>{'platform':'harmony','token':'device'},
      config: () async {
        if (offline) throw const FormatException('网络连接失败');
        return <String, dynamic>{'profileId':'profile'};
      },
      register: (_) async { registrations++; },
      unregister: (_) async { revocations++; },
    );
    await push.enable();
    offline = true;
    await expectLater(push.resume(), throwsFormatException);
    expect(preferences.getBool('push_enabled'), isTrue);
    expect(preferences.getString('registered_push_installation'), isNotNull);
    expect(revocations, 0);
    expect(push.resumeProblem.value, '网络连接失败');
    offline = false;
    await push.resume();
    expect(registrations, 2);
    expect(push.resumeProblem.value, isNull);
  });

  test('restart retries a revocation interrupted before its response', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final first = PushSubscription(
      platform: (request) async => request['action'] == 'enable'
          ? <String, dynamic>{'platform':'harmony','token':'device'} : <String, dynamic>{},
      config: () async => <String, dynamic>{'profileId':'profile'},
      register: (_) async {},
      unregister: (_) async { started.complete(); await release.future; },
    );
    await first.enable();
    final stopping = first.disable();
    await started.future;
    // 进程在这里被杀：新实例只能看到已落盘的状态。
    expect(preferences.getBool('push_revoke_pending'), isTrue);
    var retries = 0;
    final restarted = PushSubscription(
      platform: (_) async => <String, dynamic>{},
      unregister: (_) async { retries++; },
    );
    await restarted.resume();
    expect(retries, 1);
    expect(preferences.getBool('push_revoke_pending'), isNull);
    release.complete();
    await stopping;
  });

  test('restart revokes a registration interrupted before push was marked enabled', () async {
    // 开启途中被杀：安装标识已保存，服务端可能已登记，但 push_enabled 尚未写入。
    await preferences.setString('registered_push_installation', 'half-registered');
    await preferences.setString('registered_push_profile', 'profile');
    final revoked = <String>[];
    var registrations = 0;
    final restarted = PushSubscription(
      platform: (_) async => <String, dynamic>{},
      config: () async => <String, dynamic>{'profileId':'profile'},
      register: (_) async { registrations++; },
      unregister: (id) async { revoked.add(id); },
    );
    await restarted.resume();
    expect(revoked, <String>['half-registered']);
    expect(registrations, 0);
    expect(preferences.getString('registered_push_installation'), isNull);
  });

  test('logout does not wait for revocation and repeated logouts revoke once', () async {
    final release = Completer<void>();
    var revocations = 0;
    final push = PushSubscription(
      platform: (request) async => request['action'] == 'enable'
          ? <String, dynamic>{'platform':'harmony','token':'device'} : <String, dynamic>{},
      config: () async => <String, dynamic>{'profileId':'profile'},
      register: (_) async {},
      unregister: (_) async { revocations++; await release.future; },
    );
    await push.enable();
    tokenManager.beforeSessionEnd = push.disable;
    try {
      // 解绑请求一直挂起，登出仍然立即完成。
      expect(await tokenManager.deleteToken(), isTrue);
      expect(tokenManager.getToken(), isEmpty);
      await tokenManager.deleteToken();
      await pumpEventQueue();
      expect(revocations, 1);
      release.complete();
      // 复用进行中的解绑，不会再发一次。
      await push.disable();
      expect(revocations, 1);
      expect(preferences.getString('registered_push_installation'), isNull);
    } finally { tokenManager.beforeSessionEnd = null; }
  });
}
