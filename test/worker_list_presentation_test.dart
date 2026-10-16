import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/worker/worker_pages.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/utils/worker_repair_read_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();
  });
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  for (final width in <double>[320, 1800]) {
    testWidgets('distinct descriptions and status filtering at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = <RepairRecord>[
        for (final status in [5, 2, 3])
          RepairRecord(
            id: 'repair-$status',
            status: status,
            repairItemName: '水电维修',
            houseInfo: '丹桂苑 2幢 3层 302',
            description: '故障原因$status：水龙头关闭后仍然持续滴水，需要检查密封圈。',
            appointment: '2026-10-16',
          ),
      ];
      await tester.pumpWidget(MaterialApp(
          home: WorkerPage(
              recordsLoader: () async => records,
              readStore: WorkerRepairReadStore())));
      await tester.pumpAndSettle();
      for (final entry in {5: '待接单', 2: '处理中', 3: '已完成'}.entries) {
        expect(find.text('${entry.value}（1）'), findsNothing);
        expect(find.byKey(ValueKey('worker-status-dot-${entry.key}')),
            entry.key == 3 ? findsNothing : findsOneWidget);
        await tester.tap(find.text(entry.value));
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey('repair-${entry.key}')), findsOneWidget);
        expect(find.byKey(ValueKey('worker-record-dot-repair-${entry.key}')),
            entry.key == 3 ? findsNothing : findsOneWidget);
        expect(
            find.text(
                records.firstWhere((r) => r.status == entry.key).description),
            findsOneWidget);
        for (final record in records.where((r) => r.status != entry.key)) {
          expect(find.text(record.description), findsNothing);
        }
        expect(tester.takeException(), isNull);
      }
      records.clear();
      await tester.tap(find.byTooltip('刷新工单'));
      await tester.pumpAndSettle();
      for (final status in [5, 2, 3]) {
        expect(find.byKey(ValueKey('worker-status-dot-$status')), findsNothing);
      }
      expect(find.text('当前没有此状态的工单'), findsOneWidget);
    });
  }

  testWidgets('viewing each detail clears only its dot and persists on reopen',
      (tester) async {
    final records = <RepairRecord>[
      for (final id in ['first', 'second'])
        RepairRecord(id: id, workerId: 'worker-a', status: 5, revision: 1),
      const RepairRecord(id: 'active', workerId: 'worker-a', status: 2),
      const RepairRecord(id: 'done', workerId: 'worker-a', status: 3),
    ];
    Widget app() => MaterialApp(
          home: WorkerPage(
            recordsLoader: () async => records,
            recordLoader: (id) async => records.firstWhere((r) => r.id == id),
            readStore: WorkerRepairReadStore(),
          ),
        );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    // Selecting a category alone does not acknowledge its orders.
    await tester.tap(find.text('处理中'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('worker-record-dot-active')), findsOneWidget);
    await tester.tap(find.text('待接单'));
    await tester.pumpAndSettle();
    for (final id in ['first', 'second']) {
      await tester.tap(find.byKey(ValueKey(id)));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('worker-record-dot-$id')), findsNothing);
      expect(find.byKey(const ValueKey('worker-status-dot-5')),
          id == 'first' ? findsOneWidget : findsNothing);
    }
    expect(find.byKey(const ValueKey('worker-status-dot-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('worker-status-dot-3')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('worker-status-dot-5')), findsNothing);
    records[0] = const RepairRecord(
        id: 'first', workerId: 'worker-a', status: 5, revision: 2);
    await tester.tap(find.byTooltip('刷新工单'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('worker-status-dot-5')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('worker-record-dot-first')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('worker-record-dot-second')), findsNothing);
  });

  testWidgets('failed detail and leaving before loading keep the order unread',
      (tester) async {
    const record = RepairRecord(id: 'failed', workerId: 'worker-a', status: 5);
    final pending = Completer<RepairRecord>();
    bool fail = true;
    final store = WorkerRepairReadStore();
    await tester.pumpWidget(MaterialApp(
      home: WorkerPage(
        recordsLoader: () async => [record],
        recordLoader: (_) {
          if (fail) throw const FormatException('详情加载失败');
          return pending.future;
        },
        readStore: store,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('failed')));
    await tester.pumpAndSettle();
    expect(find.text('详情加载失败'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('worker-record-dot-failed')), findsOneWidget);
    fail = false;
    await tester.tap(find.byKey(const ValueKey('failed')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pageBack();
    await tester.pumpAndSettle();
    pending.complete(record);
    await tester.pumpAndSettle();
    expect(await store.unreadIds([record]), {'failed'});
    expect(tester.takeException(), isNull);
  });
}
