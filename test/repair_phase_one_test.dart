import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/repair.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/pages/worker/worker_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/widget_harness.dart';
import 'repair_flow_test.dart' show fillRepair, form;

const _deadline = '2030-10-20T10:00:00+08:00';
const _warning = '冲突，已刷新最新状态';

RepairRecord _record(int status,
        {bool second = false,
        bool closed = false,
        int revision = 4,
        List<RepairPending> pendings = const <RepairPending>[]}) =>
    RepairRecord(
      id: 'phase-one', status: status, workflowVersion: 1, revision: revision,
      repairItemName: '测试水管', mobile: '13800138000',
      workerMobile: '13800138091', propertyPhone: '020-88888888',
      expectedTime: _deadline, agreedTime: _deadline,
      confirmDeadline: status == 6 ? _deadline : '',
      warrantyEnd: status == 3 ? _deadline : '',
      round: second ? 2 : 1, reworkUsed: second, closed: closed,
      pendings: pendings,
    );

Future<void> _tap(WidgetTester tester, String text) async {
  await tester.pump();
  if (find.text(text).evaluate().isEmpty) {
    await tester.scrollUntilVisible(find.text(text), 250,
        scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(find.text(text).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();
  });

  test('P1 model parses dates, rounds, pending resolution, costs and derived fields', () {
    final record = RepairRecord.fromJson(<String, dynamic>{
      'id': 'p1', 'status': '6', 'revision': '9', 'round': '2',
      'reworkUsed': true, 'closed': false, 'propertyPhone': '020-88888888',
      'expectedTime': _deadline, 'agreedTime': _deadline,
      'confirmDeadline': _deadline, 'warrantyEnd': _deadline,
      'rounds': <dynamic>[
        <String, dynamic>{'number': 1, 'workerName': '张师傅', 'note': '第一轮',
          'cost': '12.5', 'completedAt': _deadline, 'confirmedAt': _deadline,
          'confirmedBy': 'resident', 'rejectReason': '再次漏水', 'verifiedNote': '核实10元'},
        <String, dynamic>{'number': 2, 'note': '第二轮', 'cost': 0,
          'confirmedBy': 'system'},
        'invalid legacy entry',
      ],
      'pendings': <dynamic>[
        <String, dynamic>{'kind': 'reschedule', 'by': 'resident', 'resolvedAt': _deadline, 'reply': '旧回应'},
        <String, dynamic>{'kind': 'reschedule', 'by': 'worker', 'at': _deadline,
          'reason': '新提议', 'proposedTime': _deadline, 'deadline': _deadline},
      ],
    });
    expect(record.statusText, '待确认');
    expect(record.revision, 9);
    expect(record.round, 2);
    expect(record.reworkUsed, isTrue);
    expect(record.closed, isFalse);
    expect(record.propertyPhone, '020-88888888');
    expect(record.expectedTime, _deadline);
    expect(record.agreedTime, _deadline);
    expect(record.confirmDeadline, _deadline);
    expect(record.warrantyEnd, _deadline);
    expect(record.rounds, hasLength(2));
    final first = record.rounds.first;
    expect(first.number, 1);
    expect(first.workerName, '张师傅');
    expect(first.note, '第一轮');
    expect(first.cost, 12.5);
    expect(first.completedAt, _deadline);
    expect(first.confirmedAt, _deadline);
    expect(first.confirmedBy, 'resident');
    expect(first.rejectReason, '再次漏水');
    expect(first.verifiedNote, '核实10元');
    expect(record.rounds.last.confirmedBy, 'system');
    expect(record.rounds.last.cost, 0);
    expect(record.pendings.first.resolved, isTrue);
    expect(record.pendings.first.reply, '旧回应');
    expect(record.reschedule!.by, 'worker');
    expect(record.reschedule!.reason, '新提议');
    expect(record.reschedule!.proposedTime, _deadline);
    expect(record.reschedule!.deadline, _deadline);
    expect(record.toJson().containsKey('expectedTime'), isFalse);
    expect(record.toJson().containsKey('appointment'), isFalse);
    expect(const RepairRecord(appointment: '2026-10-20').toJson().containsKey('appointment'), isFalse);
    expect(RepairRecord.fromJson(<String, dynamic>{'status': 3}).rounds, isEmpty);
  });

  for (final status in <int>[0, 1, 2, 3, 4, 5, 6]) {
    test('P1 can predicates state $status respect server closed and pending flags', () {
      final record = _record(status, closed: status == 0 || status == 4);
      expect(record.canCancel, status == 1 || status == 5);
      expect(record.canRevoke, <int>[1, 2, 5].contains(status));
      expect(record.revokeNeedsWorker, status == 2);
      expect(record.canConfirm, status == 6);
      expect(record.canReject, status == 6);
      expect(record.canReschedule, status == 2);
      expect(record.inWarranty, status == 3);
      expect(record.canApplyAftersale, status == 3);
      expect(record.canFeedback, status != 0 && status != 4);
    });
  }

  test('P1 second round and open pending predicates disable conflicting actions', () {
    expect(_record(6, second: true).canReject, isTrue);
    expect(_record(3, second: true).canApplyAftersale, isTrue);
    expect(_record(3, second: true).canFeedback, isTrue);
    expect(_record(3, closed: true).canFeedback, isFalse);
    expect(_record(3, closed: true).canApplyAftersale, isFalse);
    final revoke = _record(2, pendings: const <RepairPending>[
      RepairPending(kind: 'revoke', by: 'resident')]);
    expect(revoke.canRevoke, isFalse);
    expect(revoke.canReschedule, isFalse);
    expect(_record(2, pendings: const <RepairPending>[
      RepairPending(kind: 'reschedule', by: 'resident')]).canReschedule, isFalse);
    final completed = _record(3, pendings: const <RepairPending>[
      RepairPending(kind: 'aftersale', by: 'resident'),
      RepairPending(kind: 'feedback', by: 'resident')]);
    expect(completed.canApplyAftersale, isFalse);
    expect(completed.canFeedback, isFalse);
    expect(const RepairRecord(expectedTime: 'expected').visitTime, 'expected');
    expect(const RepairRecord(expectedTime: 'expected', agreedTime: 'agreed').visitTime, 'agreed');
  });

  for (final scenario in <(int, bool, bool, List<String>)>[
    (1, false, false, <String>['取消报修']),
    (5, false, false, <String>['取消报修']),
    (2, false, false, <String>['修改预约', '申请撤销']),
    (6, false, false, <String>['确认修好', '还没修好', '反馈问题']),
    (6, true, false, <String>['确认修好', '还没修好', '反馈问题']),
    (3, false, false, <String>['申请售后返修', '反馈问题']),
    (3, true, false, <String>['申请售后返修', '反馈问题']),
    (3, false, true, <String>[]),
    (0, false, true, <String>[]),
  ]) {
    testWidgets('P1 resident action matrix ${scenario.$1}/${scenario.$2}/${scenario.$3}', (tester) async {
      await pumpPage(tester, RepairDetailPage(loader: (_) async =>
          _record(scenario.$1, second: scenario.$2, closed: scenario.$3)), arguments: 'phase-one');
      for (final label in <String>['取消报修', '修改预约', '申请撤销', '确认修好', '还没修好', '反馈问题', '申请售后返修']) {
        expect(find.text(label), scenario.$4.contains(label) ? findsOneWidget : findsNothing);
      }
      if (scenario.$1 == 6) {
        expect(find.text('师傅已提交完工，请确认是否修好'), findsOneWidget);
        expect(find.textContaining('前未操作，将自动确认完成'), findsOneWidget);
      }
      if (scenario.$1 == 3 && !scenario.$3) expect(find.textContaining('售后期至'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finishPage(tester);
    });
  }

  for (final scenario in <(RepairPending, String)>[
    (const RepairPending(kind: 'reschedule', by: 'worker', proposedTime: _deadline), '师傅提议修改上门时间'),
    (const RepairPending(kind: 'reschedule', by: 'resident', proposedTime: _deadline), '你发起的改约，等待师傅同意'),
    (const RepairPending(kind: 'revoke', by: 'resident', deadline: _deadline), '撤销申请已提交，等待师傅确认'),
    (const RepairPending(kind: 'aftersale', by: 'resident', reason: '漏水'), '售后申请待物业审核'),
    (const RepairPending(kind: 'feedback', by: 'resident', reason: '漏水'), '反馈已提交，等待物业回复'),
  ]) {
    testWidgets('P1 pending card ${scenario.$2}', (tester) async {
      await pumpPage(tester, RepairDetailPage(loader: (_) async =>
          _record(scenario.$1.kind == 'aftersale' ? 3 : 2, pendings: <RepairPending>[scenario.$1])), arguments: 'phase-one');
      expect(find.text(scenario.$2), findsOneWidget);
      expect(find.text('同意新时间'), scenario.$1.kind == 'reschedule' && scenario.$1.by == 'worker' ? findsOneWidget : findsNothing);
      if (scenario.$1.kind == 'revoke') expect(find.text('申请撤销'), findsNothing);
      if (scenario.$1.kind == 'aftersale') expect(find.text('申请售后返修'), findsNothing);
      await finishPage(tester);
    });
  }

  testWidgets('P1 processing revoke requires reason and checked phone notice', (tester) async {
    final requests = <RepairAction>[];
    await pumpPage(tester, RepairDetailPage(loader: (_) async => _record(2),
      actionLoader: (record, action) async {
        requests.add(action);
        return _record(2, pendings: const <RepairPending>[
          RepairPending(kind: 'revoke', by: 'resident', deadline: _deadline)]);
      }), arguments: 'phase-one');
    await _tap(tester, '申请撤销');
    await tester.enterText(find.byType(TextField), '已经解决');
    await _tap(tester, '提交撤销申请');
    expect(requests, isEmpty);
    expect(find.byType(AlertDialog), findsOneWidget);
    await _tap(tester, '我已电话告知师傅');
    await _tap(tester, '提交撤销申请');
    expect(requests, hasLength(1));
    final action = requests.single as RevokeAction;
    expect(action.reason, '已经解决');
    expect(action.notified, isTrue);
    expect(find.text('撤销申请已提交，等待师傅确认'), findsOneWidget);
    expect(find.text('申请撤销'), findsNothing);
    await finishPage(tester);
  });

  testWidgets('P1 resident 409 warns reloads authoritative state without replay', (tester) async {
    int loads = 0, calls = 0;
    await pumpPage(tester, RepairDetailPage(loader: (_) async =>
      ++loads == 1 ? _record(6) : _record(3, revision: 5),
      actionLoader: (record, action) async {
        calls++;
        expect(record.revision, 4);
        expect(action, isA<ConfirmAction>());
        throw const NetworkException('版本冲突', statusCode: 409);
      }), arguments: 'phase-one');
    await _tap(tester, '确认修好');
    await _tap(tester, '确认修好');
    expect(calls, 1);
    expect(loads, 2);
    expect(find.text('版本冲突，已刷新最新状态'), findsOneWidget);
    expect(find.text('确认修好'), findsNothing);
    expect(find.text('申请售后返修'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 1);
    await finishPage(tester);
  });

  testWidgets('P1 worker shows cost and progress/reschedule/release; invalid cost cannot submit', (tester) async {
    int calls = 0;
    await pumpPage(tester, WorkerDetailPage(id: 'phase-one', recordLoader: (_) async => _record(2),
      processor: (record, {required complete, String result = ''}) async { calls++; return _record(6); }));
    for (final label in <String>['费用（元）', '修改预约', '补充进展', '无法继续接单']) {
      if (find.text(label).evaluate().isEmpty) {
        await tester.scrollUntilVisible(find.text(label), 200,
            scrollable: find.byType(Scrollable).first);
      }
      expect(find.text(label), findsOneWidget);
    }
    await tester.enterText(find.byType(TextField).first, '换水管');
    for (final value in <String>['-1', 'abc']) {
      await tester.enterText(find.byType(TextField).last, value);
      await _tap(tester, '提交完工');
      expect(calls, 0);
      expect(find.text('请填写有效金额，无费用填 0'), findsWidgets);
    }
    await finishPage(tester);
  });

  testWidgets('P1 worker action 409 reloads and does not replay progress', (tester) async {
    int loads = 0, calls = 0;
    await pumpPage(tester, WorkerDetailPage(id: 'phase-one',
      recordLoader: (_) async { loads++; return _record(2, revision: loads == 1 ? 4 : 5); },
      actionLoader: (record, action) async {
        calls++;
        expect(action, isA<WorkerProgressAction>());
        expect(record.revision, 4);
        throw const NetworkException('冲突', statusCode: 409);
      }));
    await _tap(tester, '补充进展');
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), '等配件');
    await _tap(tester, '提交进展');
    expect(calls, 1);
    expect(loads, 2);
    expect(find.text(_warning), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 1);
    await finishPage(tester);
  });

  testWidgets('P1 worker completion 409 preserves result and reloads without replay', (tester) async {
    int loads = 0, calls = 0;
    await pumpPage(tester, WorkerDetailPage(id: 'phase-one',
      recordLoader: (_) async { loads++; return _record(2, revision: loads == 1 ? 4 : 5); },
      processor: (record, {required complete, String result = ''}) async {
        calls++;
        expect(result, '换水管');
        throw const NetworkException('冲突', statusCode: 409);
      }));
    await tester.scrollUntilVisible(find.text('修了什么（必填）'), 180, scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.byType(TextField).first, '换水管');
    await _tap(tester, '提交完工');
    expect(calls, 1);
    expect(loads, 2);
    expect(find.text(_warning), findsOneWidget);
    expect(find.text('换水管'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('P1 worker release returns to workbench without reloading forbidden detail', (tester) async {
    bool released = false;
    int loads = 0;
    await pumpPage(tester, WorkerPageForTest(
      builder: (context) => TextButton(onPressed: () async {
        await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) =>
          WorkerDetailPage(id: 'phase-one', recordLoader: (_) async { loads++; return _record(2); },
            actionLoader: (record, action) async {
              expect(action, isA<WorkerReleaseAction>());
              expect((action as WorkerReleaseAction).reason, '临时有事');
              released = true;
              return null;
            })));
      }, child: const Text('测试工作台入口'))));
    await _tap(tester, '测试工作台入口');
    await _tap(tester, '无法继续接单');
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), '临时有事');
    await _tap(tester, '确认退出');
    expect(released, isTrue);
    expect(loads, 1, reason: 'release must not reload forbidden detail');
    expect(find.text('测试工作台入口'), findsOneWidget);
    expect(find.byType(WorkerDetailPage), findsNothing);
    await finishPage(tester);
  });

  for (final fail in <bool>[false, true]) {
    testWidgets('P1 disposed worker ignores late release ${fail ? 'failure' : 'success'}', (tester) async {
      final response = Completer<RepairRecord?>();
      int calls = 0;
      await pumpPage(tester, WorkerDetailPage(id: 'phase-one', recordLoader: (_) async => _record(2),
        actionLoader: (_, action) { calls++; return response.future; }));
      await _tap(tester, '无法继续接单');
      await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), '临时有事');
      await tester.pump();
      await tester.tap(find.text('确认退出'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('其他页面'))));
      if (fail) {
        response.completeError(const NetworkException('迟到退出错误'));
      } else {
        response.complete(null);
      }
      await tester.pumpAndSettle();
      expect(find.text('其他页面'), findsOneWidget);
      expect(find.text('迟到退出错误'), findsNothing);
      expect(tester.takeException(), isNull);
      await finishPage(tester);
    });
  }

  testWidgets('P1 successful form String id opens new detail with server slot', (tester) async {
    RepairRecord? submitted;
    String? openedId;
    await pumpPage(tester, form((record) async { submitted = record; return 'new-repair'; }),
      routes: <String, WidgetBuilder>{RepairDetailPage.routeName: (context) {
        openedId = ModalRoute.of(context)!.settings.arguments! as String;
        return const Scaffold(body: Text('新报修详情'));
      }});
    await fillRepair(tester);
    await _tap(tester, '提交报修');
    expect(openedId, 'new-repair');
    expect(find.text('新报修详情'), findsOneWidget);
    expect(submitted, isNotNull);
    expect(submitted!.slot, '2030-10-20#10');
    expect(submitted!.expectedTime, isEmpty);
    await finishPage(tester);
  });
}

class WorkerPageForTest extends StatelessWidget {
  const WorkerPageForTest({required this.builder, super.key});
  final WidgetBuilder builder;
  @override
  Widget build(BuildContext context) => Scaffold(body: Builder(builder: builder));
}
