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
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/logger.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/widget_harness.dart';
import 'repair_flow_test.dart' show form, fillRepair;
import 'repair_schedule_phase3_test.dart' show tapText, tallPage;

const _reason = '该时段已约满，请重新选择';
const _warning = '$_reason，已刷新最新状态';
const _time = '2030-10-20T10:00:00+08:00';
const _slot = '2030-10-20#10';
const _pending = RepairRecord(id: 'review', status: 2, pendingSchedule:
  RepairPending(kind: 'reschedule', by: 'worker', firstSchedule: true,
    proposedSlot: _slot, proposedTime: _time));

class _ResponseAdapter implements HttpClientAdapter {
  _ResponseAdapter(this.status, this.body);
  final int status;
  final Object body;
  int calls = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    return ResponseBody.fromString(jsonEncode(body), status, headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }
  @override
  void close({bool force = false}) {}
}

RequestDio _client(_ResponseAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  addTearDown(() => dio.close(force: true));
  return RequestDio(client: dio);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await tokenManager.init();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final previous = Logger.enabled;
    Logger.enabled = false;
    addTearDown(() => Logger.enabled = previous);
  });

  test('review HTTP 409 preserves backend message and status without replay', () async {
    final adapter = _ResponseAdapter(409, {'code': 40900, 'message': _reason});
    await expectLater(_client(adapter).put('repair/review/reschedule', data: {'accept': true}),
      throwsA(isA<NetworkException>().having((e) => e.message, 'message', _reason).having((e) => e.statusCode, 'statusCode', 409)));
    expect(adapter.calls, 1);
  });

  for (final body in <Object>[{'code': 40900}, {'code': 40900, 'message': ''}, {'code': 40900, 'message': '   '}, {'code': 40900, 'message': null}, {'code': 40900, 'message': 9}, 'not an envelope']) {
    test('review HTTP 409 fallback for $body', () async {
      await expectLater(_client(_ResponseAdapter(409, body)).get('repair/review'),
        throwsA(isA<NetworkException>().having((e) => e.message, 'message', '数据冲突，请刷新后重试').having((e) => e.statusCode, 'statusCode', 409)));
    });
  }
  test('review other HTTP statuses keep fixed mapping', () async {
    for (final entry in {400: '请求参数有误，请检查输入', 403: '您没有权限执行此操作', 404: '请求的接口不存在', 500: '服务器内部错误，请稍后重试'}.entries) {
      await expectLater(_client(_ResponseAdapter(entry.key, {'code': 40900, 'message': _reason})).get('repair/review'),
        throwsA(isA<NetworkException>().having((e) => e.message, 'message', entry.value).having((e) => e.statusCode, 'statusCode', entry.key)));
    }
  });

  testWidgets('review resident detail shows real RequestDio 409 and reloads', (tester) async {
    tallPage(tester);
    int loads = 0;
    final adapter = _ResponseAdapter(409, {'code': 40900, 'message': _reason});
    final client = _client(adapter);
    await pumpPage(tester, RepairDetailPage(loader: (_) async { loads++; return _pending; },
      actionLoader: (record, action) => respondRescheduleApi(record, accept: true, client: client)), arguments: 'review');
    await tapText(tester, '同意');
    expect(find.text(_warning), findsOneWidget);
    expect(loads, 2); expect(adapter.calls, 1);
    await finishPage(tester);
  });

  testWidgets('review resident form shows real RequestDio 409 and retains input', (tester) async {
    tallPage(tester);
    final adapter = _ResponseAdapter(409, {'code': 40900, 'message': _reason});
    final client = _client(adapter);
    await pumpPage(tester, form((record) => submitRepairApi(record, client: client)));
    await fillRepair(tester);
    await tapText(tester, '提交报修');
    expect(find.text(_warning), findsOneWidget);
    expect(find.text('水管漏水'), findsOneWidget); expect(adapter.calls, 1);
    await finishPage(tester);
  });

  testWidgets('review worker action shows real RequestDio 409 and reloads', (tester) async {
    tallPage(tester); int loads = 0;
    final adapter = _ResponseAdapter(409, {'code': 40900, 'message': _reason});
    final client = _client(adapter);
    await pumpPage(tester, WorkerDetailPage(id: 'review', recordLoader: (_) async { loads++; return const RepairRecord(id: 'review', status: 2, agreedTime: _time, slot: _slot); },
      actionLoader: (record, action) => workerProgressApi(record, (action as WorkerProgressAction).content, client: client)));
    await tapText(tester, '补充进展');
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), '保留进展');
    await tapText(tester, '提交进展');
    expect(find.text(_warning), findsOneWidget); expect(loads, 2); expect(adapter.calls, 1);
    await finishPage(tester);
  });

  for (final worker in [false, true]) {
    for (final status in [1, 5, 2]) {
      testWidgets('review ${worker ? 'worker' : 'resident'} active status $status retains schedule', (tester) async {
        tallPage(tester);
        final record = RepairRecord(id: 'review', status: status, agreedTime: _time, slot: _slot);
        await pumpPage(tester, worker ? WorkerDetailPage(id: 'review', recordLoader: (_) async => record)
          : RepairDetailPage(loader: (_) async => record), arguments: 'review');
        expect(find.text('已约定'), findsOneWidget);
        await finishPage(tester);
      });
    }
    for (final status in [0, 3, 4, 6]) {
      testWidgets('review ${worker ? 'worker' : 'resident'} status $status hides current arrangement', (tester) async {
        tallPage(tester);
        final record = RepairRecord(id: 'review', status: status, agreedTime: _time, slot: _slot);
        await pumpPage(tester, worker ? WorkerDetailPage(id: 'review', recordLoader: (_) async => record)
          : RepairDetailPage(loader: (_) async => record), arguments: 'review');
        expect(find.text('已约定'), findsNothing);
        expect(find.textContaining('10月20日'), findsWidgets);
        await finishPage(tester);
      });
    }
    testWidgets('review ${worker ? 'worker' : 'resident'} auto acceptance copy matches role', (tester) async {
      tallPage(tester);
      const record = RepairRecord(id: 'review', status: 2, agreedTime: _time, slot: _slot, autoAccepted: true);
      await pumpPage(tester, worker ? WorkerDetailPage(id: 'review', recordLoader: (_) async => record)
        : RepairDetailPage(loader: (_) async => record), arguments: 'review');
      expect(find.textContaining(worker ? '住户未主动确认，请先电话确认' : '确认期限已过，该时段已自动生效；如不方便可点下方按钮反馈'), findsOneWidget);
      if (!worker) expect(find.textContaining('住户未主动确认'), findsNothing);
      await finishPage(tester);
    });
    testWidgets('review ${worker ? 'worker' : 'resident'} empty proposal reason stays hidden', (tester) async {
      tallPage(tester);
      await pumpPage(tester, worker ? WorkerDetailPage(id: 'review', recordLoader: (_) async => _pending)
        : RepairDetailPage(loader: (_) async => _pending), arguments: 'review');
      expect(find.textContaining('原因：'), findsNothing);
      await finishPage(tester);
    });
  }
  for (final first in [true, false, null]) {
    testWidgets('review urgent dispatch firstSchedule=$first controls property title', (tester) async {
      tallPage(tester);
      final record = RepairRecord.fromJson({'id': 'review', 'status': 2, 'agreedTime': _time, 'slot': _slot,
        'timeline': [{'action': 'urgent_dispatched', 'label': '物业调度急单', 'detail': '任意描述，不解析此文案', 'firstSchedule': first}]});
      await pumpPage(tester, RepairDetailPage(loader: (_) async => record), arguments: 'review');
      expect(find.text(first == false ? '物业已调整时间' : '物业已安排上门时间'), findsOneWidget);
      await finishPage(tester);
    });
  }
}
