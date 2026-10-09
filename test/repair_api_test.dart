import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/repair.dart';
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
    expect(record.toJson().containsKey('attachment'), isFalse);
  });

  test('cancellation uses the verified repaire route and encodes the id',
      () async {
    final _RepairAdapter adapter = _RepairAdapter((_) => page(<String>[]));
    await cancelRepairApi('test/id',
        client: RequestDio(client: Dio()..httpClientAdapter = adapter));
    expect(adapter.requests.single.method, 'PUT');
    expect(adapter.requests.single.path, 'cancel/repaire/test%2Fid');
    expect(adapter.requests.single.data, isNull);
  });
}
