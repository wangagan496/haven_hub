import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/repair.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/widgets/repair_slot_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/repair_slots_fixture.dart';
import 'helpers/widget_harness.dart';

const offered = RepairRecord(id: 'unstaffed', status: 1, revision: 4, slot: '2030-10-20#14',
  agreedTime: '2030-10-20T14:00:00+08:00', repairItemName: '水暖维修',
  rescheduleOffer: RepairRescheduleOffer(id: 'offer-1', deadline: '2030-10-20T10:00:00+08:00'));
const updated = RepairRecord(id: 'unstaffed', status: 1, revision: 5, slot: '2030-10-20#10', repairItemName: '水暖维修');
Future<void> detail(WidgetTester tester, UnstaffedChoiceLoader submit, {RepairSlotsLoader? slots}) async {
  await pumpPage(tester, RepairDetailPage(loader: (_) async => offered, unstaffedChoiceLoader: submit,
    unstaffedSlotsLoader: slots ?? ({date, excludeId, repairItemId}) async => slotsFixture()), arguments: 'unstaffed');
}

void main() {
  setUpAll(() async { SharedPreferences.setMockInitialValues(<String, Object>{}); await tokenManager.init(); });
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('unstaffed options without quota numbers render and submit selected slot', (tester) async {
    int calls = 0;
    await detail(tester, (record, {slot, keep = false}) async {
      calls++;
      expect(slot, '2030-10-20#10');
      expect(record.revision, 4);
      expect(record.rescheduleOffer?.id, 'offer-1');
      expect(keep, isFalse);
      return updated;
    }, slots: ({date, excludeId, repairItemId}) async => RepairSlots.fromJson(<String, dynamic>{
      'today': '2030-10-20', 'dates': <String>['2030-10-20', '2030-10-21'],
      'slots': <Map<String, dynamic>>[<String, dynamic>{
        'slot': '2030-10-20#10', 'start': '2030-10-20T10:00:00+08:00',
        'end': '2030-10-20T11:00:00+08:00', 'period': 'morning', 'selectable': true,
      }],
    }));
    await tester.tap(find.text('选择新时间')); await tester.pumpAndSettle();
    expect(find.text('10:00–11:00'), findsOneWidget);
    expect(find.textContaining('余量'), findsNothing);
    await tester.tap(find.text('10:00–11:00')); await tester.pump(); await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('确认新的上门时间'), findsOneWidget);
    await tester.tap(find.text('确认改时间')); await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(RepairSlotPicker), findsNothing);
    expect(find.text('选择新时间'), findsNothing);
    expect(tester.takeException(), isNull);
    await finishPage(tester);
  });

  testWidgets('unstaffed banner displays response deadline and offers both choices', (tester) async {
    await detail(tester, (record, {slot, keep = false}) async => updated);
    expect(find.text('请选择新的上门时间'), findsOneWidget);
    expect(find.textContaining('10月20日'), findsWidgets);
    expect(find.textContaining('10:00'), findsWidgets);
    expect(find.text('选择新时间'), findsOneWidget);
    expect(find.text('保持原时间，继续等'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('unstaffed selection confirms before submitting once and ignores repeated taps', (tester) async {
    int calls = 0; final pending = Completer<RepairRecord>();
    await detail(tester, (record, {slot, keep = false}) {
      calls++; expect(record.revision, 4); expect(record.rescheduleOffer?.id, 'offer-1');
      expect(slot, '2030-10-20#10'); expect(keep, isFalse); return pending.future;
    });
    await tester.tap(find.text('选择新时间')); await tester.pumpAndSettle();
    await tester.tap(find.text('10:00–11:00')); await tester.pump(); await tester.pump(const Duration(milliseconds: 400));
    expect(calls, 0); expect(find.text('确认新的上门时间'), findsOneWidget);
    await tester.tap(find.text('确认改时间')); await tester.pump(); await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('10:00–11:00')); await tester.pump(); expect(calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); await tester.pump(); expect(calls, 1);
    pending.complete(updated); await tester.pumpAndSettle();
    expect(find.byType(RepairSlotPicker), findsNothing); expect(find.text('选择新时间'), findsNothing);
    await finishPage(tester);
  });

  testWidgets('unstaffed 409 keeps picker open displays reason and refreshes choices', (tester) async {
    int calls = 0; int queries = 0; bool full = false;
    await detail(tester, (record, {slot, keep = false}) async {
      calls++; full = true; throw const NetworkException('该时段刚被约满，请重新选择', statusCode: 409);
    }, slots: ({date, excludeId, repairItemId}) async {
      queries++; return slotsFixture(unavailable: full ? <int>{10} : <int>{});
    });
    await tester.tap(find.text('选择新时间')); await tester.pumpAndSettle();
    await tester.tap(find.text('10:00–11:00')); await tester.pump(); await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('确认改时间')); await tester.pumpAndSettle();
    expect(calls, 1); expect(queries, greaterThanOrEqualTo(3));
    expect(find.byType(RepairSlotPicker), findsOneWidget);
    expect(find.textContaining('该时段刚被约满'), findsWidgets);
    expect(find.text('10:00–11:00'), findsNothing); expect(find.text('11:00–12:00'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('unstaffed keep submits keep once and closes offer banner', (tester) async {
    int calls = 0;
    await detail(tester, (record, {slot, keep = false}) async { calls++; expect(keep, isTrue); expect(slot, isNull); return updated; });
    await tester.tap(find.text('保持原时间，继续等')); await tester.pumpAndSettle();
    expect(calls, 1); expect(find.text('请选择新的上门时间'), findsNothing);
    await finishPage(tester);
  });

  testWidgets('unstaffed account switch discards old submit result and old option response', (tester) async {
    final pending = Completer<RepairRecord>();
    await detail(tester, (record, {slot, keep = false}) => pending.future);
    await tester.tap(find.text('保持原时间，继续等')); await tester.pump();
    await tokenManager.setToken('other-user-token'); pending.complete(updated); await tester.pumpAndSettle();
    expect(find.text('请选择新的上门时间'), findsOneWidget);
    expect(find.text('上门时间已更新'), findsNothing);
    await finishPage(tester);
    final options = Completer<RepairSlots>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RepairSlotPicker(loader: ({date, excludeId, repairItemId}) => options.future))));
    await tester.pump(); await tokenManager.setToken('third-user-token'); options.complete(slotsFixture()); await tester.pumpAndSettle();
    expect(find.text('10:00–11:00'), findsNothing);
    await finishPage(tester);
  });
}
