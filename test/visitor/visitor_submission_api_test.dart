import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/visitor.dart';
import 'package:haven_hub/models/visitor.dart';
import 'package:haven_hub/utils/logger.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _id = 'bcd298cd-b2c8-41ce-8e60-3bd06e0f627d';
const _record = VisitorRecord(
  submissionId: _id,
  houseId: 'house-a',
  houseInfo: '仅在本机展示的房屋信息',
  name: '访客甲',
  gender: 0,
  mobile: '13800138000',
  visitDate: '2030-10-28',
);

class _VisitorAdapter implements HttpClientAdapter {
  _VisitorAdapter(this.data);
  Object? data;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(
        jsonEncode(<String, dynamic>{'code': 10000, 'data': data}), 200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType]
        });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _VisitorAdapter adapter;
  late RequestDio client;
  late bool logging;
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.loadTokens();
    await tokenManager.setToken('visitor-api-test');
    logging = Logger.enabled;
    Logger.enabled = false;
    adapter = _VisitorAdapter(null);
    client = RequestDio(client: Dio()..httpClientAdapter = adapter);
  });
  tearDown(() => Logger.enabled = logging);

  test(
      'receipt create preserves the request and hands off the authoritative list',
      () async {
    adapter.data = <String, dynamic>{
      'createdId': 'visitor-original',
      'complete': true,
      'rows': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'visitor-original', ..._record.toJson()}
      ],
      'total': 1,
    };
    await submitVisitorApi(_record, client: client);
    final request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.path, 'visitor');
    expect(request.data, _record.toJson());
    expect((request.data as Map).containsKey('houseInfo'), isFalse);
    expect((await getVisitorListApi(client: client)).single.id,
        'visitor-original');
    expect(adapter.requests, hasLength(1));
  });

  test('receipt create cannot succeed without a confirmed invitation ID',
      () async {
    for (final data in <Object?>[
      null,
      <String, dynamic>{},
      <String, dynamic>{'createdId': ''},
      <String, dynamic>{'createdId': '  '},
      <String, dynamic>{'createdId': 123},
    ]) {
      adapter.data = data;
      await expectLater(
          submitVisitorApi(_record, client: client), throwsFormatException);
    }
    expect(adapter.requests, hasLength(5));
  });

  test('legacy create still accepts a response without receipt metadata',
      () async {
    adapter.data = <String, dynamic>{'rows': <Object>[]};
    final legacy = VisitorRecord.fromJson(
        <String, dynamic>{..._record.toJson(), 'submissionId': ''});
    await submitVisitorApi(legacy, client: client);
    expect((adapter.requests.single.data as Map).containsKey('submissionId'),
        isFalse);
  });

  test('lookup retains the distinction between unknown closed and created',
      () async {
    for (final state in VisitorSubmissionState.values) {
      adapter.data = <String, dynamic>{
        'state': state.name,
        'createdId':
            state == VisitorSubmissionState.created ? 'visitor-original' : '',
      };
      final result = await getVisitorSubmissionApi(_id, client: client);
      expect(result.state, state);
      expect(adapter.requests.last.method, 'GET');
      expect(adapter.requests.last.path, 'visitor-submissions/$_id');
    }
  });

  test('malformed lookup responses cannot clear a pending receipt', () async {
    for (final data in <Object?>[
      null,
      <String, dynamic>{'state': 'failed', 'createdId': ''},
      <String, dynamic>{'state': 'created', 'createdId': ''},
      <String, dynamic>{'state': 'created', 'createdId': 1},
      <String, dynamic>{'state': 'closed', 'createdId': 'visitor-original'},
      <String, dynamic>{'state': 'unknown'},
    ]) {
      adapter.data = data;
      await expectLater(
          getVisitorSubmissionApi(_id, client: client), throwsFormatException);
    }
  });

  test(
      'stop requires a confirmed terminal outcome and never cancels an invitation',
      () async {
    adapter.data = <String, dynamic>{'state': 'unknown', 'createdId': ''};
    await expectLater(
        closeVisitorSubmissionApi(_id, client: client), throwsFormatException);
    for (final state in <VisitorSubmissionState>[
      VisitorSubmissionState.closed,
      VisitorSubmissionState.created
    ]) {
      adapter.data = <String, dynamic>{
        'state': state.name,
        'createdId':
            state == VisitorSubmissionState.created ? 'visitor-original' : '',
      };
      expect(
          (await closeVisitorSubmissionApi(_id, client: client)).state, state);
    }
    expect(
        adapter.requests.every((r) =>
            r.method == 'PUT' &&
            r.path == 'visitor-submissions/$_id/close' &&
            r.data == null),
        isTrue);
  });

  test('invalid receipt IDs are rejected before any network request', () async {
    const invalid = '../other-account';
    await expectLater(getVisitorSubmissionApi(invalid, client: client),
        throwsFormatException);
    await expectLater(closeVisitorSubmissionApi(invalid, client: client),
        throwsFormatException);
    await expectLater(
        submitVisitorApi(
            VisitorRecord.fromJson(<String, dynamic>{
              ..._record.toJson(),
              'submissionId': invalid
            }),
            client: client),
        throwsFormatException);
    expect(adapter.requests, isEmpty);
  });
}
