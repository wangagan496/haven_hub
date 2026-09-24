import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/utils/logger.dart';
import 'package:haven_hub/utils/request_dio.dart';

class _LoggingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{
        'code': 10000,
        'data': <String, dynamic>{
          'token': 'response-token',
          'refreshToken': 'response-refresh',
          'nickname': 'safe-value',
        },
      }),
      200,
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

  late bool previousLoggerEnabled;
  late DebugPrintCallback previousDebugPrint;
  late List<String> messages;

  setUp(() {
    previousLoggerEnabled = Logger.enabled;
    previousDebugPrint = debugPrint;
    messages = <String>[];
    Logger.enabled = true;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) messages.add(message);
    };
  });

  tearDown(() {
    Logger.enabled = previousLoggerEnabled;
    debugPrint = previousDebugPrint;
  });

  test('redacts sensitive request and response values from network logs',
      () async {
    final Dio dio = Dio()..httpClientAdapter = _LoggingAdapter();
    final RequestDio client = RequestDio(client: dio);

    await client.post(
      'login?mobile=13800138000&code=123456',
      data: <String, dynamic>{
        'mobile': '13800138000',
        'code': '123456',
        'profile': <String, dynamic>{'password': 'password-value'},
      },
      options: Options(headers: <String, dynamic>{
        'Authorization': 'Bearer request-token',
        'X-Api-Secret': 'header-secret',
      }),
    );

    final String output = messages.join('\n');
    expect(output, contains('mobile: ***'));
    expect(output, contains('code: ***'));
    expect(output, contains('password: ***'));
    expect(output, contains('token: ***'));
    expect(output, contains('refreshToken: ***'));
    expect(output, contains('Authorization: ***'));
    expect(output, contains('X-Api-Secret: ***'));
    expect(output, contains('nickname: safe-value'));
    expect(output, isNot(contains('13800138000')));
    expect(output, isNot(contains('123456')));
    expect(output, isNot(contains('password-value')));
    expect(output, isNot(contains('response-token')));
    expect(output, isNot(contains('response-refresh')));
    expect(output, isNot(contains('header-secret')));

    dio.close();
  });
}
