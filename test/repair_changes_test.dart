import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/data_state.dart';
import 'package:haven_hub/utils/retry_strategy.dart';

import 'helpers/widget_harness.dart';

const List<RepairRecord> records = <RepairRecord>[
  RepairRecord(id: 'pending', repairItemName: 'Pending repair', status: 1),
  RepairRecord(
      id: 'processing', repairItemName: 'Processing repair', status: 2),
  RepairRecord(id: 'completed', repairItemName: 'Completed repair', status: 3),
  RepairRecord(id: 'cancelled', repairItemName: 'Cancelled repair', status: 4),
];

Finder filter(RepairStatusFilter value) => find
    .descendant(
      of: find.byType(GestureDetector),
      matching: find.text(value.displayName),
    )
    .first;

void main() {
  test('data state preserves records through loading and failure', () {
    final DataState<List<RepairRecord>> success = DataState.success(records);
    final DataState<List<RepairRecord>> loading =
        DataState.loading(success.data);
    final DataState<List<RepairRecord>> failure =
        DataState.error('Refresh failed', loading.data);
    expect(loading.isLoading, isTrue);
    expect(failure.hasData, isTrue);
    expect(failure.data, same(records));
    expect(failure.hasError, isTrue);
  });

  testWidgets('status filters show matching records without reloading',
      (WidgetTester tester) async {
    int calls = 0;
    await pumpPage(tester, RepairListPage(loader: () async {
      calls++;
      return records;
    }));
    const Map<RepairStatusFilter, List<String>> expectedIds =
        <RepairStatusFilter, List<String>>{
      RepairStatusFilter.all: <String>[
        'pending',
        'processing',
        'completed',
        'cancelled'
      ],
      RepairStatusFilter.pending: <String>['pending'],
      RepairStatusFilter.processing: <String>['processing'],
      RepairStatusFilter.completed: <String>['completed'],
    };
    for (final RepairStatusFilter value in RepairStatusFilter.values) {
      await tester.tap(filter(value));
      await tester.pumpAndSettle();
      for (final RepairRecord record in records) {
        expect(
            find.text(record.repairItemName),
            expectedIds[value]!.contains(record.id)
                ? findsOneWidget
                : findsNothing);
      }
    }
    expect(calls, 1);
    await finishPage(tester);
  });

  testWidgets('refresh updates cached results while preserving chosen filter',
      (WidgetTester tester) async {
    List<RepairRecord> response = records;
    await pumpPage(tester, RepairListPage(loader: () async => response));
    await tester.tap(filter(RepairStatusFilter.pending));
    await tester.pumpAndSettle();
    response = const <RepairRecord>[
      RepairRecord(id: 'new', repairItemName: 'New pending repair', status: 1),
      RepairRecord(
          id: 'done', repairItemName: 'New completed repair', status: 3),
    ];
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    expect(find.text('New pending repair'), findsOneWidget);
    expect(find.text('Pending repair'), findsNothing);
    expect(find.text('New completed repair'), findsNothing);
    await finishPage(tester);
  });

  testWidgets('records displayed as pending remain in the pending filter',
      (WidgetTester tester) async {
    const RepairRecord legacy =
        RepairRecord(id: 'legacy', repairItemName: 'Legacy pending repair');
    expect(legacy.statusText, RepairStatusFilter.pending.displayName);
    await pumpPage(tester,
        RepairListPage(loader: () async => const <RepairRecord>[legacy]));
    expect(find.text(legacy.repairItemName), findsOneWidget);
    await tester.tap(filter(RepairStatusFilter.pending));
    await tester.pumpAndSettle();
    expect(find.text(legacy.repairItemName), findsOneWidget);
    await finishPage(tester);
  });

  for (final double width in <double>[320, 360]) {
    testWidgets('filter row fits a $width logical pixel phone',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpPage(tester, RepairListPage(loader: () async => records));
      expect(tester.takeException(), isNull);
      await finishPage(tester);
    });
  }

  testWidgets('localized network timeout retries and recovers',
      (WidgetTester tester) async {
    int calls = 0;
    await pumpPage(tester, RepairListPage(loader: () async {
      calls++;
      if (calls == 1) {
        throw const NetworkException('连接服务器超时，请检查网络', isTimeout: true);
      }
      return records;
    }));
    expect(calls, 2);
    expect(find.text('Pending repair'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('gateway failures exhaust auto and manual retry budgets',
      (WidgetTester tester) async {
    int calls = 0;
    await pumpPage(tester, RepairListPage(loader: () async {
      calls++;
      throw const NetworkException('Gateway failure', statusCode: 503);
    }));
    expect(calls, RetryStrategy.auto.maxAttempts);
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(calls,
        RetryStrategy.auto.maxAttempts + RetryStrategy.manual.maxAttempts);
    await finishPage(tester);
  });

  testWidgets('business failures fail fast', (WidgetTester tester) async {
    int calls = 0;
    await pumpPage(tester, RepairListPage(loader: () async {
      calls++;
      throw const BusinessException('Permission denied', code: 403);
    }));
    expect(calls, 1);
    expect(find.text('重新加载'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('leaving the list stops scheduled retry requests',
      (WidgetTester tester) async {
    final Completer<List<RepairRecord>> firstResponse =
        Completer<List<RepairRecord>>();
    int calls = 0;
    await tester.pumpWidget(MaterialApp(
      home: RepairListPage(loader: () {
        calls++;
        return firstResponse.future;
      }),
    ));
    firstResponse.completeError(
        const NetworkException('Gateway failure', statusCode: 503));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    for (final int delay in <int>[500, 1000, 2000]) {
      await tester.pump(Duration(milliseconds: delay));
    }
    expect(tester.takeException(), isNull);
    expect(calls, 1);
  });
}
