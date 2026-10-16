import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:haven_hub/api/location.dart';
import 'package:haven_hub/controller/build_controller.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/pages/building/building_list.dart';
import 'package:haven_hub/pages/house/house_form.dart';
import 'package:haven_hub/pages/location/location_list.dart';
import 'package:haven_hub/pages/room/room_list.dart';
import 'package:haven_hub/router/app_routes.dart';
import 'package:permission_handler/permission_handler.dart';

import 'helpers/widget_harness.dart';

final Finder roomField = find.descendant(
    of: find.byKey(const Key('room-number-input')),
    matching: find.byType(TextField));

Future<void> advanceRoute(WidgetTester tester) async {
  await tester.pumpAndSettle();
}

void main() {
  setUp(Get.reset);
  tearDown(Get.reset);

  testWidgets('manual address reaches house form without generated inventory',
      (WidgetTester tester) async {
    final BuildController controller = BuildController.instance()
      ..updateBuildingInfo(<String, dynamic>{
        'name': '榴苑三街小区',
        'address': '腾讯返回的地址',
      });
    House? house;
    Object? arguments;
    await pumpPage(tester, const BuildingList(),
        routes: <String, WidgetBuilder>{
          RoomList.routeName: (_) => const RoomList(),
          HouseForm.routeName: (BuildContext context) {
            house = createHouseFormData(controller);
            arguments = ModalRoute.of(context)?.settings.arguments;
            return const Scaffold(body: Text('业主表单'));
          },
        });

    expect(find.text('腾讯返回的地址'), findsOneWidget);
    expect(find.textContaining('可下拉选择或输入搜索'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    final Finder buildingNext = find.widgetWithText(ElevatedButton, '下一步，填写房号');
    expect(tester.widget<ElevatedButton>(buildingNext).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(tester.widget<ElevatedButton>(buildingNext).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '  12栋2单元  ');
    await tester.pump();
    await tester.tap(find.text('选择或填写楼栋'));
    await tester.pumpAndSettle();
    await tester.tap(buildingNext);
    await advanceRoute(tester);
    expect(find.text('填写房号'), findsOneWidget);
    expect(find.textContaining('选项仅供填写参考'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    expect(controller.build, '12栋2单元');
    final Finder roomNext = find.widgetWithText(ElevatedButton, '下一步，填写业主信息');
    expect(tester.widget<ElevatedButton>(roomNext).onPressed, isNull);

    await tester.enterText(roomField, '  B-1602  ');
    await tester.pump();
    await tester.tap(find.text('填写房号'));
    await tester.pumpAndSettle();
    await tester.tap(roomNext);
    await advanceRoute(tester);
    expect(find.text('业主表单'), findsOneWidget);
    expect(house?.point, '榴苑三街小区');
    expect(house?.building, '12栋2单元');
    expect(house?.room, 'B-1602');
    expect((arguments! as HouseFormArguments).isCreate, isTrue);
    await finishPage(tester);
  });

  testWidgets('direct empty house form can return to house selection',
      (WidgetTester tester) async {
    await pumpPage(
      tester,
      const HouseForm(),
      routes: <String, WidgetBuilder>{
        LocationList.routeName: (_) => LocationList(
              permissionRequester: () async => PermissionStatus.denied,
              ipLocationLookup: () async => const LocationLookupResult(
                address: '测试城市',
                isIpBased: true,
                communities: <NearbyCommunity>[
                  NearbyCommunity(name: '测试小区', address: '测试地址'),
                ],
              ),
            ),
        BuildingList.routeName: (_) => const BuildingList(),
        RoomList.routeName: (_) => const RoomList(),
        HouseForm.routeName: (_) => const HouseForm(),
      },
    );

    expect(find.text('未选择房屋'), findsOneWidget);
    expect(find.textContaining('还没有完成小区'), findsNothing);
    await tester.tap(find.text('未选择房屋'));
    await tester.pumpAndSettle();
    expect(find.text('选择社区'), findsOneWidget);
    expect(find.byType(HouseForm), findsNothing);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试小区').hitTestable());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'A座');
    await tester.pump();
    await tester.tap(find.text('选择或填写楼栋'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步，填写房号'));
    await tester.pumpAndSettle();
    await tester.enterText(roomField, '602');
    await tester.pump();
    await tester.tap(find.text('填写房号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步，填写业主信息'));
    await tester.pumpAndSettle();
    expect(find.text('测试小区'), findsOneWidget);
    expect(find.text('A座 602'), findsOneWidget);
    expect(find.text('未选择房屋'), findsNothing);
    await finishPage(tester);
  });

  testWidgets('back preserves room for same building and clears it on change',
      (WidgetTester tester) async {
    final BuildController controller = BuildController.instance()
      ..updateBuildingInfo(<String, dynamic>{'name': '社区3号院'})
      ..updateBuild('A座')
      ..updateRoom('1602', floor: '16');
    await pumpPage(tester, const BuildingList(),
        routes: <String, WidgetBuilder>{
          RoomList.routeName: (_) => const RoomList(),
        });

    await tester.tap(find.text('下一步，填写房号'));
    await advanceRoute(tester);
    expect(tester.widget<TextField>(roomField).controller?.text, '1602');
    expect(controller.buildingInfo.floor, '16');
    expect(
        tester
            .widget<DropdownMenu<String>>(
                find.byKey(const Key('floor-dropdown')))
            .controller
            ?.text,
        '16');
    Navigator.of(tester.element(find.byType(RoomList))).pop();
    await advanceRoute(tester);
    await tester.enterText(find.byType(TextField), '28栋3单元');
    await tester.pump();
    await tester.tap(find.text('选择或填写楼栋'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步，填写房号'));
    await advanceRoute(tester);
    expect(controller.build, '28栋3单元');
    expect(controller.room, isEmpty);
    expect(controller.buildingInfo.floor, isEmpty);
    expect(
        tester
            .widget<DropdownMenu<String>>(
                find.byKey(const Key('floor-dropdown')))
            .controller
            ?.text,
        isEmpty);
    expect(tester.widget<TextField>(roomField).controller?.text, isEmpty);
    await finishPage(tester);
  });

  for (final Widget page in <Widget>[const BuildingList(), const RoomList()]) {
    testWidgets('${page.runtimeType} requires preceding address steps',
        (WidgetTester tester) async {
      BuildController.instance();
      await pumpPage(tester, page);
      for (final TextField field
          in tester.widgetList<TextField>(find.byType(TextField))) {
        expect(field.enabled, isFalse);
      }
      expect(
          tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
          isNull);
      await finishPage(tester);
    });
  }
}
