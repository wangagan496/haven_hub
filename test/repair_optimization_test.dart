import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/repair.dart';
import 'package:haven_hub/api/worker.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/pages/worker/worker_pages.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/widget_harness.dart';

class _ResultAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> bodies = [];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    expect(options.path, 'worker/repairs/rework/result');
    expect(options.method, 'PUT');
    bodies.add(Map<String, dynamic>.from(options.data as Map));
    return ResponseBody.fromString(jsonEncode({'code': 10000, 'data': {'id': 'rework', 'status': 2, 'round': 3}}), 200,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }
  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await tokenManager.init();
  });
  testWidgets('rework progress and ready buttons send distinct ready flags and stay on detail', (tester) async {
    const record = RepairRecord(id: 'rework', status: 2, round: 3,
      rounds: [RepairRound(number: 3, problem: '接头仍渗水', cause: '待排查')]);
    final adapter = _ResultAdapter();
    final client = RequestDio(client: Dio()..httpClientAdapter = adapter);
    await pumpPage(tester, WorkerDetailPage(id: 'rework',
      recordLoader: (_) async => record,
      resultSaver: (record, {required ready, required result, required cost, problem, cause}) async {
        expect(result, '密封圈老化，上次未拆检，现已更换并试水');
        return processWorkerRepairApi(record, complete: true, saveOnly: true,
            ready: ready, result: result, cost: cost, problem: problem, cause: cause, client: client);
      }));
    final cause = find.widgetWithText(TextField, '重新排查原因（含上次未查出的原因）');
    await tester.scrollUntilVisible(cause, 180, scrollable: find.byType(Scrollable).first);
    await tester.enterText(cause, '密封圈老化，上次未拆检，现已更换并试水');
    expect(find.widgetWithText(TextField, '修了什么（必填）'), findsNothing);
    for (final label in ['保存进度', '保存结果，供现场业主确认']) {
      final save = find.text(label);
      await tester.scrollUntilVisible(save, 180, scrollable: find.byType(Scrollable).first);
      await tester.tap(save);
      await tester.pumpAndSettle();
    }
    expect(adapter.bodies.map((body) => body['ready']), [false, true]);
    expect(find.byType(WorkerDetailPage), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('new worker sees empty result and default cost after reassignment', (tester) async {
    final record = RepairRecord.fromJson({'id': 'reassigned', 'status': 2, 'round': 1,
      'completionNote': '', 'resultReady': false, 'workerId': 'new-worker',
      'rounds': [{'number': 1, 'note': '', 'cost': null, 'cause': '待排查', 'problem': '漏水'}],
      'timeline': [{'action': 'result_ready', 'label': '前任保存', 'detail': '前任结果；上报费用 99 元'}]});
    await pumpPage(tester, WorkerDetailPage(id: record.id, recordLoader: (_) async => record));
    for (final entry in {'修了什么（必填）': '', '费用（元）': '0'}.entries) {
      final field = find.widgetWithText(TextField, entry.key);
      await tester.scrollUntilVisible(field, 180, scrollable: find.byType(Scrollable).first);
      expect(tester.widget<TextField>(field).controller!.text, entry.value);
    }
    await finishPage(tester);
  });

  testWidgets('owner may confirm an onsite result while still processing', (tester) async {
    var calls = 0;
    await pumpPage(tester, RepairDetailPage(
      loader: (_) async => const RepairRecord(id: 'onsite', workflowVersion: 1, status: 2, resultReady: true,
        completionNote: '更换水管并复测', rounds: [RepairRound(number: 1, note: '更换水管并复测', cost: 19)]),
      actionLoader: (_, action) async {
        expect(action, isA<ConfirmAction>()); calls++;
        return const RepairRecord(id: 'onsite', status: 3);
      }), arguments: 'onsite');
    expect(find.text('维修结果已保存，现场检查后可直接确认修好'), findsOneWidget);
    await tester.tap(find.text('确认修好'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认修好').last);
    await tester.pumpAndSettle();
    expect(calls, 1);
    await finishPage(tester);
  });
  test('rework retains follow-up actions after the second round and fees parse independently', () {
    final current = RepairRecord.fromJson({'status': 6, 'round': 4, 'reworkUsed': true,
      'rounds': [{'number': 4, 'problem': '再次漏水', 'cause': '待排查'}],
      'fees': [{'number': 1, 'cost': 25}, {'number': 3, 'cost': 12}]});
    expect(current.canReject, isTrue);
    expect(current.round, 4);
    expect(current.rounds.single.cause, '待排查');
    expect(current.fees.map((f) => f.cost), [25, 12]);
    expect(const RepairRecord(status: 2).canConfirm, isFalse);
    expect(const RepairRecord(status: 3, reworkUsed: true, warrantyEnd: '2030-01-01').canApplyAftersale, isTrue);
  });
}
