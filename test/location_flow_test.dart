import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:haven_hub/api/location.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/controller/build_controller.dart';
import 'package:haven_hub/pages/building/building_list.dart';
import 'package:haven_hub/pages/location/location_list.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/location.dart';
import 'package:permission_handler/permission_handler.dart';

import 'helpers/widget_harness.dart';

const LocationLookupResult ipResult = LocationLookupResult(
  address: '测试城市',
  communities: <NearbyCommunity>[],
  isIpBased: true,
);

Position samplePosition({DateTime? timestamp, double accuracy = 5}) {
  return Position.fromMap(<String, Object>{
    'latitude': 30.0,
    'longitude': 120.0,
    'timestamp': (timestamp ?? DateTime.now()).millisecondsSinceEpoch,
    'accuracy': accuracy,
    'altitude': 0.0,
    'speed': 0.0,
    'heading': 0.0,
    'is_mocked': true,
  });
}

void main() {
  for (final double width in <double>[390, 1440]) {
    testWidgets('searchable community dropdown stays below the field at $width',
        (WidgetTester tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpPage(
        tester,
        LocationList(
          permissionRequester: () async => PermissionStatus.granted,
          positionLoader: () async => samplePosition(),
          locationLookup: (double lat, double lon,
                  {required bool isMocked}) async =>
              const LocationLookupResult(
            address: '测试地址',
            communities: <NearbyCommunity>[
              NearbyCommunity(name: '春景小区', address: '春景路 1 号', id: 'spring'),
              NearbyCommunity(
                name: '湖畔小区',
                address: '湖畔路 2 号',
                id: 'lake',
                latitude: 30,
                longitude: 120,
              ),
            ],
          ),
        ),
        routes: <String, WidgetBuilder>{
          BuildingList.routeName: (_) => const Scaffold(body: Text('楼栋选择页')),
        },
      );
      final Finder field = find.byType(TextField);
      expect(find.text('春景小区').hitTestable(), findsNothing);
      expect(find.byType(ListTile), findsNothing);
      await tester.tap(field);
      await tester.pumpAndSettle();
      final Finder options = find.byType(MenuItemButton).hitTestable();
      expect(options, findsNWidgets(2));
      final Rect fieldRect = tester.getRect(field);
      final Rect optionRect = tester.getRect(options.first);
      expect(optionRect.left, closeTo(fieldRect.left, 1));
      expect(optionRect.width, closeTo(fieldRect.width, 1));
      expect(optionRect.top, greaterThanOrEqualTo(fieldRect.bottom));
      await tester.tapAt(const Offset(8, 700));
      await tester.pumpAndSettle();
      expect(options, findsNothing);
      await tester.tap(field);
      await tester.enterText(field, '不存在的小区');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的小区'), findsOneWidget);
      expect(tester.widget<MenuItemButton>(options).onPressed, isNull);
      await tester.enterText(field, '春景');
      await tester.pumpAndSettle();
      expect(options, findsOneWidget);
      expect(find.text('春景小区').hitTestable(), findsOneWidget);
      await tester.enterText(field, ' 湖畔路 ');
      await tester.pumpAndSettle();
      expect(options, findsOneWidget);
      expect(find.text('湖畔小区').hitTestable(), findsOneWidget);
      await tester.tap(options);
      await tester.pumpAndSettle();
      expect(find.text('楼栋选择页'), findsOneWidget);
      final info = BuildController.instance().buildingInfo;
      expect(info.name, '湖畔小区');
      expect(info.communityId, 'lake');
      expect(info.latitude, 30);
      expect(info.longitude, 120);
      expect(tester.takeException(), isNull);
      await finishPage(tester);
      BuildController.instance().clearBuildingInfo();
    });
  }

  test('179m community position is accepted without waiting for timeout',
      () async {
    final StreamController<Position> stream = StreamController<Position>();
    Position? accepted;
    final Future<void> result = selectPrecisePosition(stream.stream,
            timeout: const Duration(milliseconds: 150))
        .then((Position position) => accepted = position);
    stream.add(samplePosition(accuracy: 179));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(accepted?.accuracy, 179);
    await result;
    expect(accepted?.accuracy, 179);
    await stream.close();
  });

  test('position over 1km is rejected at the deadline', () async {
    final StreamController<Position> stream = StreamController<Position>();
    final Future<void> assertion = expectLater(
      selectPrecisePosition(stream.stream,
          timeout: const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>().having(
        (TimeoutException error) => error.message,
        'reason',
        contains('最佳估计误差 1001 米'),
      )),
    );
    stream.add(samplePosition(accuracy: 1001));
    await assertion;
    await stream.close();
  });

  testWidgets(
      'initial loading hides manual location switches and falls back automatically',
      (WidgetTester tester) async {
    final Completer<Position> gps = Completer<Position>();
    int reverseCalls = 0;
    await pumpPage(
        tester,
        LocationList(
          permissionRequester: () async => PermissionStatus.granted,
          positionLoader: () => gps.future,
          locationLookup: (double lat, double lon,
              {required bool isMocked}) async {
            reverseCalls++;
            return const LocationLookupResult(
                address: '旧地址', communities: <NearbyCommunity>[]);
          },
          ipLocationLookup: () async => ipResult,
        ));
    expect(find.textContaining('正在获取当前位置'), findsOneWidget);
    expect(find.text('GPS定位'), findsNothing);
    expect(find.text('IP定位'), findsNothing);
    gps.completeError(const PositionUpdateException('unavailable'));
    await tester.pumpAndSettle();
    expect(find.textContaining('测试城市'), findsOneWidget);
    expect(reverseCalls, 0);
    expect(find.text('旧地址'), findsNothing);
    await finishPage(tester);
  });

  for (final (Object, String) failure in <(Object, String)>[
    (const PositionUpdateException('unavailable'), '浏览器或系统无法提供位置'),
    (TimeoutException('provider timeout'), '设备定位等待超时'),
    (const PermissionDeniedException('denied'), '设备定位权限被拒绝'),
  ]) {
    testWidgets('IP fallback stays automatic: ${failure.$2}',
        (WidgetTester tester) async {
      await pumpPage(
          tester,
          LocationList(
            permissionRequester: () async => PermissionStatus.granted,
            positionLoader: () async => throw failure.$1,
            ipLocationLookup: () async => ipResult,
          ));
      await tester.pump(const Duration(seconds: 4));
      expect(find.textContaining(failure.$2), findsNothing);
      expect(find.textContaining('测试城市'), findsOneWidget);
      await finishPage(tester);
    });
  }

  testWidgets('map failure can be retried without a visible source label',
      (WidgetTester tester) async {
    int lookups = 0;
    int ipCalls = 0;
    await pumpPage(
        tester,
        LocationList(
          permissionRequester: () async => PermissionStatus.granted,
          positionLoader: () async => samplePosition(),
          locationLookup: (double lat, double lon,
              {required bool isMocked}) async {
            if (++lookups == 1) throw const NetworkException('连接超时');
            return const LocationLookupResult(
                address: '设备位置查询成功', communities: <NearbyCommunity>[]);
          },
          ipLocationLookup: () async {
            ipCalls++;
            return ipResult;
          },
        ));
    await tester.pump(const Duration(seconds: 4));
    expect(find.textContaining('附近社区查询失败：连接超时'), findsOneWidget);
    expect(find.textContaining('腾讯地图'), findsNothing);
    expect(ipCalls, 0);
    await tester.tap(find.byKey(const Key('location-retry-button')));
    await tester.pumpAndSettle();
    expect(find.text('设备位置查询成功'), findsOneWidget);
    expect(find.textContaining('附近社区查询失败'), findsNothing);
    await finishPage(tester);
  });

  testWidgets(
      '179m result queries communities without showing positioning details',
      (WidgetTester tester) async {
    int ipCalls = 0;
    await pumpPage(
      tester,
      LocationList(
        permissionRequester: () async => PermissionStatus.granted,
        positionLoader: () async => samplePosition(accuracy: 179),
        locationLookup: (double lat, double lon,
            {required bool isMocked}) async {
          expect(lat, 30);
          expect(lon, 120);
          return const LocationLookupResult(
            address: '设备附近地址',
            communities: <NearbyCommunity>[
              NearbyCommunity(name: '设备附近社区', address: '测试街道'),
            ],
          );
        },
        ipLocationLookup: () async {
          ipCalls++;
          return ipResult;
        },
      ),
    );
    expect(ipCalls, 0);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text('设备附近社区').hitTestable(), findsOneWidget);
    expect(find.textContaining('估计误差'), findsNothing);
    expect(find.byKey(const Key('location-fallback-reason')), findsNothing);
    expect(find.byKey(const Key('gps-location-button')), findsNothing);
    expect(find.byKey(const Key('ip-location-button')), findsNothing);
    await finishPage(tester);
  });

  testWidgets(
      'stalled map lookup exits skeleton, keeps error and permits retry',
      (WidgetTester tester) async {
    final Completer<LocationLookupResult> pending =
        Completer<LocationLookupResult>();
    int calls = 0;
    await pumpPage(
        tester,
        LocationList(
          permissionRequester: () async => PermissionStatus.denied,
          ipLocationLookup: () =>
              ++calls == 1 ? pending.future : Future.value(ipResult),
        ));
    await tester.pump(const Duration(seconds: 21));
    await tester.pump();
    expect(find.byKey(const Key('location-skeleton')), findsNothing);
    expect(find.text('定位失败，请重试'), findsOneWidget);
    await tester.tap(find.byKey(const Key('location-retry-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('测试城市'), findsOneWidget);
    pending.complete(const LocationLookupResult(
        address: '迟到地址', communities: <NearbyCommunity>[]));
    await tester.pumpAndSettle();
    expect(find.text('迟到地址'), findsNothing);
    await finishPage(tester);
  });

  test('shared interface parses the OHOS position payload', () {
    final Position position = samplePosition();
    expect(position.latitude, 30);
    expect(position.longitude, 120);
    expect(position.isMocked, isTrue);
    expect(position.altitudeAccuracy, 0);
    expect(position.headingAccuracy, 0);
  });

  test('position stream ignores stale samples and cancels after fresh fix',
      () async {
    bool cancelled = false;
    final StreamController<Position> stream = StreamController<Position>(
      onCancel: () => cancelled = true,
    );
    final Future<Position> result = selectPrecisePosition(stream.stream);
    stream
      ..add(samplePosition(
          timestamp: DateTime.now().subtract(const Duration(minutes: 5))))
      ..add(samplePosition(accuracy: 8));
    expect((await result).accuracy, 8);
    expect(cancelled, isTrue);
    await stream.close();
  });

  test('invalid accuracy is not accepted as a fallback location', () async {
    final StreamController<Position> stream = StreamController<Position>();
    final Future<Position> result = selectPrecisePosition(
      stream.stream,
      timeout: const Duration(milliseconds: 20),
    );
    stream.add(samplePosition(accuracy: 0));
    await stream.close();
    await expectLater(result, throwsA(isA<TimeoutException>()));
  });

  for (final PermissionStatus status in <PermissionStatus>[
    PermissionStatus.denied,
    PermissionStatus.permanentlyDenied,
  ]) {
    testWidgets('$status uses IP fallback without reading GPS',
        (WidgetTester tester) async {
      int gpsCalls = 0;
      int ipCalls = 0;
      await pumpPage(
        tester,
        LocationList(
          permissionRequester: () async => status,
          positionLoader: () async {
            gpsCalls++;
            return samplePosition();
          },
          ipLocationLookup: () async {
            ipCalls++;
            return ipResult;
          },
        ),
      );
      expect(gpsCalls, 0);
      expect(ipCalls, 1);
      expect(find.textContaining('测试城市'), findsOneWidget);
      await finishPage(tester);
    });
  }

  testWidgets('permission timeout finishes loading with IP fallback',
      (WidgetTester tester) async {
    await pumpPage(
      tester,
      LocationList(
        permissionRequester: () => Completer<PermissionStatus>().future,
        permissionRequestTimeout: const Duration(milliseconds: 10),
        ipLocationLookup: () async => ipResult,
      ),
    );
    expect(find.textContaining('测试城市'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await finishPage(tester);
  });

  testWidgets('granted permission forwards mocked fix to lookup',
      (WidgetTester tester) async {
    bool? mocked;
    await pumpPage(
      tester,
      LocationList(
        permissionRequester: () async => PermissionStatus.granted,
        positionLoader: () async => samplePosition(),
        locationLookup: (double lat, double lon,
            {required bool isMocked}) async {
          expect(lat, 30);
          expect(lon, 120);
          mocked = isMocked;
          return const LocationLookupResult(
            address: '测试精确位置',
            communities: <NearbyCommunity>[],
          );
        },
      ),
    );
    expect(mocked, isTrue);
    expect(find.text('测试精确位置'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('leaving during GPS failure does not start IP or show late error',
      (WidgetTester tester) async {
    final Completer<Position> gps = Completer<Position>();
    int ipCalls = 0;
    await pumpPage(tester, const Scaffold(body: Text('原页面')));
    unawaited(GlobalVariable.navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LocationList(
          permissionRequester: () async => PermissionStatus.granted,
          positionLoader: () => gps.future,
          ipLocationLookup: () async {
            ipCalls++;
            throw const FormatException('迟到的定位错误');
          },
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    GlobalVariable.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(LocationList), findsNothing);
    gps.completeError(const FormatException('迟到的定位错误'));
    await tester.pump();
    expect(ipCalls, 0);
    expect(find.text('迟到的定位错误'), findsNothing);
    expect(tester.takeException(), isNull);
    await finishPage(tester);
  });
}
