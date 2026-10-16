import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:haven_hub/api/location.dart';
import 'package:haven_hub/pages/location/location_list.dart';
import 'package:permission_handler/permission_handler.dart';

import 'helpers/widget_harness.dart';

const LocationLookupResult _ipResult = LocationLookupResult(
  address: 'IP 地址',
  communities: <NearbyCommunity>[],
  isIpBased: true,
);
final Finder _settings = find.byKey(const Key('location-settings-button'));

Position _position() => Position.fromMap(<String, Object>{
      'latitude': 30.0,
      'longitude': 120.0,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'accuracy': 5.0,
      'altitude': 0.0,
      'speed': 0.0,
      'heading': 0.0,
      'is_mocked': true,
    });

void _returnFromSettings(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  testWidgets('entering the page only checks permission without requesting it',
      (WidgetTester tester) async {
    const MethodChannel channel =
        MethodChannel('flutter.baseflow.com/permissions/methods');
    final List<String> calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall call) async {
        calls.add(call.method);
        if (call.method == 'checkPermissionStatus') {
          return PermissionStatus.denied.index;
        }
        if (call.method == 'openAppSettings') return true;
        throw StateError('Unexpected permission call: ${call.method}');
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await pumpPage(tester, LocationList(ipLocationLookup: () async => _ipResult));
    expect(calls, <String>['checkPermissionStatus']);
    await tester.tap(_settings);
    await tester.pumpAndSettle();
    expect(calls, <String>['checkPermissionStatus', 'openAppSettings']);
    await finishPage(tester);
  });

  for (final PermissionStatus status in <PermissionStatus>[
    PermissionStatus.denied,
    PermissionStatus.permanentlyDenied,
  ]) {
    testWidgets('$status offers settings while keeping the IP result',
        (WidgetTester tester) async {
      int opens = 0;
      await pumpPage(
          tester,
          LocationList(
            permissionRequester: () async => status,
            ipLocationLookup: () async => _ipResult,
            settingsOpener: () async {
              opens++;
              return true;
            },
          ));
      expect(find.text('如未授权，请到设置授权'), findsOneWidget);
      expect(find.text('IP 地址'), findsOneWidget);
      await tester.tap(_settings);
      await tester.pumpAndSettle();
      expect(opens, 1);
      _returnFromSettings(tester);
      await tester.pumpAndSettle();
      expect(_settings, findsOneWidget);
      await finishPage(tester);
    });
  }

  testWidgets('settings return rechecks permission and ignores stale IP result',
      (WidgetTester tester) async {
    final Completer<LocationLookupResult> oldIp =
        Completer<LocationLookupResult>();
    PermissionStatus status = PermissionStatus.denied;
    int checks = 0;
    int gpsCalls = 0;
    await pumpPage(
        tester,
        LocationList(
          permissionRequester: () async {
            checks++;
            return status;
          },
          ipLocationLookup: () => oldIp.future,
          settingsOpener: () async => true,
          positionLoader: () async {
            gpsCalls++;
            return _position();
          },
          locationLookup: (double lat, double lon,
                  {required bool isMocked}) async =>
              const LocationLookupResult(
                  address: '授权后的位置', communities: <NearbyCommunity>[]),
        ));
    await tester.tap(_settings);
    await tester.pumpAndSettle();
    status = PermissionStatus.granted;
    _returnFromSettings(tester);
    await tester.pumpAndSettle();
    expect(checks, 2);
    expect(gpsCalls, 1);
    expect(find.text('授权后的位置'), findsOneWidget);
    expect(_settings, findsNothing);
    oldIp.complete(_ipResult);
    await tester.pumpAndSettle();
    expect(find.text('授权后的位置'), findsOneWidget);
    expect(find.text('IP 地址'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(checks, 2, reason: '同一次返回只刷新一次');
    await finishPage(tester);
  });

  testWidgets('settings launch cannot be submitted twice while pending',
      (WidgetTester tester) async {
    final Completer<bool> opened = Completer<bool>();
    int calls = 0;
    await pumpPage(
        tester,
        LocationList(
          permissionRequester: () async => PermissionStatus.denied,
          ipLocationLookup: () async => _ipResult,
          settingsOpener: () {
            calls++;
            return opened.future;
          },
        ));
    await tester.tap(_settings);
    await tester.pump();
    await tester.tap(_settings);
    expect(calls, 1);
    expect(tester.widget<TextButton>(_settings).onPressed, isNull);
    opened.complete(false);
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(_settings).onPressed, isNotNull);
    expect(find.text('无法打开设置，请在系统设置中为本应用开启定位权限'), findsOneWidget);
    await finishPage(tester);
  });

  for (final bool timeout in <bool>[false, true]) {
    testWidgets('settings ${timeout ? 'timeout' : 'exception'} allows retry',
        (WidgetTester tester) async {
      await pumpPage(
          tester,
          LocationList(
            permissionRequester: () async => PermissionStatus.denied,
            ipLocationLookup: () async => _ipResult,
            settingsOpener: () => timeout
                ? Completer<bool>().future
                : Future<bool>.error(StateError('settings unavailable')),
          ));
      await tester.tap(_settings);
      await tester.pump(timeout ? const Duration(seconds: 6) : Duration.zero);
      await tester.pumpAndSettle();
      expect(tester.widget<TextButton>(_settings).onPressed, isNotNull);
      expect(find.text('无法打开设置，请在系统设置中为本应用开启定位权限'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finishPage(tester);
    });
  }

  testWidgets('late settings callback after leaving does not update UI',
      (WidgetTester tester) async {
    final Completer<bool> opened = Completer<bool>();
    int checks = 0;
    await pumpPage(
        tester,
        LocationList(
          permissionRequester: () async {
            checks++;
            return PermissionStatus.denied;
          },
          ipLocationLookup: () async => _ipResult,
          settingsOpener: () => opened.future,
        ));
    await tester.tap(_settings);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    opened.complete(false);
    _returnFromSettings(tester);
    await tester.pumpAndSettle();
    expect(checks, 1);
    expect(tester.takeException(), isNull);
    await finishPage(tester);
  });
}
