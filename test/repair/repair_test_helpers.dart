import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/models/user_info.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/utils/repair_draft_store.dart';

import 'repair_slots_fixture.dart';

Future<void> fillRepair(WidgetTester tester) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>).at(0));
  await tester.pumpAndSettle();
  await tester.tap(find.text('测试小区 1栋 101').last);
  await tester.pumpAndSettle();
  await tester.tap(find.byType(DropdownButtonFormField<String>).at(1));
  await tester.pumpAndSettle();
  await tester.tap(find.text('水管维修').last);
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextFormField).first, '13800138000');
  await tester.tap(find.text('请选择期望上门时间'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('10:00–11:00'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextFormField).last, '水管漏水');
  await tester.scrollUntilVisible(find.text('提交报修'), 200,
      scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

RepairFormPage form(
  Future<dynamic> Function(RepairRecord) submitter, {
  RepairDraftStore? draftStore,
  String Function()? draftUserKey,
  bool productionIdentity = false,
}) =>
    RepairFormPage(
      draftStore: draftStore ?? RepairDraftStore(),
      userInfoLoader: () async => const UserInfo.empty(),
      draftUserKey:
          productionIdentity ? null : draftUserKey ?? () => 'test-user',
      houseLoader: () async => const <House>[
        House(id: 'house-test', point: '测试小区', building: '1栋', room: '101'),
      ],
      itemLoader: () async =>
          const <RepairItem>[RepairItem(id: 'item-test', name: '水管维修')],
      submitter: submitter,
      submissionLoader: (_) async => null,
      slotsLoader: loadSlotsFixture,
    );

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.pump();
  if (find.text(text).evaluate().isEmpty) {
    await tester.scrollUntilVisible(find.text(text), 180,
        scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(find.text(text).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

void tallPage(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
