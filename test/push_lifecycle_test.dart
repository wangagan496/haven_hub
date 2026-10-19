import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/utils/emitter.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/widgets/push_lifecycle.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('haven_hub/push');
  late SharedPreferences preferences;
  var clickReads = 0;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    preferences = await SharedPreferences.getInstance();
    await tokenManager.init();
  });
  setUp(() async {
    tokenManager.beforeSessionEnd = null;
    await tokenManager.deleteToken();
    await preferences.clear();
    clickReads = 0;
    debugDefaultTargetPlatformOverride = TargetPlatform.ohos;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'takeClick') clickReads++;
      return <String, dynamic>{};
    });
  });
  tearDown(() {
    tokenManager.beforeSessionEnd = null;
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> observeTimers(Future<void> Function(List<Timer>) body) async {
    final timers = <Timer>[];
    try {
      await runZoned(() => body(timers), zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createPeriodicTimer(zone, duration, callback);
          if (duration == const Duration(seconds: 2)) timers.add(timer);
          return timer;
        },
      ));
    } finally {
      for (final timer in timers) { timer.cancel(); }
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('click timer starts after login, stops at logout and restarts once', (tester) async {
    await observeTimers((timers) async {
      await tester.pumpWidget(const PushLifecycle(child: SizedBox()));
      await tester.pump();
      expect(timers, isEmpty);
      await tokenManager.setToken('account-a');
      eventBus.fire(const LoginSuccessEvent());
      await tester.pump();
      expect(timers.where((timer) => timer.isActive), hasLength(1));
      eventBus.fire(const LoginSuccessEvent());
      await tester.pump();
      expect(timers, hasLength(1));
      final reads = clickReads;
      await tester.pump(const Duration(seconds: 2));
      expect(clickReads, reads + 1);
      await tokenManager.deleteToken();
      expect(timers.where((timer) => timer.isActive), isEmpty);
      eventBus.fire(const LogoutEvent());
      await tester.pump();
      final afterLogout = clickReads;
      await tester.pump(const Duration(seconds: 4));
      expect(clickReads, afterLogout);
      await tokenManager.setToken('account-b');
      eventBus.fire(const LoginSuccessEvent());
      await tester.pump();
      expect(timers.where((timer) => timer.isActive), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      expect(timers.where((timer) => timer.isActive), isEmpty);
    });
  });

  testWidgets('restored login creates one click timer', (tester) async {
    await tokenManager.setToken('restored-account');
    await observeTimers((timers) async {
      await tester.pumpWidget(const PushLifecycle(child: SizedBox()));
      await tester.pump();
      expect(timers, hasLength(1));
      expect(timers.single.isActive, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(timers.single.isActive, isFalse);
    });
  });

  testWidgets('unsupported platform never creates a click timer', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tokenManager.setToken('account-a');
    await observeTimers((timers) async {
      await tester.pumpWidget(const PushLifecycle(child: SizedBox()));
      await tester.pump();
      expect(timers, isEmpty);
      expect(clickReads, 0);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
