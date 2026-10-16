import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:haven_hub/controller/build_controller.dart';
import 'package:haven_hub/models/building_info.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/pages/house/house_form.dart';
import 'package:haven_hub/pages/room/room_list.dart';
import 'package:haven_hub/utils/floor.dart';

import 'helpers/widget_harness.dart';

final Finder _floorField = find.descendant(
  of: find.byKey(const Key('floor-dropdown')),
  matching: find.byType(TextField),
);
final Finder _roomField = find.descendant(
    of: find.byKey(const Key('room-number-input')),
    matching: find.byType(TextField));
final Finder _next = find.widgetWithText(ElevatedButton, '下一步，填写业主信息');

void main() {
  setUp(Get.reset);
  tearDown(Get.reset);

  testWidgets(
      'room options expand in batches and custom prefixed room saves without duplication',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final BuildController controller = BuildController.instance()
      ..updateBuildingInfo(<String, dynamic>{'name': '测试小区'})
      ..updateBuild('A座')
      ..updateRoom('', floor: '16');
    House? selected;
    await pumpPage(tester, const RoomList(), routes: <String, WidgetBuilder>{
      HouseForm.routeName: (_) {
        selected = createHouseFormData(controller);
        return const Scaffold(body: Text('业主表单'));
      },
    });
    final Finder prefix = find.descendant(
        of: find.byKey(const Key('room-prefix-input')),
        matching: find.byType(TextField));
    List<DropdownMenuEntry<String>> options() => tester
        .widget<DropdownMenu<String>>(
            find.byKey(const Key('room-number-input')))
        .dropdownMenuEntries;
    expect(options().length, 20);
    await tester.tap(find.byKey(const Key('more-room-options')));
    await tester.pumpAndSettle();
    expect(options().length, 40);
    expect(options().last.value, '1640');
    await tester.tap(find.text('填写房号'));
    await tester.pumpAndSettle();
    await tester.tap(prefix);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'A').hitTestable());
    await tester.pumpAndSettle();
    expect(options().first.value, 'A1601');
    await tester.enterText(_roomField, '1632');
    await tester.pumpAndSettle();
    await tester
        .tap(find.widgetWithText(MenuItemButton, 'A1632').hitTestable());
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_roomField).controller?.text, 'A1632');
    await tester.enterText(prefix, 'b');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_roomField).controller?.text, 'B1632');
    await tester.enterText(prefix, '');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_roomField).controller?.text, '1632');
    await tester.enterText(prefix, 'aa');
    await tester.pumpAndSettle();
    await tester.tap(find.text('填写房号'));
    await tester.pumpAndSettle();
    await tester.enterText(_roomField, 'AA1699');
    await tester.pumpAndSettle();
    final Finder custom =
        find.widgetWithText(MenuItemButton, '使用房号 AA1699').hitTestable();
    expect(custom, findsOneWidget);
    await tester.tap(custom);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_roomField).controller?.text, 'AA1699');
    await tester.tap(_next);
    await tester.pumpAndSettle();
    expect(selected?.room, 'AA1699');
    expect(selected?.floor, '16');
    await finishPage(tester);
  });

  testWidgets('room dropdown filters below the field and saves selected room',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final BuildController controller = BuildController.instance()
      ..updateBuildingInfo(<String, dynamic>{'name': '测试小区'})
      ..updateBuild('A座');
    House? selected;
    await pumpPage(tester, const RoomList(), routes: <String, WidgetBuilder>{
      HouseForm.routeName: (_) {
        selected = createHouseFormData(controller);
        return const Scaffold(body: Text('业主表单'));
      },
    });
    expect(tester.widget<TextField>(_roomField).controller?.text, isEmpty);
    await tester.enterText(_floorField, '63');
    await tester.pumpAndSettle();
    await tester.tap(find.text('填写房号'));
    await tester.pumpAndSettle();
    await tester.tap(_roomField);
    await tester.enterText(_roomField, '6302');
    await tester.pumpAndSettle();
    final Finder option =
        find.widgetWithText(MenuItemButton, '6302').hitTestable();
    expect(option, findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, '6301').hitTestable(),
        findsNothing);
    expect(tester.getTopLeft(option).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(_roomField).dy));
    expect(tester.getTopRight(option).dx, lessThanOrEqualTo(390));
    await tester.tap(option);
    await tester.pumpAndSettle();
    await tester.tap(_next);
    await tester.pumpAndSettle();
    expect(selected?.floor, '63');
    expect(selected?.room, '6302');
    await finishPage(tester);
  });

  testWidgets(
      'floor changes clear selected suggestions but preserve custom room input',
      (WidgetTester tester) async {
    BuildController.instance()
      ..updateBuildingInfo(<String, dynamic>{'name': '测试小区'})
      ..updateBuild('A座');
    await pumpPage(tester, const RoomList());
    await tester.enterText(_floorField, '16');
    await tester.pumpAndSettle();
    await tester.tap(find.text('填写房号'));
    await tester.pumpAndSettle();
    await tester.tap(_roomField);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '1602').hitTestable());
    await tester.pumpAndSettle();
    await tester.enterText(_floorField, '17');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_roomField).controller?.text, isEmpty);
    expect(tester.widget<ElevatedButton>(_next).onPressed, isNull);
    expect(
        tester
            .widget<DropdownMenu<String>>(
                find.byKey(const Key('room-number-input')))
            .dropdownMenuEntries
            .first
            .value,
        '1701');
    await tester.enterText(_roomField, 'B-302');
    await tester.enterText(_floorField, 'B1');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_roomField).controller?.text, 'B-302');
    await tester.enterText(_floorField, '');
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<DropdownMenu<String>>(
                find.byKey(const Key('room-number-input')))
            .dropdownMenuEntries
            .first
            .value,
        '01');
    expect(tester.widget<TextField>(_roomField).controller?.text, 'B-302');
    await finishPage(tester);
  });

  test('floor formats, serialization and old records stay compatible', () {
    for (final String value in <String>[
      '',
      '33',
      '63层',
      '100',
      '9999',
      'b1',
      '地下2层'
    ]) {
      expect(validateFloor(value), isNull, reason: value);
    }
    for (final String value in <String>[
      '0',
      '-1',
      '01',
      '3.5',
      'abc',
      'B0',
      'B100',
      '10000'
    ]) {
      expect(validateFloor(value), isNotNull, reason: value);
    }
    const BuildingInfo info =
        BuildingInfo(name: '小区', building: '1栋', floor: '63', room: '6301');
    expect(BuildingInfo.fromJson(info.toJson()), info);
    final House house = House.fromJson(<String, dynamic>{
      'point': '小区',
      'building': '1栋',
      'floor': '63',
      'room': '6301'
    });
    expect(house.fullName, '小区 1栋 63层 6301');
    expect(house.toJson()['floor'], '63');
    expect(house.copyWith(floor: 'B1').roomLabel, '1栋 地下1层 6301');
    final House oldHouse =
        House.fromJson(<String, dynamic>{'building': '1栋', 'room': '101'});
    expect(oldHouse.floor, isEmpty);
    expect(oldHouse.roomLabel, '1栋101');
    expect(oldHouse.toJson().containsKey('floor'), isFalse);
  });

  for (final String floor in <String>['', '100', 'b1', '地下2层']) {
    testWidgets('manual floor "$floor" reaches the registration form unchanged',
        (WidgetTester tester) async {
      final BuildController controller = BuildController.instance()
        ..updateBuildingInfo(<String, dynamic>{'name': '测试小区'})
        ..updateBuild('A座');
      House? selected;
      await pumpPage(tester, const RoomList(), routes: <String, WidgetBuilder>{
        HouseForm.routeName: (_) {
          selected = createHouseFormData(controller);
          return const Scaffold(body: Text('业主表单'));
        },
      });
      await tester.enterText(_floorField, floor);
      await tester.enterText(_roomField, '原样门牌A-01');
      await tester.pumpAndSettle();
      await tester.tap(find.text('填写房号'));
      await tester.pumpAndSettle();
      await tester.tap(_next);
      await tester.pumpAndSettle();
      expect(find.text('业主表单'), findsOneWidget);
      expect(selected?.floor, normalizeFloor(floor));
      expect(selected?.room, '原样门牌A-01');
      await finishPage(tester);
    });
  }

  testWidgets(
      'floor menu filters below the input on a narrow screen and selection saves 63',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final BuildController controller = BuildController.instance()
      ..updateBuildingInfo(<String, dynamic>{'name': '测试小区'})
      ..updateBuild('A座');
    House? selected;
    await pumpPage(tester, const RoomList(), routes: <String, WidgetBuilder>{
      HouseForm.routeName: (_) {
        selected = createHouseFormData(controller);
        return const Scaffold(body: Text('业主表单'));
      },
    });
    await tester.tap(_floorField);
    await tester.enterText(_floorField, '63');
    await tester.pumpAndSettle();
    final Finder option =
        find.widgetWithText(MenuItemButton, '63层').hitTestable();
    expect(option, findsOneWidget);
    expect(
        find.widgetWithText(MenuItemButton, '33层').hitTestable(), findsNothing);
    final Rect inputRect = tester.getRect(_floorField);
    final Rect optionRect = tester.getRect(option);
    expect(optionRect.top, greaterThanOrEqualTo(inputRect.bottom));
    expect(optionRect.right, lessThanOrEqualTo(390));
    await tester.tap(option);
    await tester.enterText(_roomField, '6301');
    await tester.pumpAndSettle();
    await tester.tap(find.text('填写房号'));
    await tester.pumpAndSettle();
    await tester.tap(_next);
    await tester.pumpAndSettle();
    expect(selected?.floor, '63');
    expect(selected?.fullName, '测试小区 A座 63层 6301');
    await finishPage(tester);
  });

  testWidgets(
      'invalid floor immediately shows an inline error and cannot navigate',
      (WidgetTester tester) async {
    final BuildController controller = BuildController.instance()
      ..updateBuildingInfo(<String, dynamic>{'name': '测试小区'})
      ..updateBuild('A座');
    await pumpPage(tester, const RoomList());
    await tester.enterText(_roomField, '101');
    for (final String value in <String>['0', 'abc']) {
      await tester.enterText(_floorField, value);
      await tester.pump();
      expect(tester.widget<TextField>(_floorField).decoration?.errorText,
          isNotNull);
      expect(tester.widget<ElevatedButton>(_next).onPressed, isNull);
      await tester.tap(find.text('填写房号'));
      await tester.pumpAndSettle();
      await tester.tap(_roomField);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(controller.room, isEmpty);
    }
    await tester.enterText(_floorField, '33');
    await tester.pump();
    expect(tester.widget<TextField>(_floorField).decoration?.errorText, isNull);
    expect(tester.widget<ElevatedButton>(_next).onPressed, isNotNull);
    await finishPage(tester);
  });
}
