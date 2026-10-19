import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:haven_hub/api/location.dart';
import 'package:haven_hub/controller/build_controller.dart';
import 'package:haven_hub/models/device_map_location.dart';
import 'package:haven_hub/pages/building/building_list.dart';
import 'package:haven_hub/pages/room/room_list.dart';
import 'package:haven_hub/utils/building_recommendations.dart';

import 'helpers/widget_harness.dart';
import 'tencent_building_test.dart' as fixtures;

TencentBuilding building(String id, double? lat, double? lon) =>
    TencentBuilding(
        id: id,
        name: '榴苑三街小区-$id座',
        address: '榴苑三街',
        label: '$id座',
        latitude: lat,
        longitude: lon);

DeviceMapLocation fix(DateTime now, {double accuracy = 5}) => DeviceMapLocation(
    latitude: 23.007933,
    longitude: 113.090276,
    accuracy: accuracy,
    timestamp: now);

void main() {
  setUp(Get.reset);
  tearDown(Get.reset);

  test('both providers retain building coordinates with correct axis order',
      () {
    final TencentBuilding tencent = parseTencentCommunityBuildings(
            fixtures.response(<dynamic>[
              <String, dynamic>{
                ...fixtures.poi('3', '榴苑三街小区-3座'),
                'location': <String, dynamic>{'lat': 23.0079, 'lng': 113.0902}
              },
            ]),
            fixtures.community,
            1)
        .buildings
        .single;
    expect(tencent.latitude, 23.0079);
    expect(tencent.longitude, 113.0902);
    final TencentBuilding amap = parseAmapCommunityBuildings(<String, dynamic>{
      'status': '1',
      'pois': <dynamic>[
        <String, dynamic>{
          'id': '3',
          'name': '榴苑三街小区-3座',
          'address': '榴苑三街',
          'location': '113.0902,23.0079'
        },
      ],
    }, fixtures.community, 1)
        .buildings
        .single;
    expect(amap.latitude, tencent.latitude);
    expect(amap.longitude, tencent.longitude);
  });

  test('merge uses supplemental coordinates when primary label lacks them',
      () async {
    final TencentBuildingPage result = await searchCommunityBuildings(
      fixtures.community,
      1,
      tencentKey: 'test',
      amapKey: 'test',
      tencentGet: (_, {params}) async =>
          fixtures.response(<dynamic>[fixtures.poi('3', '榴苑三街小区-3座')]),
      amapGet: (_, {params}) async => <String, dynamic>{
        'status': '1',
        'pois': <dynamic>[
          <String, dynamic>{
            'id': '3',
            'name': '榴苑三街小区-3座',
            'address': '榴苑三街',
            'location': '113.090276,23.007933'
          },
        ]
      },
    );
    expect(result.buildings, hasLength(1));
    expect(result.buildings.single.latitude, 23.007933);
  });

  test('rank nearby buildings only, exclude missing invalid and distant points',
      () {
    final DateTime now = DateTime(2026, 10, 18);
    final List<TencentBuilding> buildings = <TencentBuilding>[
      building('far', 24, 114),
      building('2', 23.0082, 113.090276),
      building('missing', null, null),
      building('1', 23.007933, 113.090276),
      building('invalid', double.nan, 999),
      building('3', 23.0084, 113.090276),
      building('4', 23.0085, 113.090276),
      building('zero', 0, 0),
    ];
    final List<NearbyBuilding> result =
        recommendBuildings(buildings, fix(now), now: now);
    expect(result.map((e) => e.building.id), <String>['1', '2', '3']);
    expect(result[0].distance, 0);
    expect(result[1].distance, closeTo(29.7, 1));
    expect(recommendBuildings(buildings, null, now: now), isEmpty);
    for (final double accuracy in <double>[
      0,
      -1,
      51,
      double.nan,
      double.infinity
    ]) {
      expect(
          recommendBuildings(buildings, fix(now, accuracy: accuracy), now: now),
          isEmpty);
    }
    expect(
        recommendBuildings(buildings, fix(now),
            now: now.add(const Duration(minutes: 6))),
        isEmpty);
    expect(
        recommendBuildings(buildings, fix(now.add(const Duration(minutes: 1))),
            now: now),
        isEmpty);
  });

  testWidgets(
      'recommendation requires confirmation and carries actual label to room page',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final BuildController controller = BuildController.instance()
      ..updateBuildingInfo(fixtures.community.toJson());
    final TencentBuilding nearest = building('3', 23.007933, 113.090276);
    await pumpPage(
        tester,
        BuildingList(
          deviceLocation: fix(DateTime.now()),
          buildingLookup: (_, __) async => TencentBuildingPage(
              buildings: <TencentBuilding>[nearest],
              poiIds: <String>[nearest.id]),
        ),
        routes: <String, WidgetBuilder>{
          RoomList.routeName: (_) => const RoomList()
        });
    expect(find.text('附近楼栋推荐'), findsOneWidget);
    expect(controller.build, isEmpty);
    expect(find.text('填写房号'), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('confirm-building-3')));
    await tester.pumpAndSettle();
    expect(controller.build, '3座');
    expect(find.text('填写房号'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets(
      'late recommendation does not overwrite manual input; disposal cancels timer',
      (tester) async {
    BuildController.instance().updateBuildingInfo(fixtures.community.toJson());
    final Completer<TencentBuildingPage> pending =
        Completer<TencentBuildingPage>();
    await tester.pumpWidget(MaterialApp(
        home: BuildingList(
            deviceLocation: fix(DateTime.now()),
            buildingLookup: (_, __) => pending.future)));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '12座2单元');
    pending.complete(TencentBuildingPage(
        buildings: <TencentBuilding>[building('3', 23.007933, 113.090276)],
        poiIds: const <String>['3']));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '12座2单元');
    await finishPage(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'coarse location leaves manual entry available without recommendations',
      (tester) async {
    BuildController.instance().updateBuildingInfo(fixtures.community.toJson());
    await pumpPage(
        tester,
        BuildingList(
          deviceLocation: fix(DateTime.now(), accuracy: 179),
          buildingLookup: (_, __) async => TencentBuildingPage(
              buildings: <TencentBuilding>[
                building('3', 23.007933, 113.090276)
              ],
              poiIds: const <String>[
                '3'
              ]),
        ));
    expect(find.text('附近楼栋推荐'), findsNothing);
    expect(find.textContaining('当前定位精度不足'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    await finishPage(tester);
  });
}
