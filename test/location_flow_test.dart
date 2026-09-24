import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:haven_hub/api/location.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/pages/location/location_list.dart';
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
