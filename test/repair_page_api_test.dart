import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/repair.dart';
import 'package:haven_hub/models/repair_page.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/logger.dart';
import 'package:haven_hub/utils/repair_list_preloader.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<Map<String, dynamic>> Function(RequestOptions) respond;
  final List<RequestOptions> requests = [];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(jsonEncode({'code': 10000, 'data': await respond(options)}), 200,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }
  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> response({int current = 1, int total = 47, int pageSize = 20, int status = 1, String filter = 'all'}) => {
  'filter': filter,
  'current': current, 'total': total, 'pageTotal': (total + pageSize - 1) ~/ pageSize,
  'rows': List.generate((total - (current - 1) * pageSize).clamp(0, pageSize), (index) => {
    'id': 'row-${(current - 1) * pageSize + index}', 'status': status,
  }),
};

RequestDio _client(_Adapter adapter) => RequestDio(client: Dio()..httpClientAdapter = adapter);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await tokenManager.loadTokens();
    Logger.enabled = false;
  });
  setUp(() async => tokenManager.setToken('page-account'));

  test('first page of 47 records requests only 20; further pages require explicit calls', () async {
    final adapter = _Adapter((options) => response(current: options.queryParameters['current'] as int));
    final api = _client(adapter);
    final first = await getRepairPageApi(client: api);
    expect(first.rows.length, 20);
    expect(first.total, 47);
    expect(first.hasMore, isTrue);
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.queryParameters, {'current': 1, 'pageSize': 20, 'filter': 'all'});
    expect(first.rows.clear, throwsUnsupportedError);
    final second = await getRepairPageApi(current: 2, client: api);
    expect(second.rows.first.id, 'row-20');
    expect(adapter.requests, hasLength(2));
    final third = await getRepairPageApi(current: 3, client: api);
    expect(third.rows.length, 7);
    expect(third.hasMore, isFalse);
    expect(adapter.requests.map((r) => r.queryParameters['current']), [1, 2, 3]);
    adapter.requests.clear();
    final legacy = await getRepairListApi(client: api);
    expect(legacy.map((record) => record.id), [...first.rows, ...second.rows, ...third.rows].map((record) => record.id));
    expect(legacy, hasLength(47));
    expect(adapter.requests, hasLength(3));
  });

  test('filters are sent to server and confirming belongs to processing', () async {
    for (final entry in {RepairStatusFilter.pending: 1, RepairStatusFilter.waiting: 5,
      RepairStatusFilter.processing: 6, RepairStatusFilter.completed: 3}.entries) {
      final adapter = _Adapter((_) => response(total: 1, status: entry.value, filter: entry.key.name));
      final page = await getRepairPageApi(filter: entry.key, client: _client(adapter));
      expect(page.rows.single.status, entry.value);
      expect(adapter.requests.single.queryParameters['filter'], entry.key.name);
    }
  });

  test('empty and out of range pages are complete without extra requests', () async {
    for (final total in [0, 1]) {
      final adapter = _Adapter((_) => response(current: 3, total: total));
      final page = await getRepairPageApi(current: 3, client: _client(adapter));
      expect(page.rows, isEmpty);
      expect(page.hasMore, isFalse);
      expect(adapter.requests, hasLength(1));
    }
  });

  test('malformed pages and unfiltered responses fail rather than pretending complete', () async {
    final invalidPages = <Map<String, dynamic>>[
      {...response(), 'total': -1}, {...response(), 'total': 'x'},
      {...response(), 'pageTotal': 1}, {...response(), 'current': 2},
      {...response()}..remove('current'), {...response()}..remove('total'),
      {...response(), 'rows': []},
      {...response(total: 1), 'rows': [{'id': '', 'status': 1}]},
      {...response(total: 2), 'rows': [{'id': 'same', 'status': 1}, {'id': 'same', 'status': 1}]},
      response(total: 1, status: 3),
    ];
    for (final data in invalidPages) {
      data['filter'] = 'pending';
      await expectLater(getRepairPageApi(filter: RepairStatusFilter.pending,
          client: _client(_Adapter((_) => data))), throwsFormatException);
    }
  });

  test('filtered pages require acknowledgement so older servers cannot silently ignore filters', () async {
    for (final acknowledged in [null, 'all', 'completed']) {
      final data = response(total: 1)..['filter'] = acknowledged;
      await expectLater(getRepairPageApi(filter: RepairStatusFilter.pending,
          client: _client(_Adapter((_) => data))), throwsFormatException);
    }
  });

  test('invalid paging arguments are rejected without sending a request', () async {
    final adapter = _Adapter((_) => response());
    for (final args in [(0, 20), (-1, 20), (1, 0), (1, 201)]) {
      await expectLater(getRepairPageApi(current: args.$1, pageSize: args.$2, client: _client(adapter)), throwsFormatException);
    }
    expect(adapter.requests, isEmpty);
  });

  test('account switch rejects a delayed page response', () async {
    final entered = Completer<void>();
    final delayed = Completer<Map<String, dynamic>>();
    final adapter = _Adapter((_) { entered.complete(); return delayed.future; });
    final pending = getRepairPageApi(client: _client(adapter));
    final assertion = expectLater(pending, throwsA(isA<SessionChangedException>()));
    await entered.future;
    await tokenManager.setToken('another-account');
    delayed.complete(response());
    await assertion;
    expect(adapter.requests, hasLength(1));
  });

  test('page preload joins one first-page request and is consumed only once', () async {
    final delayed = Completer<Map<String, dynamic>>();
    final adapter = _Adapter((_) => delayed.future);
    final api = _client(adapter);
    final preloader = RepairPreloader<RepairPage>(loader: () => getRepairPageApi(client: api));
    final warm = preloader.preload();
    final loaded = preloader.load();
    delayed.complete(response());
    await warm;
    expect((await loaded).rows.length, 20);
    expect(adapter.requests, hasLength(1));
    await preloader.load();
    expect(adapter.requests, hasLength(2));
  });

  test('page invalidation and expiry both fetch fresh first pages', () async {
    var now = DateTime(2026, 10, 28);
    final adapter = _Adapter((_) => response());
    final api = _client(adapter);
    final preloader = RepairPreloader<RepairPage>(loader: () => getRepairPageApi(client: api), now: () => now);
    await preloader.preload();
    preloader.invalidate();
    await preloader.load();
    expect(adapter.requests, hasLength(2));
    await preloader.preload();
    now = now.add(const Duration(seconds: 31));
    await preloader.load();
    expect(adapter.requests, hasLength(4));
  });
}
