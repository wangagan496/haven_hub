import 'dart:async';
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

class _HouseAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final Object data = options.method == 'POST'
        ? <String, Object>{
            'complete': true,
            'total': 1,
            'rows': <Object>[
              <String, Object>{'id': 'house-1', 'revision': 7, 'name': '张三'},
            ]
          }
        : <String, Object>{
            'id': 'house-1',
            'revision': 8,
            'name': '李四',
            'status': 2
          };
    return ResponseBody.fromString(
        jsonEncode(<String, Object>{'code': 10000, 'data': data}), 200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType]
        });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'house revision round trips through parsing, local edits and edit payload',
      () {
    for (final value in <Object>[7, 7.0, '7']) {
      final house =
          House.fromJson(<String, dynamic>{'id': 'house-1', 'revision': value});
      expect(house.revision, 7);
      expect(house.copyWith(name: '李四').toJson()['revision'], 7);
      expect(house.copyWith(revision: 8).toJson()['revision'], 8);
      expect(house.copyWith(id: '').toJson().containsKey('revision'), isFalse);
    }
  });
  test('legacy missing revision uses explicit zero while new houses omit it',
      () {
    expect(
        House.fromJson(<String, dynamic>{'id': 'legacy'}).toJson()['revision'],
        0);
    expect(const House().toJson().containsKey('revision'), isFalse);
  });
  test(
      'malformed revisions fail closed instead of silently authorizing an edit',
      () {
    for (final value in <Object?>[
      null,
      true,
      -1,
      1.5,
      '',
      'bad',
      '1.5',
      double.nan,
      double.infinity,
      9007199254740992
    ]) {
      expect(
          () => House.fromJson(
              <String, dynamic>{'id': 'house-1', 'revision': value}),
          throwsFormatException);
    }
  });
  test(
      'edit detail bypasses a stale mutation receipt and submissions retain the read revision',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.loadTokens();
    await tokenManager.setToken('house-revision-test');
    Logger.enabled = false;
    final adapter = _HouseAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    final client = RequestDio(client: dio);
    await submitHouseAPI(const House(id: 'house-1', revision: 6),
        client: client);
    expect((adapter.requests.single.data as Map)['revision'], 6);
    expect((await getHouseDetailApi('house-1', client: client)).revision, 7);
    expect(adapter.requests, hasLength(1), reason: '写回执仍供普通详情页使用');
    final latest = await getHouseEditDetailApi('house-1', client: client);
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.last.method, 'GET');
    expect(latest.revision, 8);
    expect(latest.name, '李四');
    await submitHouseAPI(latest.copyWith(name: '王五'), client: client);
    expect((adapter.requests.last.data as Map)['revision'], 8);
    await tokenManager.deleteToken();
  });
}
