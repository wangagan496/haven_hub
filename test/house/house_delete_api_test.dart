import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/house.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/logger.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 200;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(<String, Object>{
        'code': status == 200 ? 10000 : 40900,
        'message': '房屋资料或审核状态已更新，请刷新核对后再删除',
        'data': <String, Object>{
          'complete': true,
          'rows': <Object>[],
          'total': 0
        },
      }),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Adapter adapter;
  late RequestDio client;
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.loadTokens();
    await tokenManager.setToken('house-delete-test');
    Logger.enabled = false;
    adapter = _Adapter();
    final dio = Dio()..httpClientAdapter = adapter;
    client = RequestDio(client: dio);
    addTearDown(() => dio.close(force: true));
  });
  tearDown(() async => tokenManager.deleteToken());

  test(
      'deletion sends the viewed revision and preserves authoritative empty list',
      () async {
    await deleteHouseApi(' house-1 ', revision: 7, client: client);
    expect(adapter.requests.single.method, 'DELETE');
    expect(adapter.requests.single.path, 'room/house-1');
    expect(adapter.requests.single.data, <String, Object>{'revision': 7});
    expect(await getHouseListApi(client: client), isEmpty);
    expect(adapter.requests, hasLength(1));
  });

  test('legacy zero is explicit and invalid deletion parameters send nothing',
      () async {
    for (final revision in <int>[-1, 9007199254740992]) {
      await expectLater(
          deleteHouseApi('house-1', revision: revision, client: client),
          throwsFormatException);
    }
    await expectLater(deleteHouseApi(' ', revision: 1, client: client),
        throwsFormatException);
    expect(adapter.requests, isEmpty);
    await deleteHouseApi('legacy', revision: 0, client: client);
    expect(adapter.requests.single.data, <String, Object>{'revision': 0});
  });

  test('conflicted and transiently failed deletion never automatically replays',
      () async {
    for (final status in <int>[409, 503]) {
      adapter.status = status;
      await expectLater(
          deleteHouseApi('house-1', revision: 7, client: client),
          throwsA(isA<NetworkException>()
              .having((error) => error.statusCode, 'status', status)));
    }
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.every((request) => request.method == 'DELETE'),
        isTrue);
  });
}
