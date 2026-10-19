import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/repair.dart';
import 'package:haven_hub/api/worker.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/logger.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RepairAdapter implements HttpClientAdapter {
  _RepairAdapter(this.response);

  final FutureOr<ResponseBody> Function(RequestOptions) response;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return response(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody page(List<String> ids,
        {int? total, int? pageTotal, int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(<String, dynamic>{
        'code': status == 200 ? 10000 : 500,
        'data': <String, dynamic>{
          'rows': ids.map((String id) => <String, dynamic>{'id': id}).toList(),
          if (total != null) 'total': total,
          if (pageTotal != null) 'pageTotal': pageTotal,
        },
      }),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late bool previousLoggerEnabled;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();
  });

  setUp(() {
    previousLoggerEnabled = Logger.enabled;
    Logger.enabled = false;
  });
  tearDown(() => Logger.enabled = previousLoggerEnabled);

  Future<List<String>> load(_RepairAdapter adapter) async =>
      (await getRepairListApi(
              client: RequestDio(client: Dio()..httpClientAdapter = adapter)))
          .map((record) => record.id)
          .toList();

  test('loads every page with current and pageSize, preserving server order',
      () async {
    final _RepairAdapter adapter = _RepairAdapter((RequestOptions options) {
      final int current = options.queryParameters['current'] as int;
      expect(options.method, 'GET');
      expect(options.path, 'repair');
      expect(options.queryParameters['pageSize'], 20);
      return page(current == 1 ? <String>['new', 'middle'] : <String>['old'],
          total: 3, pageTotal: 2);
    });
    expect(await load(adapter), <String>['new', 'middle', 'old']);
    expect(
        adapter.requests.map((r) => r.queryParameters['current']), <int>[1, 2]);
  });

  test('empty and legacy unpaginated responses stop after one request',
      () async {
    for (final ResponseBody response in <ResponseBody>[
      page(<String>[], total: 0, pageTotal: 0),
      page(<String>['legacy']),
    ]) {
      final _RepairAdapter adapter = _RepairAdapter((_) => response);
      await load(adapter);
      expect(adapter.requests, hasLength(1));
    }
  });

  test('a later HTTP failure never returns a partial history', () async {
    final _RepairAdapter adapter = _RepairAdapter((RequestOptions options) =>
        options.queryParameters['current'] == 1
            ? page(<String>['first'], total: 2, pageTotal: 2)
            : page(<String>[], status: 500));
    await expectLater(load(adapter), throwsA(isA<NetworkException>()));
    expect(adapter.requests, hasLength(2));
  });

  test('repeated pages fail without looping or duplicating records', () async {
    final _RepairAdapter adapter =
        _RepairAdapter((_) => page(<String>['same'], total: 3, pageTotal: 3));
    await expectLater(load(adapter), throwsA(isA<FormatException>()));
    expect(adapter.requests, hasLength(2));
  });

  test('truncated final page and missing pagination cannot look complete',
      () async {
    for (final int? pageTotal in <int?>[1, null]) {
      final _RepairAdapter adapter = _RepairAdapter(
          (_) => page(<String>['one'], total: 38, pageTotal: pageTotal));
      await expectLater(load(adapter), throwsA(isA<FormatException>()));
      expect(adapter.requests, hasLength(1));
    }
  });

  test('a session change between pages stops the old account history',
      () async {
    final _RepairAdapter adapter = _RepairAdapter((_) async {
      await tokenManager.deleteToken();
      return page(<String>['old-account'], total: 2, pageTotal: 2);
    });
    await expectLater(load(adapter), throwsA(isA<SessionChangedException>()));
    expect(adapter.requests, hasLength(1));
  });

  test('creation explicitly sends an empty attachment array without photos',
      () async {
    final _RepairAdapter adapter = _RepairAdapter((_) => page(<String>[]));
    const RepairRecord record = RepairRecord(
      houseId: '7177501402628096',
      repairItemId: '1001',
      mobile: '13800138008',
      appointment: '2026-10-10',
      description: 'test-marker',
    );
    await submitRepairApi(record,
        client: RequestDio(client: Dio()..httpClientAdapter = adapter));
    final RequestOptions request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.path, 'repair');
    expect(request.data, <String, dynamic>{
      ...record.toJson(),
      'attachment': <String>[],
    });
    expect(record.toJson()['attachment'], isEmpty);
  });

  test('cancellation uses the correct repair route and encodes the id',
      () async {
    final _RepairAdapter adapter = _RepairAdapter((_) => page(<String>[]));
    await cancelRepairApi('test/id',
        client: RequestDio(client: Dio()..httpClientAdapter = adapter));
    expect(adapter.requests.single.method, 'PUT');
    expect(adapter.requests.single.path, 'cancel/repair/test%2Fid');
    expect(adapter.requests.single.data, isNull);
  });

  test('P3 slot lookup forwards optional date and excludeId and rejects malformed data', () async {
    final adapter = _RepairAdapter((_) => ResponseBody.fromString(jsonEncode({
      'code':10000, 'data':{'today':'2030-10-20','dates':['2030-10-20'],'slots':[]}
    }),200,headers:{Headers.contentTypeHeader:[Headers.jsonContentType]}));
    final client = RequestDio(client: Dio()..httpClientAdapter=adapter);
    expect((await getRepairSlotsApi(client:client)).today,'2030-10-20');
    await getRepairSlotsApi(date:'2030-10-20',excludeId:'repair/id',client:client);
    expect(adapter.requests.first.path,'repair/slots');
    expect(adapter.requests.first.queryParameters,isEmpty);
    expect(adapter.requests.last.queryParameters,{'date':'2030-10-20','excludeId':'repair/id'});
    expect(() => RepairSlots.fromJson({'today':null,'dates':[],'slots':[]}),throwsFormatException);
  });

  test('P3 creation sends chosen slot or urgent ASAP without legacy date fields', () async {
    for(final record in [const RepairRecord(slot:'2030-10-20#10'),const RepairRecord(urgentRequest:true,asap:true)]) {
      final adapter=_RepairAdapter((_) => page([]));
      await submitRepairApi(record,client:RequestDio(client:Dio()..httpClientAdapter=adapter));
      final data=adapter.requests.single.data as Map;
      expect(data['slot'],record.slot); expect(data['urgentRequest'],record.urgentRequest); expect(data['asap'],record.asap);
      expect(data.containsKey('expectedTime'),isFalse); expect(data.containsKey('appointment'),isFalse);
    }
  });

  test('P3 resident and worker actions use slot notified revision and existing response route', () async {
    final adapter=_RepairAdapter((_) => ResponseBody.fromString(jsonEncode({'code':10000,'data':{'id':'p3'}}),200,
      headers:{Headers.contentTypeHeader:[Headers.jsonContentType]}));
    final client=RequestDio(client:Dio()..httpClientAdapter=adapter);
    const record=RepairRecord(id:'p3',revision:7);
    await proposeRescheduleApi(record,'2030-10-20#10',' 原因 ',client:client);
    await proposeWorkerRescheduleApi(record,'2030-10-20#10',' 原因 ',client:client);
    for(final request in adapter.requests) {
      expect(request.method,'POST');
      expect(request.data,{'revision':7,'slot':'2030-10-20#10','reason':'原因','notified':true});
    }
    expect(adapter.requests[0].path,'repair/p3/reschedule');
    expect(adapter.requests[1].path,'worker/repairs/p3/reschedule');
    for(final accept in [true,false]) {
      await respondRescheduleApi(record,accept:accept,reason:accept?'':'不在家',client:client);
      expect(adapter.requests.last.method,'PUT'); expect(adapter.requests.last.path,'repair/p3/reschedule');
      expect(adapter.requests.last.data,{'revision':7,'accept':accept,'reason':accept?'':'不在家'});
    }
    await processWorkerRepairApi(record,complete:false,client:client);
    expect(adapter.requests.last.data,{'revision':7});
    await processWorkerRepairApi(record,complete:false,slot:'2030-10-20#10',reason:' 电话已沟通 ',client:client);
    expect(adapter.requests.last.data,{'revision':7,'slot':'2030-10-20#10','reason':'电话已沟通'});
    await workerProgressApi(record,' 请协助 ',needsAdmin:true,client:client);
    expect(adapter.requests.last.path,'worker/repairs/p3/progress');
    expect(adapter.requests.last.data,{'revision':7,'content':'请协助','needsAdmin':true});
  });
}
