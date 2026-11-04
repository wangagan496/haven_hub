import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/house.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/utils/logger.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _id = 'a84c6835-6c90-4013-bb66-438749070b43';
const _house = House(
    submissionId: _id,
    point: '甲小区',
    building: '1栋',
    room: '101',
    name: '张三',
    mobile: '13800138000',
    idcardFrontUrl: 'https://example.test/front.png',
    idcardBackUrl: 'https://example.test/back.png');

class _Adapter implements HttpClientAdapter {
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
  late _Adapter adapter;
  late RequestDio client;
  late bool logging;
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.loadTokens();
    await tokenManager.setToken('house-api-owner');
    logging = Logger.enabled;
    Logger.enabled = false;
    adapter = _Adapter();
    client = RequestDio(client: Dio()..httpClientAdapter = adapter);
  });
  tearDown(() => Logger.enabled = logging);

  test('creation sends immutable receipt and preloads authoritative list once',
      () async {
    adapter.data = <String, dynamic>{
      'createdId': 'house-original',
      'complete': true,
      'total': 1,
      'rows': <Map<String, dynamic>>[
        <String, dynamic>{..._house.toJson(), 'id': 'house-original'}
      ]
    };
    await submitHouseAPI(_house, client: client);
    final request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.path, 'room');
    expect(request.data, _house.toJson());
    expect((await getHouseListApi(client: client)).single.id, 'house-original');
    expect(adapter.requests, hasLength(1));
  });

  test('missing creation ID cannot clear a persisted house submission',
      () async {
    for (final data in <Object?>[
      null,
      <String, dynamic>{},
      <String, dynamic>{'createdId': ''},
      <String, dynamic>{'createdId': 1}
    ]) {
      adapter.data = data;
      await expectLater(
          submitHouseAPI(_house, client: client), throwsFormatException);
    }
    expect(adapter.requests, hasLength(4));
  });

  test(
      'editing never sends creation receipt and keeps revision; legacy creation still works',
      () async {
    adapter.data = <String, dynamic>{'rows': <Object>[]};
    await submitHouseAPI(_house.copyWith(id: 'edit-house', revision: 7),
        client: client);
    expect((adapter.requests.last.data as Map)['revision'], 7);
    expect((adapter.requests.last.data as Map).containsKey('submissionId'),
        isFalse);
    await submitHouseAPI(_house.copyWith(submissionId: ''), client: client);
    expect((adapter.requests.last.data as Map).containsKey('submissionId'),
        isFalse);
    expect(
        (adapter.requests.last.data as Map).containsKey('revision'), isFalse);
  });

  test('lookup preserves unknown created closed and deleted states', () async {
    for (final state in HouseSubmissionState.values) {
      adapter.data = <String, dynamic>{
        'state': state.name,
        'createdId': state == HouseSubmissionState.created ||
                state == HouseSubmissionState.deleted
            ? 'house-original'
            : ''
      };
      expect((await getHouseSubmissionApi(_id, client: client)).state, state);
      expect(adapter.requests.last.path, 'room-submissions/$_id');
      expect(adapter.requests.last.method, 'GET');
    }
  });

  test(
      'malformed lookup data and uncertain stop cannot be mistaken for completion',
      () async {
    for (final data in <Object?>[
      null,
      <String, dynamic>{'state': 'deleted', 'createdId': ''},
      <String, dynamic>{'state': 'created', 'createdId': null},
      <String, dynamic>{'state': 'closed', 'createdId': 'house-original'},
      <String, dynamic>{'state': 'failed', 'createdId': ''}
    ]) {
      adapter.data = data;
      await expectLater(
          getHouseSubmissionApi(_id, client: client), throwsFormatException);
    }
    adapter.data = <String, dynamic>{'state': 'unknown', 'createdId': ''};
    await expectLater(
        closeHouseSubmissionApi(_id, client: client), throwsFormatException);
  });

  test('close preserves existing and deleted outcomes without calling delete',
      () async {
    for (final state in <HouseSubmissionState>[
      HouseSubmissionState.created,
      HouseSubmissionState.closed,
      HouseSubmissionState.deleted
    ]) {
      adapter.data = <String, dynamic>{
        'state': state.name,
        'createdId':
            state == HouseSubmissionState.closed ? '' : 'house-original'
      };
      expect((await closeHouseSubmissionApi(_id, client: client)).state, state);
      expect(adapter.requests.last.method, 'PUT');
      expect(adapter.requests.last.path, 'room-submissions/$_id/close');
      expect(adapter.requests.last.data, isNull);
    }
  });

  test('invalid receipt fails before network', () async {
    await expectLater(
        submitHouseAPI(_house.copyWith(submissionId: 'invalid'),
            client: client),
        throwsFormatException);
    await expectLater(getHouseSubmissionApi('../other', client: client),
        throwsFormatException);
    await expectLater(closeHouseSubmissionApi('../other', client: client),
        throwsFormatException);
    expect(adapter.requests, isEmpty);
  });
}
