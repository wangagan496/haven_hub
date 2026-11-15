import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:haven_hub/controller/build_controller.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/models/user_info.dart';
import 'package:haven_hub/pages/house/house_drafts.dart';
import 'package:haven_hub/pages/house/house_form.dart';
import 'package:haven_hub/pages/room/room_list.dart';
import 'package:haven_hub/router/app_routes.dart';
import 'package:haven_hub/utils/house_submission_store.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/widget_harness.dart';

Future<UserInfo> _identity() async => const UserInfo(id: 'house-draft-owner', avatarUrl: '', nickName: '测试');

String _draft(BuildController controller, String community, String room) {
  final id = controller.startDraft();
  controller
    ..selectCommunity(<String, dynamic>{'name': community}, draftId: id)
    ..selectBuilding('1栋', draftId: id)
    ..selectRoom(room, floor: '3', draftId: id);
  return id;
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() async {
    Get.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.loadTokens();
  });
  tearDown(Get.reset);

  test(
      'independent selections and owner details survive switching and scoped resets',
      () {
    final controller = BuildController.instance();
    final a = _draft(controller, '甲小区', '301');
    controller.saveForm(
        a,
        const House(
            name: '甲业主', mobile: '13800138000', idcardFrontUrl: 'front-a'));
    final b = _draft(controller, '乙小区', '302');
    controller
      ..saveForm(b, const House(name: '乙业主', mobile: '13800138001'))
      ..activateDraft(a);
    expect(controller.room, '301');
    expect(controller.houseFor(a).name, '甲业主');
    controller.activateDraft(b);
    expect(controller.room, '302');
    controller.selectBuilding('2栋', draftId: a);
    expect(controller.selectionFor(a).room, isEmpty);
    expect(controller.selectionFor(a).floor, isEmpty);
    expect(controller.room, '302');
    controller.selectCommunity(<String, dynamic>{'name': '丙小区'}, draftId: a);
    expect(controller.selectionFor(a).building, isEmpty);
    expect(controller.houseFor(a).name, '甲业主');
    expect(controller.houseFor(a).point, '丙小区');
    controller.clearSelection(draftId: a);
    expect(controller.draftFor(a), isNull);
    expect(controller.houseFor(b).name, '乙业主');
    controller.selectRoom('旧页面迟到写入', draftId: a);
    expect(controller.drafts.length, 1);
    expect(controller.room, '302');
  });

  test(
      'refresh preserves drafts but logout and account switches clear every draft',
      () async {
    await tokenManager.setToken('draft-account-a');
    final controller = BuildController.instance();
    final a = _draft(controller, '甲小区', '301');
    await tokenManager.setRefreshedToken('refreshed',
        refreshToken: 'refreshed-rt');
    expect(controller.draftFor(a), isNotNull);
    await tokenManager.setToken('draft-account-b');
    expect(controller.drafts, isEmpty);
    final b = _draft(controller, '乙小区', '302');
    await tokenManager.deleteToken();
    expect(controller.draftFor(b), isNull);
    controller.saveForm(a, const House(name: '旧账号'));
    expect(controller.drafts, isEmpty);
  });

  testWidgets(
      'draft screen switches between forms and preserves entered owner information',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = BuildController.instance();
    final a = _draft(controller, '甲小区', '301');
    final b = _draft(controller, '乙小区', '302');
    await pumpPage(tester, const HouseDraftsPage(),
        routes: <String, WidgetBuilder>{
          houseDrafts: (_) => const HouseDraftsPage(),
          houseForm: (_) => HouseForm(userInfoLoader: _identity, submissionStore: HouseSubmissionStore()),
        });
    await tester.tap(find.text('甲小区'));
    await _frames(tester);
    await tester.enterText(find.byType(TextFormField).first, '张三');
    await tester.enterText(find.byType(TextFormField).at(1), '13800138000');
    await tester.tap(find.byTooltip('切换选房草稿'));
    await _frames(tester);
    await tester.tap(find.text('乙小区'));
    await _frames(tester);
    expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        isEmpty);
    await tester.enterText(find.byType(TextFormField).first, '李四');
    await tester.tap(find.byTooltip('切换选房草稿'));
    await _frames(tester);
    await tester.tap(find.text('甲小区'));
    await _frames(tester);
    expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        '张三');
    expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).at(1))
            .controller!
            .text,
        '13800138000');
    expect(controller.houseFor(b).name, '李四');
    expect(controller.houseFor(a).room, '301');
    await finishPage(tester);
  });

  testWidgets(
      'submitting one draft clears only that draft and preserves the other',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = BuildController.instance();
    final a = _draft(controller, '甲小区', '301');
    final b = _draft(controller, '乙小区', '302');
    controller.saveForm(
        a,
        const House(
            name: '张三',
            mobile: '13800138000',
            idcardFrontUrl: 'https://example.com/front.png',
            idcardBackUrl: 'https://example.com/back.png'));
    House? submitted;
    await pumpPage(tester, const HouseDraftsPage(),
        routes: <String, WidgetBuilder>{
          houseForm: (_) => HouseForm(userInfoLoader: _identity, submissionStore: HouseSubmissionStore(), submitHouseLoader: (house) async {
                submitted = house;
              }),
          houseList: (_) => const Scaffold(body: Text('提交后的房屋列表')),
        });
    await tester.tap(find.text('甲小区'));
    await _frames(tester);
    await tester.tap(find.text('提交审核'));
    await _frames(tester);
    expect(submitted?.point, '甲小区');
    expect(submitted?.room, '301');
    expect(controller.draftFor(a), isNull);
    expect(controller.draftFor(b), isNotNull);
    expect(find.text('提交后的房屋列表'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('discarding a draft through its menu preserves the other draft',
      (tester) async {
    final controller = BuildController.instance();
    final a = _draft(controller, '甲小区', '301');
    final b = _draft(controller, '乙小区', '302');
    await pumpPage(tester, const HouseDraftsPage());
    await tester.tap(find.byTooltip('草稿操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃草稿'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();
    expect(controller.draftFor(a), isNull);
    expect(controller.draftFor(b), isNotNull);
    expect(find.text('乙小区'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets(
      'typed room inputs survive reopening and stay bound to their draft',
      (tester) async {
    final controller = BuildController.instance();
    final a = _draft(controller, '甲小区', '301');
    final b = _draft(controller, '乙小区', '302');
    final roomField = find.descendant(
        of: find.byKey(const Key('room-number-input')),
        matching: find.byType(TextField));
    await pumpPage(tester, RoomList(draftId: a), routes: <String, WidgetBuilder>{
      houseDrafts: (_) => const HouseDraftsPage(),
      roomList: (context) => RoomList(draftId: (ModalRoute.of(context)!.settings.arguments! as HouseSelectionArguments).draftId),
    });
    await tester.enterText(roomField, '新房号');
    await tester.tap(find.byTooltip('切换选房草稿'));
    await _frames(tester);
    await tester.tap(find.text('甲小区'));
    await _frames(tester);
    expect(tester.widget<TextField>(roomField).controller!.text, '新房号');
    expect(controller.houseFor(b).room, '302');
    await finishPage(tester);
  });

  testWidgets(
      'account change hides the old form and ignores late submission completion',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = BuildController.instance();
    final a = _draft(controller, '甲小区', '301');
    controller.saveForm(
        a,
        const House(
            name: '张三',
            mobile: '13800138000',
            idcardFrontUrl: 'https://example.com/front.png',
            idcardBackUrl: 'https://example.com/back.png'));
    final done = Completer<void>();
    await pumpPage(tester, const HouseDraftsPage(),
        routes: <String, WidgetBuilder>{
          houseForm: (_) => HouseForm(userInfoLoader: _identity, submissionStore: HouseSubmissionStore(), submitHouseLoader: (_) => done.future),
          houseList: (_) => const Scaffold(body: Text('不应跳转到列表')),
        });
    await tester.tap(find.text('甲小区'));
    await _frames(tester);
    await tester.tap(find.text('提交审核'));
    await tester.pump();
    tokenManager.invalidateLocalSession();
    final b = _draft(controller, '新账号小区', '999');
    done.complete();
    await _frames(tester);
    expect(find.text('甲小区'), findsNothing);
    expect(find.text('张三'), findsNothing);
    expect(find.text('不应跳转到列表'), findsNothing);
    expect(controller.draftFor(b), isNotNull);
    await finishPage(tester);
  });
}
