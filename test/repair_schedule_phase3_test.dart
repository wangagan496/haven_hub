import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/repair.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/notifications/notification_page.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/pages/worker/worker_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/date_utils.dart';
import 'package:haven_hub/utils/emitter.dart';
import 'package:haven_hub/utils/repair_draft_store.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/widgets/repair_availability_hint.dart';
import 'package:haven_hub/widgets/repair_progress.dart';
import 'package:haven_hub/widgets/repair_slot_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/repair_slots_fixture.dart';
import 'helpers/widget_harness.dart';
import 'repair_flow_test.dart' show form, fillRepair;

const _slot = '2030-10-20#10';
const _time = '2030-10-20T10:00:00+08:00';
const _first = RepairPending(kind: 'reschedule', by: 'worker', firstSchedule: true,
  proposedSlot: _slot, proposedTime: _time, deadline: '2030-10-20T09:30:00+08:00', reason: '已联系');
const _pending = RepairRecord(id: 'p3', status: 2, pendingSchedule: _first, slot: _slot);
const _agreed = RepairRecord(id: 'p3', status: 2, agreedTime: _time, slot: _slot,
  slotWindow: RepairSlotWindow(start: _time, end: '2030-10-20T11:00:00+08:00'));

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.pump();
  if (find.text(text).evaluate().isEmpty) {
    await tester.scrollUntilVisible(find.text(text), 180, scrollable: find.byType(Scrollable).first);
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

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();
  });
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('P3 optional scheduling fields tolerate missing and null', () {
    final record = RepairRecord.fromJson({for (final key in ['slot', 'slotWindow', 'pendingSchedule',
      'expectedSlot', 'autoAccepted', 'shiftCount', 'priority', 'priorityPending', 'urgentRequest', 'asap', 'needsAdmin']) key: null});
    expect(record.slot, isEmpty);
    expect(record.firstSchedule, isNull);
    expect(record.slotWindow, isNull);
    expect(record.shiftCount, 0);
    expect(record.autoAccepted || record.priorityPending || record.urgentRequest || record.asap || record.needsAdmin, isFalse);
    expect(RepairRecord.fromJson({}).slot, isEmpty);
  });

  test('P3 window formatting leaves historic 18:00 and non-hour deadlines unchanged', () {
    expect(formatSlotWindow(slot: _slot), '10月20日 周日 10:00–11:00');
    final historical = DateTime(2026, 10, 18, 18).toIso8601String();
    expect(formatVisitTime(historical), endsWith('18:00'));
    expect(formatVisitTime(DateTime(2026, 10, 18, 18, 37).toIso8601String()), endsWith('18:37'));
    expect(formatVisitTime(historical), isNot(contains('–')));
  });

  testWidgets('P3 selector uses server today and 4 4 3 groups and forwards excludeId', (tester) async {
    tallPage(tester);
    final calls = <String?>[];
    await pumpPage(tester, Scaffold(body: RepairSlotPicker(excludeId: 'p3', loader: ({date, excludeId}) async {
      calls.add(excludeId); return slotsFixture(date: date ?? '2030-10-20');
    })));
    expect(find.text('今天 10-20'), findsOneWidget);
    expect(find.text('上午'), findsOneWidget); expect(find.text('下午'), findsOneWidget); expect(find.text('晚上'), findsOneWidget);
    final chips = tester.widgetList<ActionChip>(find.byType(ActionChip)).map((c) => (c.label as Text).data).toList();
    expect(chips, ['08:00–09:00','09:00–10:00','10:00–11:00','11:00–12:00',
      '14:00–15:00','15:00–16:00','16:00–17:00','17:00–18:00','19:00–20:00','20:00–21:00','21:00–22:00']);
    await tapText(tester, '10-21');
    expect(find.byKey(const ValueKey('2030-10-21#10')), findsOneWidget);
    expect(calls, everyElement('p3'));
    await finishPage(tester);
  });

  testWidgets('P3 unavailable slots are hidden and empty day offers alternatives', (tester) async {
    tallPage(tester);
    await pumpPage(tester, Scaffold(body: RepairSlotPicker(loader: ({date, excludeId}) async => slotsFixture(unavailable: {8,10,21}))));
    expect(find.text('08:00–09:00'), findsNothing); expect(find.text('10:00–11:00'), findsNothing); expect(find.text('21:00–22:00'), findsNothing);
    expect(find.byType(ActionChip), findsNWidgets(8));
    await finishPage(tester);
    await pumpPage(tester, Scaffold(body: RepairSlotPicker(loader: ({date, excludeId}) async => const RepairSlots(today: '2030-10-20', dates: ['2030-10-20'], slots: []))));
    expect(find.text('可选其他日期或提交待安排'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('P3 failed lookup shows error and retry without fake empty slots', (tester) async {
    int calls = 0;
    await pumpPage(tester, Scaffold(body: RepairSlotPicker(loader: ({date, excludeId}) async {
      if (++calls == 1) throw const NetworkException('查询断网');
      return slotsFixture();
    })));
    expect(find.text('查询断网'), findsOneWidget);
    expect(find.text('可选其他日期或提交待安排'), findsNothing);
    expect(find.byType(ActionChip), findsNothing);
    await tapText(tester, '重试');
    expect(find.text('10:00–11:00'), findsOneWidget); expect(calls, 2);
    await finishPage(tester);
  });

  testWidgets('P3 resume refreshes availability and discards stale in-flight response', (tester) async {
    final first = Completer<RepairSlots>();
    int calls = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RepairSlotPicker(loader: ({date, excludeId}) {
      return ++calls == 1 ? first.future : Future.value(slotsFixture(unavailable: {10}));
    }))));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    first.complete(slotsFixture()); await tester.pumpAndSettle();
    expect(calls, 2); expect(find.text('10:00–11:00'), findsNothing);
    await finishPage(tester);
  });

  for (final entry in <(RepairRecord, String)>[
    (const RepairRecord(id: 'p3', status: 1), '等待安排上门时间'),
    (_pending, '首次提议待确认'), (_agreed, '已约定'),
    (const RepairRecord(id: 'p3', status: 2, agreedTime: _time, slot: _slot, autoAccepted: true), '超时已生效'),
    (const RepairRecord(id: 'p3', status: 2, agreedTime: _time, slot: _slot, timeline: [RepairEvent(action: 'admin_shifted', label: '物业顺延', at: _time)]), '物业已调整时间'),
  ]) {
    testWidgets('P3 resident schedule state ${entry.$2}', (tester) async {
      tallPage(tester);
      await pumpPage(tester, RepairDetailPage(loader: (_) async => entry.$1), arguments: 'p3');
      expect(find.text(entry.$2), findsOneWidget);
      expect(find.text('同意'), entry.$1.firstSchedule != null ? findsOneWidget : findsNothing);
      expect(find.text('这个时间不方便'), entry.$1.autoAccepted ? findsOneWidget : findsNothing);
      if (entry.$1.propertyAdjusted) expect(find.textContaining('等待住户同意'), findsNothing);
      await finishPage(tester);
    });
  }

  for (final accept in [true, false]) {
    testWidgets('P3 resident first proposal ${accept ? 'accept' : 'refuse with mandatory reason'}', (tester) async {
      tallPage(tester); final actions = <RepairAction>[];
      await pumpPage(tester, RepairDetailPage(loader: (_) async => _pending, actionLoader: (_, action) async {
        actions.add(action); return accept ? _agreed : const RepairRecord(id: 'p3', status: 2);
      }), arguments: 'p3');
      await tapText(tester, accept ? '同意' : '拒绝');
      if (!accept) {
        await tapText(tester, '确认拒绝'); expect(actions, isEmpty);
        await tester.enterText(find.byType(TextField), '当天不在家'); await tapText(tester, '确认拒绝');
      }
      final action = actions.single as RespondAction;
      expect(action.accept, accept); expect(action.reason, accept ? '' : '当天不在家');
      expect(find.text(accept ? '已约定' : '等待安排上门时间'), findsOneWidget);
      await finishPage(tester);
    });
  }

  testWidgets('P3 refusal conflict refreshes and retains the entered reason', (tester) async {
    tallPage(tester); int loads = 0, calls = 0;
    await pumpPage(tester, RepairDetailPage(loader: (_) async { loads++; return _pending; },
      actionLoader: (_, action) async { calls++; throw const NetworkException('名额已占', statusCode: 409); }), arguments: 'p3');
    await tapText(tester, '拒绝'); await tester.enterText(find.byType(TextField), '请另约明天');
    await tapText(tester, '确认拒绝'); expect(loads, 2); expect(calls, 1);
    await tapText(tester, '拒绝'); expect(find.text('请另约明天'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('P3 auto accepted inconvenience uses existing feedback action', (tester) async {
    tallPage(tester); RepairAction? sent;
    await pumpPage(tester, RepairDetailPage(loader: (_) async => const RepairRecord(id:'p3', status:2, autoAccepted:true, agreedTime:_time),
      actionLoader: (_, action) async { sent = action; return _agreed; }), arguments: 'p3');
    await tapText(tester, '这个时间不方便'); await tester.enterText(find.byType(TextField), '需要换一天');
    await tapText(tester, '提交反馈'); expect(sent, isA<FeedbackAction>());
    await finishPage(tester);
  });

  testWidgets('P3 urgent ASAP and selected slot are mutually exclusive and persist', (tester) async {
    tallPage(tester);
    await pumpPage(tester, form((_) async {}));
    expect(find.text('尽快上门'), findsNothing);
    await fillRepair(tester); await tapText(tester, '紧急诉求'); await tapText(tester, '尽快上门');
    expect(find.text('请选择期望上门时间'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    var draft = (await RepairDraftStore().load('test-user'))!;
    expect(draft.record.asap, isTrue); expect(draft.record.urgentRequest, isTrue); expect(draft.record.slot, isEmpty);
    await tapText(tester, '请选择期望上门时间'); await tapText(tester, '10:00–11:00');
    await tester.pump(const Duration(milliseconds: 400));
    draft = (await RepairDraftStore().load('test-user'))!;
    expect(draft.record.slot, _slot); expect(draft.record.asap, isFalse);
    await finishPage(tester);
  });

  test('P3 legacy draft exact slot migration rejects nonhour historic 18 and unavailable', () async {
    expect((await matchDraftSlot(_time, loadSlotsFixture))?.slot, _slot);
    for (final value in ['2030-10-20T10:30:00+08:00', '2030-10-20T18:00:00+08:00', '2031-10-20T10:00:00+08:00', '2030-10-20T10:00:00']) {
      expect(await matchDraftSlot(value, loadSlotsFixture), isNull);
    }
    expect(await matchDraftSlot(_time, ({date, excludeId}) async => slotsFixture(unavailable: {10})), isNull);
  });

  testWidgets('P3 invalid old draft clears time with warning and preserves all input', (tester) async {
    tallPage(tester); final store = RepairDraftStore();
    await store.save('test-user', const RepairDraft(record: RepairRecord(houseId:'house-test', repairItemId:'item-test',
      mobile:'13800138000', description:'旧草稿描述', expectedTime:'2030-10-20T18:00:00+08:00')));
    await pumpPage(tester, form((_) async {}, draftStore: store));
    expect(find.text('旧草稿描述'), findsOneWidget); expect(find.text('13800138000'), findsOneWidget);
    expect(find.text('旧草稿时间无法对应可预约时段，请重新选择或提交待安排'), findsOneWidget);
    expect(find.text('请选择期望上门时间'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('P3 info read state excludes pending count and retry; missing kind stays task', (tester) async {
    tallPage(tester); int reads = 0, retries = 0;
    final rows = <Map<String,dynamic>>[
      {'id':'info', 'kind':'info','active':1,'readAt':null,'title':'时间已调整','body':'告知内容'},
      {'id':'task', 'kind':'task','active':1,'title':'确认时间','body':'待办内容'},
      {'id':'legacy', 'active':1,'title':'旧服务端','body':'兼容'},
    ];
    await pumpPage(tester, NotificationPage(loader: () async => rows, reader: (id) async {
      expect(id,'info'); reads++; rows.first['readAt'] = 123; return rows.first;
    }, retrier: (_) async { retries++; }));
    expect(find.text('待处理 2 项'), findsOneWidget); expect(find.text('未读 · 时间已调整'), findsOneWidget);
    expect(find.text('重试系统提醒'), findsNWidgets(2));
    await tapText(tester, '标为已读');
    expect(reads,1); expect(retries,0); expect(find.text('已读 · 时间已调整'), findsOneWidget);
    expect(find.text('标为已读'), findsNothing); expect(find.text('待处理 2 项'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('P3 reassigned worker 404 explains and refreshes workbench', (tester) async {
    int refreshes = 0;
    await pumpPage(tester, WorkerDetailPage(id:'p3', recordLoader: (_) async => throw const NetworkException('不存在',statusCode:404),
      onReassigned: () async { refreshes++; }));
    expect(find.text('该工单已不再指派给你（可能已由物业改派）'), findsOneWidget); expect(refreshes,1);
    expect(find.text('重试'), findsNothing); expect(find.text('返回工单列表'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('P3 worker progress submits needsAdmin and preserves it on 409', (tester) async {
    tallPage(tester); int loads = 0; WorkerProgressAction? sent;
    await pumpPage(tester, WorkerDetailPage(id:'p3',recordLoader: (_) async { loads++; return _agreed; },actionLoader: (_,action) async {
      sent = action as WorkerProgressAction; throw const NetworkException('师傅冲突',statusCode:409);
    }));
    await tapText(tester,'补充进展');
    await tester.enterText(find.descendant(of:find.byType(AlertDialog),matching:find.byType(TextField)),'请物业联系住户');
    await tapText(tester,'需要物业协助'); await tapText(tester,'提交进展');
    expect(sent!.needsAdmin,isTrue); expect(loads,2);
    await tapText(tester,'补充进展'); expect(find.text('请物业联系住户'),findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,isTrue);
    await finishPage(tester);
  });

  for (final propose in [false,true]) {
    testWidgets('P3 worker unscheduled acceptance ${propose ? 'with first proposal and phone consent' : 'without time'}', (tester) async {
      tallPage(tester); int calls=0; String? sent;
      await pumpPage(tester, WorkerDetailPage(id:'p3', recordLoader: (_) async => const RepairRecord(id:'p3',status:5),
        slotsLoader:loadSlotsFixture, acceptor:(record,{slot,String reason=''}) async {
          calls++; sent=slot; if(propose) expect(reason,'已约电话'); return _pending;
        }));
      await tapText(tester,'接单'); await tapText(tester,propose?'接单并提议时间':'只接单');
      if(propose) {
        await tapText(tester,'10:00–11:00'); await tester.enterText(find.byType(TextField),'已约电话');
        await tapText(tester,'接单'); expect(calls,0);
        await tapText(tester,'我已电话告知住户'); await tapText(tester,'接单');
      }
      expect(calls,1); expect(sent,propose?_slot:null);
      await finishPage(tester);
    });
  }

  testWidgets('P3 worker proposal uses excludeId and phone consent before sending', (tester) async {
    tallPage(tester); WorkerProposeAction? sent; final ids=<String?>[];
    await pumpPage(tester,WorkerDetailPage(id:'p3',recordLoader:(_) async => const RepairRecord(id:'p3',status:2),
      slotsLoader:({date,excludeId}) async { ids.add(excludeId); return slotsFixture(); },
      actionLoader:(_,action) async { sent=action as WorkerProposeAction; return _pending; }));
    await tapText(tester,'首次提议时间'); await tapText(tester,'10:00–11:00');
    await tester.enterText(find.descendant(of:find.byType(AlertDialog),matching:find.byType(TextField)),'已联系住户');
    await tapText(tester,'发起改约'); expect(sent,isNull);
    await tapText(tester,'我已电话告知住户'); await tapText(tester,'发起改约');
    expect(sent!.slot,_slot); expect(ids,everyElement('p3'));
    await finishPage(tester);
  });

  for(final state in ['available','full','error']) {
    testWidgets('P3 home availability $state queries today without date or quantities', (tester) async {
      await pumpPage(tester,Scaffold(body:RepairAvailabilityHint(loader:({date,excludeId}) async {
        expect(date,isNull); expect(excludeId,isNull);
        if(state=='error') throw const NetworkException('断网');
        return state=='full' ? const RepairSlots(today:'2030-10-20',dates:['2030-10-20'],slots:[]) : slotsFixture();
      })));
      expect(find.text(state=='error'?'暂时无法获取':state=='full'?'今天已约满，可选后续日期或提交待安排':'今天可预约'),findsOneWidget);
      expect(find.textContaining('剩余'),findsNothing); expect(find.textContaining('容量'),findsNothing);
      await finishPage(tester);
    });
  }

  testWidgets('P3 home availability refreshes login and discards pre-login response', (tester) async {
    final oldResponse = Completer<RepairSlots>();
    var queries = 0;
    await pumpPage(tester, Scaffold(body: RepairAvailabilityHint(loader: ({date, excludeId}) {
      queries++;
      return queries == 1 ? oldResponse.future : Future.value(slotsFixture());
    })));
    await tokenManager.setToken('phase3-next-session');
    eventBus.fire(const LoginSuccessEvent());
    await tester.pumpAndSettle();
    expect(queries, 2);
    expect(find.text('今天可预约'), findsOneWidget);
    oldResponse.complete(const RepairSlots(today: '2030-10-20', dates: ['2030-10-20'], slots: []));
    await tester.pumpAndSettle();
    expect(find.text('今天可预约'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('P3 home availability clears previous account status on logout', (tester) async {
    await pumpPage(tester, Scaffold(body: RepairAvailabilityHint(loader: ({date, excludeId}) async => slotsFixture())));
    expect(find.text('今天可预约'), findsOneWidget);
    eventBus.fire(const LogoutEvent());
    await tester.pumpAndSettle();
    expect(find.text('暂时无法获取'), findsOneWidget);
    await finishPage(tester);
  });

  test('P3 progress covers actual schedule events and unknown server label', () {
    expect(repairEventLabel(const RepairEvent(action:'admin_shifted',label:'',at:'')),'物业已调整时间');
    expect(repairEventLabel(const RepairEvent(action:'reschedule_proposed',label:'',detail:'未约定 → 新时段',at:'')),'首次上门时间待住户确认');
    expect(repairEventLabel(const RepairEvent(action:'rescheduled',label:'',detail:'未约定 → 新时段',at:'')),'住户已同意首次上门时间');
    expect(repairEventLabel(const RepairEvent(action:'future_event',label:'服务端新文案',at:'')),'服务端新文案');
  });
}
