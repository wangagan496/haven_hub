import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/house.dart';
import 'package:haven_hub/api/repair.dart';
import 'package:haven_hub/api/visitor.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/models/visitor.dart';
import 'package:haven_hub/pages/house/house_detail.dart';
import 'package:haven_hub/pages/house/house_list.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/pages/visitor/visitor_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/logger.dart';
import 'package:haven_hub/utils/mutation_list.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/widget_harness.dart';

Map<String, dynamic> complete(List<Map<String, dynamic>> rows) =>
    <String, dynamic>{'complete': true, 'rows': rows, 'total': rows.length};

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final dynamic Function(RequestOptions) reply;
  final List<RequestOptions> requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(
        jsonEncode(<String, dynamic>{'code': 10000, 'data': reply(options)}),
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType]
        });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();
    Logger.enabled = false;
  });
  setUp(() async {
    await tokenManager.setToken('local-test');
    repairListPreloader.invalidate();
  });

  test('complete mutation list is consumed once; manual reload fetches again',
      () async {
    final cache = MutationList<House>(House.fromJson);
    int reads = 0;
    Future<List<House>> fetch() async {
      reads++;
      return const <House>[House(id: 'remote')];
    }

    await cache.write(() async => complete(<Map<String, dynamic>>[
          <String, dynamic>{'id': 'saved'}
        ]));
    expect((await cache.load(fetch)).single.id, 'saved');
    expect(reads, 0);
    expect((await cache.load(fetch)).single.id, 'remote');
    expect(reads, 1);
    await cache.write(() async => complete(<Map<String, dynamic>>[]));
    expect(await cache.load(fetch), isEmpty);
    expect(reads, 1,
        reason: 'deleting the last item is an authoritative empty list');
  });

  test(
      'legacy, truncated and duplicate lists fall back without failing the write',
      () async {
    final cache = MutationList<House>(House.fromJson);
    final rows = <Map<String, dynamic>>[
      <String, dynamic>{'id': 'one'}
    ];
    for (final dynamic response in <dynamic>[
      null,
      <String, dynamic>{'rows': rows},
      <String, dynamic>{...complete(rows), 'total': 20},
      complete(<Map<String, dynamic>>[...rows, ...rows]),
      complete(<Map<String, dynamic>>[
        <String, dynamic>{'id': ''}
      ]),
    ]) {
      await cache.write(() async => response);
      int reads = 0;
      await cache.load(() async {
        reads++;
        return <House>[];
      });
      expect(reads, 1);
    }
  });

  test('old account responses and expired snapshots cannot be reused',
      () async {
    DateTime now = DateTime(2026);
    final cache = MutationList<House>(House.fromJson, now: () => now);
    await cache.write(() async => complete(<Map<String, dynamic>>[
          <String, dynamic>{'id': 'old'}
        ]));
    now = now.add(const Duration(seconds: 31));
    expect(cache.pending, isNull);
    final response = Completer<dynamic>();
    final write = cache.write(() => response.future);
    final assertion =
        expectLater(write, throwsA(isA<SessionChangedException>()));
    await tokenManager.setToken('new-account');
    response.complete(complete(<Map<String, dynamic>>[
      <String, dynamic>{'id': 'old'}
    ]));
    await assertion;
    expect(cache.pending, isNull);
  });

  test('late reads cannot replace a successful write snapshot', () async {
    final cache = MutationList<House>(House.fromJson);
    final old = Completer<List<House>>();
    final read = cache.load(() => old.future);
    await cache.write(() async => complete(<Map<String, dynamic>>[
          <String, dynamic>{'id': 'new'}
        ]));
    old.complete(const <House>[House(id: 'old')]);
    expect((await read).single.id, 'new');
  });

  test('overlapping writes discard uncertain response ordering', () async {
    final cache = MutationList<House>(House.fromJson);
    final a = Completer<dynamic>();
    final b = Completer<dynamic>();
    final writeA = cache.write(() => a.future);
    final writeB = cache.write(() => b.future);
    b.complete(complete(<Map<String, dynamic>>[
      <String, dynamic>{'id': 'b'}
    ]));
    await writeB;
    a.complete(complete(<Map<String, dynamic>>[
      <String, dynamic>{'id': 'a'}
    ]));
    await writeA;
    expect(cache.pending, isNull);
  });

  test('all three API modules use write response without an extra GET',
      () async {
    final adapter = _Adapter((options) => options.method == 'GET'
        ? <String, dynamic>{'rows': <dynamic>[], 'total': 0, 'pageTotal': 0}
        : complete(<Map<String, dynamic>>[
            <String, dynamic>{'id': options.path}
          ]));
    final client = RequestDio(client: Dio()..httpClientAdapter = adapter);
    await submitHouseAPI(const House(), client: client);
    expect((await getHouseListApi(client: client)).single.id, 'room');
    await deleteHouseApi('room', client: client);
    await getHouseListApi(client: client);
    await submitVisitorApi(const VisitorRecord(), client: client);
    expect((await getVisitorListApi(client: client)).single.id, 'visitor');
    await submitRepairApi(const RepairRecord(), client: client);
    expect((await getRepairListApi(client: client)).single.id, 'repair');
    await cancelRepairApi('repair', client: client);
    await getRepairListApi(client: client);
    expect(adapter.requests.where((r) => r.method == 'GET'), isEmpty);
    await getRepairListApi(client: client);
    expect(adapter.requests.where((r) => r.method == 'GET'), hasLength(1));
  });

  Widget actionPage(BuildContext context, Future<void> Function() action) =>
      Scaffold(
          body: TextButton(
              onPressed: () async {
                await action();
                if (context.mounted) Navigator.pop(context, true);
              },
              child: const Text('保存并返回')));

  testWidgets(
      'repair list displays creation then cancellation from mutation response',
      (tester) async {
    int status = 1;
    final adapter = _Adapter((options) {
      if (options.method == 'GET') {
        return <String, dynamic>{'rows': <dynamic>[], 'total': 0};
      }
      if (options.method == 'PUT') status = 0;
      return complete(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'repair',
          'repairItemName': '水电维修',
          'status': status
        }
      ]);
    });
    final client = RequestDio(client: Dio()..httpClientAdapter = adapter);
    await pumpPage(
        tester, RepairListPage(loader: () => getRepairListApi(client: client)),
        routes: {
          RepairFormPage.routeName: (context) => actionPage(context,
              () => submitRepairApi(const RepairRecord(), client: client)),
          RepairDetailPage.routeName: (context) => actionPage(
              context, () => cancelRepairApi('repair', client: client)),
        });
    await tester.tap(find.text('新增报修'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存并返回'));
    await tester.pumpAndSettle();
    expect(find.text('水电维修'), findsOneWidget);
    await tester.tap(find.text('水电维修'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存并返回'));
    await tester.pumpAndSettle();
    expect(find.text('已取消'), findsOneWidget);
    expect(adapter.requests.where((r) => r.method == 'GET'), hasLength(1));
    await finishPage(tester);
  });

  testWidgets('house list becomes empty after deletion without another GET',
      (tester) async {
    final adapter = _Adapter((options) => options.method == 'GET'
        ? <Map<String, dynamic>>[
            <String, dynamic>{'id': 'house', 'point': '学习小区', 'room': '101'}
          ]
        : complete(<Map<String, dynamic>>[]));
    final client = RequestDio(client: Dio()..httpClientAdapter = adapter);
    await pumpPage(tester,
        HouseList(houseListLoader: () => getHouseListApi(client: client)),
        routes: {
          HouseDetail.routeName: (context) => actionPage(
              context, () => deleteHouseApi('house', client: client)),
        });
    await tester.tap(find.text('学习小区').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存并返回'));
    await tester.pumpAndSettle();
    expect(find.text('学习小区'), findsNothing);
    expect(adapter.requests.where((r) => r.method == 'GET'), hasLength(1));
    await finishPage(tester);
  });

  testWidgets('visitor list displays newly created record without another GET',
      (tester) async {
    final adapter = _Adapter((options) => options.method == 'GET'
        ? <String, dynamic>{'rows': <dynamic>[]}
        : complete(<Map<String, dynamic>>[
            <String, dynamic>{'id': 'visitor', 'name': '李四'}
          ]));
    final client = RequestDio(client: Dio()..httpClientAdapter = adapter);
    await pumpPage(tester,
        VisitorListPage(loader: () => getVisitorListApi(client: client)),
        routes: {
          VisitorFormPage.routeName: (context) => actionPage(context,
              () => submitVisitorApi(const VisitorRecord(), client: client)),
        });
    await tester.tap(find.text('新增访客邀请'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存并返回'));
    await tester.pumpAndSettle();
    expect(find.text('李四'), findsOneWidget);
    expect(adapter.requests.where((r) => r.method == 'GET'), hasLength(1));
    await finishPage(tester);
  });
}
