import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';

import 'helpers/widget_harness.dart';

const RepairRecord pendingRepair = RepairRecord(
  id: 'repair-test',
  houseId: 'house-test',
  repairItemId: 'item-test',
  repairItemName: '水管维修',
  status: 1,
  mobile: '13800138000',
);

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
  await tester.tap(find.text('请选择预约日期'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('确定'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextFormField).last, '水管漏水');
  await tester.ensureVisible(find.text('提交报修'));
}

RepairFormPage form(Future<void> Function(RepairRecord) submitter) =>
    RepairFormPage(
      houseLoader: () async => const <House>[
        House(id: 'house-test', point: '测试小区', building: '1栋', room: '101'),
      ],
      itemLoader: () async =>
          const <RepairItem>[RepairItem(id: 'item-test', name: '水管维修')],
      submitter: submitter,
    );

void main() {
  testWidgets('submit success returns to list and fetches the new record',
      (WidgetTester tester) async {
    bool submitted = false;
    int loads = 0;
    await pumpPage(tester, RepairListPage(loader: () async {
      loads++;
      return <RepairRecord>[if (submitted) pendingRepair];
    }), routes: <String, WidgetBuilder>{
      RepairFormPage.routeName: (_) => form((_) async {
            submitted = true;
          }),
    });
    expect(find.text('暂无报修记录'), findsOneWidget);
    await tester.tap(find.text('新增报修'));
    await tester.pumpAndSettle();
    await fillRepair(tester);
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(find.text('水管维修'), findsOneWidget);
    expect(find.text('暂无报修记录'), findsNothing);
    await finishPage(tester);
  });

  testWidgets('leaving during submission ignores late success and failure',
      (WidgetTester tester) async {
    for (final bool fail in <bool>[true, false]) {
      final Completer<void> response = Completer<void>();
      await pumpPage(tester, const Scaffold(body: Text('其他页面')),
          routes: <String, WidgetBuilder>{
            RepairFormPage.routeName: (_) => form((_) => response.future),
          });
      unawaited(GlobalVariable.navigatorKey.currentState!
          .pushNamed<void>(RepairFormPage.routeName));
      await tester.pumpAndSettle();
      await fillRepair(tester);
      await tester.tap(find.text('提交报修'));
      await tester.pump();
      GlobalVariable.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      if (fail) {
        response.completeError(const NetworkException('迟到的提交错误'));
      } else {
        response.complete();
      }
      await tester.pumpAndSettle();
      expect(find.text('其他页面'), findsOneWidget);
      expect(find.text('迟到的提交错误'), findsNothing);
      expect(find.text('报修提交成功'), findsNothing);
      expect(tester.takeException(), isNull);
      await finishPage(tester);
    }
  });

  testWidgets('rapid cancel taps open only one confirmation dialog',
      (WidgetTester tester) async {
    int calls = 0;
    await pumpPage(
        tester,
        RepairDetailPage(
          loader: (_) async => pendingRepair,
          cancelLoader: (_) async {
            calls++;
          },
        ),
        arguments: pendingRepair.id);
    final VoidCallback cancel = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '取消报修'))
        .onPressed!;
    cancel();
    cancel();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog, skipOffstage: false), findsOneWidget);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '取消报修'))
            .onPressed,
        isNotNull);
    await finishPage(tester);
  });

  testWidgets('cancel success reloads the list with server status',
      (WidgetTester tester) async {
    bool cancelled = false;
    int loads = 0;
    await pumpPage(tester, RepairListPage(loader: () async {
      loads++;
      return <RepairRecord>[
        if (cancelled)
          const RepairRecord(
              id: 'repair-test', repairItemName: '水管维修', status: 4)
        else
          pendingRepair,
      ];
    }), routes: <String, WidgetBuilder>{
      RepairDetailPage.routeName: (_) => RepairDetailPage(
            loader: (_) async => pendingRepair,
            cancelLoader: (_) async {
              cancelled = true;
            },
          ),
    });
    await tester.tap(find.text('水管维修'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消报修'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认取消'));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(find.text('已取消'), findsOneWidget);
    expect(find.text('待处理'), findsNothing);
    await finishPage(tester);
  });

  testWidgets('list error can retry and refresh failure preserves records',
      (WidgetTester tester) async {
    int loads = 0;
    await pumpPage(tester, RepairListPage(loader: () async {
      loads++;
      if (loads != 2) throw const NetworkException('测试网络失败');
      return const <RepairRecord>[pendingRepair];
    }));
    expect(find.text('重新加载'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(find.text('水管维修'), findsOneWidget);
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    expect(find.text('水管维修'), findsOneWidget);
    expect(find.text('重新加载'), findsNothing);
    await finishPage(tester);
  });

  testWidgets('invalid form makes no request', (WidgetTester tester) async {
    int calls = 0;
    await pumpPage(tester, form((_) async {
      calls++;
    }));
    await tester.ensureVisible(find.text('提交报修'));
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('请选择报修房屋'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets(
      'duplicate submit is suppressed and failure retains form for retry',
      (WidgetTester tester) async {
    final Completer<void> response = Completer<void>();
    final List<RepairRecord> requests = <RepairRecord>[];
    await pumpPage(tester, form((RepairRecord record) {
      requests.add(record);
      return response.future;
    }));
    await fillRepair(tester);
    final VoidCallback submit = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '提交报修'))
        .onPressed!;
    submit();
    submit();
    await tester.pump();
    expect(requests, hasLength(1));
    response.completeError(const BusinessException('测试提交失败'));
    await tester.pumpAndSettle();
    expect(find.text('水管漏水'), findsOneWidget);
    expect(find.text('13800138000'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交报修'))
            .onPressed,
        isNotNull);
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(2));
    expect(requests.last.houseId, 'house-test');
    expect(requests.last.repairItemId, 'item-test');
    await finishPage(tester);
  });

  testWidgets('late cancellation failure does not toast on another page',
      (WidgetTester tester) async {
    final Completer<void> response = Completer<void>();
    await pumpPage(tester, const Scaffold(body: Text('其他页面')),
        routes: <String, WidgetBuilder>{
          RepairDetailPage.routeName: (_) => RepairDetailPage(
                loader: (_) async => pendingRepair,
                cancelLoader: (_) => response.future,
              ),
        });
    unawaited(GlobalVariable.navigatorKey.currentState!.pushNamed<void>(
        RepairDetailPage.routeName,
        arguments: pendingRepair.id));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消报修'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认取消'));
    await tester.pump();
    GlobalVariable.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    response.completeError(const NetworkException('迟到的取消错误'));
    await tester.pumpAndSettle();
    expect(find.text('其他页面'), findsOneWidget);
    expect(find.text('迟到的取消错误'), findsNothing);
    expect(tester.takeException(), isNull);
    await finishPage(tester);
  });

  testWidgets('cancel failure allows retry and completed repair cannot cancel',
      (WidgetTester tester) async {
    int calls = 0;
    await pumpPage(
        tester,
        RepairDetailPage(
          loader: (_) async => pendingRepair,
          cancelLoader: (_) async {
            calls++;
            throw const NetworkException('取消失败');
          },
        ),
        arguments: pendingRepair.id);
    for (int attempt = 0; attempt < 2; attempt++) {
      await tester.tap(find.text('取消报修'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认取消'));
      await tester.pumpAndSettle();
      expect(find.text('报修详情'), findsOneWidget);
    }
    expect(calls, 2);
    await finishPage(tester);
    await pumpPage(
        tester,
        RepairDetailPage(
          loader: (_) async => const RepairRecord(id: 'done', status: 3),
        ),
        arguments: 'done');
    expect(find.text('取消报修'), findsNothing);
    await finishPage(tester);
  });
}
