import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:haven_hub/api/location.dart';
import 'package:haven_hub/controller/build_controller.dart';
import 'package:haven_hub/models/building_info.dart';
import 'package:haven_hub/pages/building/building_list.dart';
import 'package:haven_hub/pages/room/room_list.dart';
import 'package:haven_hub/utils/app_exception.dart';

import 'helpers/widget_harness.dart';

const TencentBuilding mappedBuilding = TencentBuilding(
  id: 'actual-13',
  name: '榴苑三街小区-13座',
  address: '佛山市榴苑三街16号榴苑三街小区',
  label: '13座',
);

const TencentBuildingPage mappedPage = TencentBuildingPage(
  buildings: <TencentBuilding>[mappedBuilding],
  poiIds: <String>['actual-13'],
);

BuildController selectCommunity() => BuildController.instance()
  ..updateBuildingInfo(<String, dynamic>{
    'name': '榴苑三街小区',
    'address': '佛山市榴苑三街16号',
    'communityId': 'community',
    'latitude': 23.007933,
    'longitude': 113.090276,
  });

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 250,
      scrollable: find.byType(Scrollable).first);
  await tester.pump();
}

void main() {
  setUp(Get.reset);
  tearDown(Get.reset);

  for (final Size size in <Size>[const Size(390, 844), const Size(1864, 900)]) {
    testWidgets(
        'building dropdown filters below its field at ${size.width} width',
        (WidgetTester tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final BuildController controller = selectCommunity();
      await pumpPage(
          tester,
          BuildingList(
            buildingLookup: (BuildingInfo info, int page) async =>
                const TencentBuildingPage(
              buildings: <TencentBuilding>[
                mappedBuilding,
                TencentBuilding(
                    id: 'actual-7',
                    name: '榴苑三街小区-7座',
                    address: '另一条路',
                    label: '7座')
              ],
              poiIds: <String>['actual-13', 'actual-7'],
            ),
          ),
          routes: <String, WidgetBuilder>{
            RoomList.routeName: (_) => const RoomList()
          });
      final Finder field = find.byType(TextField);
      expect(find.byType(ListTile), findsNothing);
      await tester.tap(field);
      await tester.pumpAndSettle();
      final Finder first = find
          .widgetWithText(MenuItemButton, mappedBuilding.name)
          .hitTestable();
      expect(first, findsOneWidget);
      expect(find.widgetWithText(MenuItemButton, '榴苑三街小区-7座').hitTestable(),
          findsOneWidget);
      final Rect input = tester.getRect(field);
      final Rect option = tester.getRect(first);
      expect(option.top, greaterThanOrEqualTo(input.bottom));
      expect(option.left, greaterThanOrEqualTo(input.left));
      expect(option.right, lessThanOrEqualTo(input.right + 1));
      await tester.enterText(field, '16号');
      await tester.pumpAndSettle();
      expect(first, findsOneWidget, reason: '地址也可用于筛选');
      expect(find.widgetWithText(MenuItemButton, '榴苑三街小区-7座').hitTestable(),
          findsNothing);
      await tester.enterText(field, '13');
      await tester.pumpAndSettle();
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller?.text, '13座');
      await tester.enterText(field, '99栋2单元');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的楼栋，可直接填写').hitTestable(), findsOneWidget);
      await tester.tap(find.text('选择或填写楼栋'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步，填写房号'));
      await tester.pumpAndSettle();
      expect(controller.build, '99栋2单元');
      expect(find.text('填写房号'), findsOneWidget);
      await finishPage(tester);
    });
  }

  testWidgets(
      'selecting Tencent result fills its actual label and reaches rooms',
      (WidgetTester tester) async {
    final BuildController controller = selectCommunity();
    await pumpPage(
      tester,
      BuildingList(buildingLookup: (BuildingInfo info, int page) async {
        expect(info.latitude, 23.007933);
        expect(info.communityId, 'community');
        return mappedPage;
      }),
      routes: <String, WidgetBuilder>{
        RoomList.routeName: (_) => const RoomList(),
      },
    );
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('地图收录的楼栋及单元'), findsNothing);
    expect(find.text('已加载 1 个楼栋及单元'), findsOneWidget);
    final Finder completed = find.text('没有更多结果了，未找到的楼栋或单元可直接填写。');
    expect(completed, findsOneWidget);
    expect(tester.getBottomLeft(completed).dy,
        lessThan(tester.getTopLeft(find.byType(TextField)).dy));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    final Finder item =
        find.widgetWithText(MenuItemButton, mappedBuilding.name).hitTestable();
    expect(find.text(mappedBuilding.address), findsOneWidget);
    expect(find.textContaining('来源：'), findsNothing);
    await tester.tap(item);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '13座');
    await tester.enterText(find.byType(TextField), '13座2单元');
    await tester.pump();
    await tester.tap(find.text('选择或填写楼栋'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步，填写房号'));
    await tester.pumpAndSettle();
    expect(controller.build, '13座2单元');
    expect(find.text('填写房号'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('map business failure can retry; manual input is preserved',
      (WidgetTester tester) async {
    selectCommunity();
    int calls = 0;
    await pumpPage(tester,
        BuildingList(buildingLookup: (BuildingInfo info, int page) async {
      calls++;
      if (calls == 1) throw const BusinessException('地图配额不足');
      expect(page, 1);
      return mappedPage;
    }));
    await tester.enterText(find.byType(TextField), 'B座3单元');
    await tester.pump();
    await tester.tap(find.text('选择或填写楼栋'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('重试查询'));
    expect(find.text('楼栋查询失败：地图配额不足'), findsOneWidget);
    await tester.tap(find.text('重试查询'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(
        tester
            .widget<DropdownMenu<String>>(
                find.byKey(const Key('building-dropdown')))
            .dropdownMenuEntries
            .single
            .value,
        mappedBuilding.label);
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'B座3单元');
    await finishPage(tester);
  });

  testWidgets('empty response is distinct from network failure',
      (WidgetTester tester) async {
    selectCommunity();
    await pumpPage(tester,
        BuildingList(buildingLookup: (BuildingInfo info, int page) async {
      return const TencentBuildingPage(
          buildings: <TencentBuilding>[], poiIds: <String>[]);
    }));
    await reveal(tester, find.textContaining('本次查询未找到匹配楼栋'));
    expect(find.text('重试查询'), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    await finishPage(tester);

    selectCommunity();
    await pumpPage(tester,
        BuildingList(buildingLookup: (BuildingInfo info, int page) async {
      throw const NetworkException('连接超时', isTimeout: true);
    }));
    await reveal(tester, find.text('重试查询'));
    expect(find.text('楼栋查询失败：连接超时'), findsOneWidget);
    expect(find.textContaining('本次查询未找到匹配楼栋'), findsNothing);
    await finishPage(tester);
  });

  testWidgets(
      'loading more locks requests, deduplicates and stops repeated page',
      (WidgetTester tester) async {
    selectCommunity();
    final Completer<TencentBuildingPage> pending =
        Completer<TencentBuildingPage>();
    int calls = 0;
    await pumpPage(tester,
        BuildingList(buildingLookup: (BuildingInfo info, int page) async {
      calls++;
      if (page == 1) {
        return const TencentBuildingPage(
          buildings: <TencentBuilding>[mappedBuilding],
          poiIds: <String>['actual-13'],
          hasMore: true,
        );
      }
      return pending.future;
    }));
    await reveal(tester, find.text('加载更多地图结果'));
    expect(tester.getBottomLeft(find.text('加载更多地图结果')).dy,
        lessThan(tester.getTopLeft(find.byType(TextField)).dy));
    await tester.tap(find.text('加载更多地图结果'));
    await tester.tap(find.text('加载更多地图结果'));
    await tester.pump();
    expect(calls, 2);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.getBottomLeft(find.byType(LinearProgressIndicator)).dy,
        lessThan(tester.getTopLeft(find.byType(TextField)).dy));
    expect(find.text('加载更多地图结果'), findsNothing);
    pending.complete(const TencentBuildingPage(
      buildings: <TencentBuilding>[mappedBuilding],
      poiIds: <String>['actual-13'],
      hasMore: true,
    ));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<DropdownMenu<String>>(
                find.byKey(const Key('building-dropdown')))
            .dropdownMenuEntries
            .single
            .value,
        mappedBuilding.label);
    expect(find.text('加载更多地图结果'), findsNothing);
    expect(find.text('已加载 1 个楼栋及单元'), findsOneWidget);
    expect(find.text('没有更多结果了，未找到的楼栋或单元可直接填写。'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets(
      'late map response never replaces manual input or touches disposal',
      (WidgetTester tester) async {
    selectCommunity();
    final Completer<TencentBuildingPage> pending =
        Completer<TencentBuildingPage>();
    await tester.pumpWidget(MaterialApp(
      home: BuildingList(
          buildingLookup: (BuildingInfo info, int page) => pending.future),
    ));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '28栋');
    pending.complete(mappedPage);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '28栋');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    final Completer<TencentBuildingPage> disposed =
        Completer<TencentBuildingPage>();
    selectCommunity();
    await tester.pumpWidget(MaterialApp(
      home: BuildingList(
          buildingLookup: (BuildingInfo info, int page) => disposed.future),
    ));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    disposed.complete(mappedPage);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing selected community invalidates pending results',
      (WidgetTester tester) async {
    final BuildController controller = selectCommunity();
    final Completer<TencentBuildingPage> pending =
        Completer<TencentBuildingPage>();
    await tester.pumpWidget(MaterialApp(
      home: BuildingList(
          buildingLookup: (BuildingInfo info, int page) => pending.future),
    ));
    await tester.pump();
    controller.updateBuildingInfo(<String, dynamic>{'name': '其他小区'});
    pending.complete(mappedPage);
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNothing);
    expect(find.textContaining('所选小区已变更'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    await finishPage(tester);
  });
}
