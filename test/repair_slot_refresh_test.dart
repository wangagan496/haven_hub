import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/repair_draft_store.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/widgets/repair_slot_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/repair_slots_fixture.dart';
import 'helpers/widget_harness.dart';
import 'repair_flow_test.dart' show form, fillRepair;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();
  });
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
  testWidgets('skill category reaches initial load, periodic refresh and selection recheck', (tester) async {
    final received = <String?>[];
    await pumpPage(tester, Scaffold(body: Builder(builder: (context) => TextButton(
      onPressed: () => pickRepairSlot(context, repairItemId: '1005', loader: ({date, excludeId, repairItemId}) async {
        received.add(repairItemId);
        return slotsFixture();
      }), child: const Text('选择时间'),
    ))));
    await tester.tap(find.text('选择时间')); await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 15)); await tester.pumpAndSettle();
    await tester.tap(find.text('10:00–11:00')); await tester.pumpAndSettle();
    expect(received.length, greaterThanOrEqualTo(3));
    expect(received, everyElement('1005'));
    await finishPage(tester);
  });
  testWidgets('open picker refreshes capacity without reopening and stops after dispose', (tester) async {
    int calls = 0;
    bool full = false;
    await pumpPage(tester, Scaffold(body: RepairSlotPicker(loader: ({date, excludeId, repairItemId}) async {
      calls++;
      return slotsFixture(unavailable: full ? {10} : {});
    })));
    expect(find.text('10:00–11:00'), findsOneWidget);
    full = true;
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(find.text('10:00–11:00'), findsNothing);
    expect(calls, 2);
    await finishPage(tester);
    await tester.pump(const Duration(seconds: 30));
    expect(calls, 2);
  });

  testWidgets('picker manual refresh and background pause prevent stale choices', (tester) async {
    int calls = 0;
    await pumpPage(tester, Scaffold(body: RepairSlotPicker(loader: ({date, excludeId, repairItemId}) async {
      calls++;
      return slotsFixture(unavailable: calls > 1 ? {10} : {});
    })));
    await tester.tap(find.text('刷新时段'));
    await tester.pumpAndSettle();
    expect(find.text('10:00–11:00'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 30));
    expect(calls, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, 3);
    await finishPage(tester);
  });

  testWidgets('selecting an outdated slot rechecks and stays open for reselection', (tester) async {
    bool full = false;
    RepairSlot? selected;
    await pumpPage(tester, Scaffold(body: Builder(builder: (context) => TextButton(
      onPressed: () async { selected = await pickRepairSlot(context, loader: ({date, excludeId, repairItemId}) async => slotsFixture(unavailable: full ? {10} : {})); },
      child: const Text('选择时间'),
    ))));
    await tester.tap(find.text('选择时间')); await tester.pumpAndSettle();
    full = true;
    await tester.tap(find.text('10:00–11:00')); await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(find.textContaining('该时段已不可选'), findsOneWidget);
    expect(find.text('10:00–11:00'), findsNothing);
    await tester.tap(find.text('11:00–12:00')); await tester.pumpAndSettle();
    expect(selected?.slot, '2030-10-20#11');
    await finishPage(tester);
  });

  testWidgets('slow refresh does not overlap or apply after picker disposal', (tester) async {
    final pending = Completer<RepairSlots>();
    int calls = 0;
    await pumpPage(tester, Scaffold(body: RepairSlotPicker(loader: ({date, excludeId, repairItemId}) {
      calls++;
      return calls == 1 ? Future.value(slotsFixture()) : pending.future;
    })));
    await tester.pump(const Duration(seconds: 15));
    await tester.pump(const Duration(seconds: 30));
    expect(calls, 2);
    await finishPage(tester);
    pending.complete(slotsFixture(unavailable: {10}));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  for (final bool offline in <bool>[false, true]) {
    testWidgets('submit recheck ${offline ? 'offline' : 'full'} keeps the form and never sends the repair', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      bool changed = false;
      int submits = 0;
      final store = RepairDraftStore();
      final base = form((_) async { submits++; }, draftStore: store);
      await pumpPage(tester, RepairFormPage(
        draftStore: store, draftUserKey: base.draftUserKey, userInfoLoader: base.userInfoLoader,
        houseLoader: base.houseLoader, itemLoader: base.itemLoader, submitter: base.submitter,
        slotsLoader: ({date, excludeId, repairItemId}) async {
          if (changed && offline) throw const NetworkException('时段查询断网');
          return slotsFixture(unavailable: changed ? {10} : {});
        },
      ));
      await fillRepair(tester);
      changed = true;
      await tester.tap(find.text('提交报修')); await tester.pumpAndSettle();
      expect(submits, 0);
      expect(find.text('水管漏水'), findsOneWidget);
      await finishPage(tester);
      final saved = await store.load('test-user');
      expect(saved?.record.description, '水管漏水');
      expect(saved?.record.mobile, '13800138000');
      expect(saved?.resultUnconfirmed, isFalse);
      expect(saved?.record.slot, offline ? '2030-10-20#10' : isEmpty);
    });
  }
}
