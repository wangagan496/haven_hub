import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/repair_slots_fixture.dart';
import 'helpers/widget_harness.dart';

const RepairRecord offeredRepair = RepairRecord(
  id: 'replacement-snapshot',
  status: 1,
  revision: 4,
  slot: '2030-10-20#14',
  agreedTime: '2030-10-20T14:00:00+08:00',
  description: '旧详情',
  rescheduleOffer: RepairRescheduleOffer(
    id: 'offer-snapshot',
    deadline: '2030-10-20T10:00:00+08:00',
  ),
);

const RepairRecord replacementResult = RepairRecord(
  id: 'replacement-snapshot',
  status: 1,
  revision: 5,
  slot: '2030-10-20#10',
  description: '提交成功后的详情',
);

Future<void> openReplacementPicker(WidgetTester tester) async {
  await tester.ensureVisible(find.text('选择新时间'));
  await tester.tap(find.text('选择新时间'));
  await tester.pumpAndSettle();
}

Future<void> selectAndConfirmReplacement(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('2030-10-20#10')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text('确认改时间'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.loadTokens();
  });
  for (final scenario in <(String, String, int)>[
    ('还没修好', '交回返修', 6),
    ('申请售后返修', '提交申请', 3),
    ('反馈问题', '提交反馈', 6),
    ('修改预约', '发起改约', 2),
    ('拒绝', '确认拒绝', 2),
  ]) {
    testWidgets(
        '${scenario.$1} aborts when revision changes while its dialog is open',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var reads = 0, writes = 0;
      RepairRecord record() => RepairRecord(
            id: 'snapshot',
            status: scenario.$3,
            revision: ++reads,
            workflowVersion: 1,
            workerMobile: '13800138091',
            agreedTime: '2030-10-20T10:00:00+08:00',
            slot: '2030-10-20#10',
            confirmDeadline: '2030-10-20T10:00:00+08:00',
            warrantyEnd: '2030-10-20T10:00:00+08:00',
            pendingSchedule: scenario.$1 == '拒绝'
                ? const RepairPending(
                    kind: 'reschedule',
                    by: 'worker',
                    firstSchedule: true,
                    proposedSlot: '2030-10-20#11',
                    proposedTime: '2030-10-20T11:00:00+08:00',
                    deadline: '2030-10-20T09:30:00+08:00')
                : null,
          );
      await pumpPage(
          tester,
          RepairDetailPage(
            loadRepairDetail: (_) async => record(),
            submitAction: (r, a) async {
              writes++;
              return r;
            },
            loadAvailableSlots: ({date, excludeId, repairItemId}) async =>
                slotsFixture(),
          ),
          arguments: 'snapshot');
      await tester.ensureVisible(find.text(scenario.$1));
      await tester.tap(find.text(scenario.$1));
      await tester.pumpAndSettle();
      if (scenario.$1 == '修改预约') {
        await tester.tap(find.byKey(const ValueKey('2030-10-20#11')));
        await tester.pumpAndSettle();
      }
      await tester.enterText(find.byType(TextField).last, '需要重新处理');
      if (scenario.$1 == '修改预约') {
        await tester.tap(find.text('我已电话告知师傅'));
        await tester.pumpAndSettle();
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(reads, 2);
      await tester.tap(find.text(scenario.$2).last);
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(reads, 3);
      expect(find.text('工单状态已更新，请重新核对后再确认'), findsOneWidget);
      await finishPage(tester);
    });
  }

  testWidgets('replacement choice aborts when the repair revision changes',
      (tester) async {
    final Completer<RepairRecord> refreshedDetail = Completer<RepairRecord>();
    var detailReads = 0;
    var writes = 0;
    await pumpPage(
      tester,
      RepairDetailPage(
        loadRepairDetail: (_) {
          detailReads++;
          return detailReads == 1
              ? Future<RepairRecord>.value(offeredRepair)
              : refreshedDetail.future;
        },
        submitReplacementChoice: (record, {slot, keep = false}) async {
          writes++;
          return record;
        },
        loadReplacementSlots: ({date, excludeId, repairItemId}) async =>
            slotsFixture(),
      ),
      arguments: offeredRepair.id,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(detailReads, 2);
    await openReplacementPicker(tester);
    refreshedDetail.complete(replacementResult);
    await tester.pumpAndSettle();
    await selectAndConfirmReplacement(tester);

    expect(writes, 0);
    expect(find.text('工单状态已更新，请重新核对后再确认'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('replacement choice handles an offer closed during selection',
      (tester) async {
    final Completer<RepairRecord> refreshedDetail = Completer<RepairRecord>();
    var detailReads = 0;
    var writes = 0;
    const closedOffer = RepairRecord(
      id: 'replacement-snapshot',
      status: 1,
      revision: 4,
      slot: '2030-10-20#14',
      description: '改约已关闭',
    );
    await pumpPage(
      tester,
      RepairDetailPage(
        loadRepairDetail: (_) {
          detailReads++;
          return detailReads == 1
              ? Future<RepairRecord>.value(offeredRepair)
              : refreshedDetail.future;
        },
        submitReplacementChoice: (record, {slot, keep = false}) async {
          writes++;
          return record;
        },
        loadReplacementSlots: ({date, excludeId, repairItemId}) async =>
            slotsFixture(),
      ),
      arguments: offeredRepair.id,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(detailReads, 2);
    await openReplacementPicker(tester);
    refreshedDetail.complete(closedOffer);
    await tester.pumpAndSettle();
    await selectAndConfirmReplacement(tester);

    expect(tester.takeException(), isNull);
    expect(writes, 0);
    expect(find.text('改约提议已关闭，请刷新工单状态'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('keeping the original schedule refreshes detail once after a 409',
      (tester) async {
    var detailReads = 0;
    var writes = 0;
    await pumpPage(
      tester,
      RepairDetailPage(
        loadRepairDetail: (_) async =>
            ++detailReads == 1 ? offeredRepair : replacementResult,
        submitReplacementChoice: (record, {slot, keep = false}) async {
          writes++;
          expect(keep, isTrue);
          expect(record.revision, offeredRepair.revision);
          throw const NetworkException('改约提议已失效', statusCode: 409);
        },
      ),
      arguments: offeredRepair.id,
    );

    await tester.ensureVisible(find.text('保持原时间，继续等'));
    await tester.tap(find.text('保持原时间，继续等'));
    await tester.pumpAndSettle();

    expect(writes, 1);
    expect(detailReads, 2);
    expect(find.text('提交成功后的详情'), findsOneWidget);
    expect(find.text('旧详情'), findsNothing);
    expect(find.text('保持原时间，继续等'), findsNothing);
    expect(find.text('改约提议已失效'), findsOneWidget);
    await finishPage(tester);
    expect(detailReads, 2);
  });

  testWidgets('replacement picker blocks a stale retry after a 409 refresh',
      (tester) async {
    var detailReads = 0;
    var writes = 0;
    await pumpPage(
      tester,
      RepairDetailPage(
        loadRepairDetail: (_) async =>
            ++detailReads == 1 ? offeredRepair : replacementResult,
        submitReplacementChoice: (record, {slot, keep = false}) async {
          writes++;
          expect(keep, isFalse);
          expect(record.revision, offeredRepair.revision);
          throw const NetworkException('改约提议已失效', statusCode: 409);
        },
        loadReplacementSlots: ({date, excludeId, repairItemId}) async =>
            slotsFixture(),
      ),
      arguments: offeredRepair.id,
    );

    await openReplacementPicker(tester);
    await selectAndConfirmReplacement(tester);
    expect(writes, 1);
    expect(detailReads, 2);
    expect(find.text('选择新的上门时间'), findsOneWidget);
    expect(find.text('提交成功后的详情'), findsOneWidget);
    expect(find.text('旧详情'), findsNothing);

    await selectAndConfirmReplacement(tester);
    expect(writes, 1);
    expect(find.text('工单状态已更新，请重新核对后再确认'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('late detail response cannot overwrite a successful replacement',
      (tester) async {
    final Completer<RepairRecord> staleDetail = Completer<RepairRecord>();
    final Completer<RepairRecord> submitResult = Completer<RepairRecord>();
    var detailReads = 0;
    await pumpPage(
      tester,
      RepairDetailPage(
        loadRepairDetail: (_) {
          detailReads++;
          return detailReads == 1
              ? Future<RepairRecord>.value(offeredRepair)
              : staleDetail.future;
        },
        submitReplacementChoice: (record, {slot, keep = false}) =>
            submitResult.future,
        loadReplacementSlots: ({date, excludeId, repairItemId}) async =>
            slotsFixture(),
      ),
      arguments: offeredRepair.id,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(detailReads, 2);

    await openReplacementPicker(tester);
    await tester.tap(find.byKey(const ValueKey('2030-10-20#10')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('确认改时间'));
    await tester.pump();
    submitResult.complete(replacementResult);
    await tester.pumpAndSettle();
    expect(find.text('提交成功后的详情'), findsOneWidget);

    staleDetail.complete(offeredRepair);
    await tester.pumpAndSettle();
    expect(find.text('提交成功后的详情'), findsOneWidget);
    expect(find.text('旧详情'), findsNothing);
    await finishPage(tester);
  });
}
