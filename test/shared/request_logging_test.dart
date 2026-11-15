import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/logger.dart';
import 'package:haven_hub/utils/request_dio.dart';

class _LoggingAdapter implements HttpClientAdapter {
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
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

  test('logs a fixed summary without request headers, parameters or bodies',
      () async {
    final _LoggingAdapter adapter = _LoggingAdapter();
    final Dio dio = Dio()..httpClientAdapter = adapter;
    final RequestDio client = RequestDio(client: dio);

    final dynamic result = await client.post(
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
    expect(output, contains('method: POST'));
    expect(output, contains('path: login'));
    expect(output, contains('status: 200'));
    expect(output, contains('code: 10000'));
    expect(output, isNot(contains('body:')));
    expect(output, isNot(contains('headers:')));
    expect(output, isNot(contains('params:')));
    expect(output, isNot(contains('safe-value')));
    expect(output, isNot(contains('13800138000')));
    expect(output, isNot(contains('123456')));
    expect(output, isNot(contains('password-value')));
    expect(output, isNot(contains('response-token')));
    expect(output, isNot(contains('response-refresh')));
    expect(output, isNot(contains('header-secret')));
    expect(output, isNot(contains('request-token')));
    expect(adapter.request!.path, 'login?mobile=13800138000&code=123456');
    expect((adapter.request!.data as Map<String, dynamic>)['mobile'],
        '13800138000');
    expect(result['token'], 'response-token');

    dio.close();
  });

  // 只取外层数字业务码，data 内的验证码连同其他业务内容一起省略。
  test('keeps the business status code without logging nested business data',
      () async {
    final Dio dio = Dio()..httpClientAdapter = _NestedCodeAdapter();
    final RequestDio client = RequestDio(client: dio);

    final dynamic result = await client.get('sendCode');

    final String output = messages.join('\n');
    // 顶层业务状态码保留，否则排查「接口返回了非成功码」时没有依据。
    expect(output, contains('code: 10000'));
    expect(output, isNot(contains('verificationCode:')));
    expect(output, isNot(contains('920739')));
    expect(output, isNot(contains('888888')));
    expect(output, isNot(contains('safe-value')));
    expect(result['code'], '920739');

    dio.close();
  });

  // 失败请求保留错误类型、HTTP 状态和业务码，原始说明不写入日志。
  test('logs failure status and business code without the error body', () async {
    final Dio dio = Dio()
      ..httpClientAdapter = _FailingAdapter(
        500,
        jsonEncode(<String, dynamic>{
          'code': 50001,
          'message': '服务端拒绝：houseId 不存在',
        }),
      );
    final RequestDio client = RequestDio(client: dio);

    await expectLater(client.post('repair'), throwsA(isA<NetworkException>()));

    final String output = messages.join('\n');
    expect(output, contains('type: badResponse'));
    expect(output, contains('status: 500'));
    expect(output, contains('code: 50001'));
    expect(output, isNot(contains('houseId 不存在')));

    dio.close();
  });

  test('HTTP 409 from repair becomes NetworkException with statusCode 409 without replay', () async {
    final adapter = _FailingAdapter(409, jsonEncode(<String, dynamic>{
      'code': 40900, 'message': '记录已更新，请刷新后再操作',
    }));
    final Dio dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final RequestDio client = RequestDio(client: dio);
    await expectLater(client.put('worker/repairs/test-id/complete',
        data: <String, dynamic>{'revision': 3, 'result': '已修好'}),
      throwsA(isA<NetworkException>().having(
        (error) => error.statusCode, 'statusCode', 409)));
    expect(adapter.calls, 1);
    expect(messages.join('\n'), contains('status: 409'));
  });

  test('omits sensitive values in failed response bodies', () async {
    final Dio dio = Dio()
      ..httpClientAdapter = _FailingAdapter(
        500,
        jsonEncode(<String, dynamic>{
          'code': 500,
          'data': <String, dynamic>{'token': 'leaked-token', 'code': '920739'},
        }),
      );
    final RequestDio client = RequestDio(client: dio);

    await expectLater(client.get('userInfo'), throwsA(isA<NetworkException>()));

    final String output = messages.join('\n');
    expect(output, contains('status: 500'));
    expect(output, contains('code: 500'));
    expect(output, isNot(contains('body:')));
    expect(output, isNot(contains('leaked-token')));
    expect(output, isNot(contains('920739')));

    dio.close();
  });

  test('omits JSON error messages that echo credentials', () async {
    final Dio dio = Dio()
      ..httpClientAdapter = _FailingAdapter(
        500,
        jsonEncode(<String, dynamic>{
          'code': 50001,
          'message': 'houseId invalid; Authorization: Bearer echoed-token; '
              'refreshToken="echoed-refresh"; password=echoed-password; '
              'mobile=13800138008; code=920739',
        }),
      );
    addTearDown(dio.close);
    final RequestDio client = RequestDio(client: dio);

    await expectLater(client.post('repair'), throwsA(isA<NetworkException>()));

    final String output = messages.join('\n');
    expect(output, contains('status: 500'));
    expect(output, contains('code: 50001'));
    expect(output, isNot(contains('houseId invalid')));
    for (final String secret in <String>[
      'echoed-token',
      'echoed-refresh',
      'echoed-password',
      '13800138008',
      '920739',
    ]) {
      expect(output, isNot(contains(secret)));
    }
  });

  test('omits free text from logs without mutating the actual request',
      () async {
    const String original =
        'houseId=7177501402628096; password="request secret"; '
        'Basic dXNlcjpwYXNz; phone 13800138008; '
        'jwt eyJhbGciOiJIUzI1NiJ9.payload.signature';
    final _LoggingAdapter adapter = _LoggingAdapter();
    final Dio dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final RequestDio client = RequestDio(client: dio);

    await client
        .post('repair', data: <String, dynamic>{'description': original});

    expect((adapter.request!.data as Map<String, dynamic>)['description'],
        original);
    final String output = messages.join('\n');
    expect(output, isNot(contains('houseId=7177501402628096')));
    for (final String secret in <String>[
      'request secret',
      'dXNlcjpwYXNz',
      '13800138008',
      'eyJhbGciOiJIUzI1NiJ9.payload.signature',
    ]) {
      expect(output, isNot(contains(secret)));
    }
  });

  for (final String contentType in <String>['text/plain', 'text/html']) {
    test('omits unstructured $contentType error bodies', () async {
      const String body =
          '<p>token=unstructured-token; password=raw-secret</p>';
      final Dio dio = Dio()
        ..httpClientAdapter =
            _FailingAdapter(500, body, contentType: contentType);
      addTearDown(dio.close);
      final RequestDio client = RequestDio(client: dio);

      await expectLater(client.get('repair'), throwsA(isA<NetworkException>()));

      final String output = messages.join('\n');
      expect(output, contains('status: 500'));
      expect(output, isNot(contains('body:')));
      expect(output, isNot(contains('unstructured-token')));
      expect(output, isNot(contains('raw-secret')));
    });
  }

  test('private failed responses remain absent from logs', () async {
    final Dio dio = Dio()
      ..httpClientAdapter = _FailingAdapter(500, '{"code":500}');
    addTearDown(dio.close);
    final RequestDio client = RequestDio(client: dio);

    await expectLater(
        client.get('repair',
            options:
                Options(extra: <String, dynamic>{'privateResponse': true})),
        throwsA(isA<NetworkException>()));

    expect(messages, isEmpty);
  });

  test('timeout logs keep only the error type when there is no response', () async {
    final Dio dio = Dio()..httpClientAdapter = _TimeoutAdapter();
    addTearDown(dio.close);
    final RequestDio client = RequestDio(client: dio);

    await expectLater(client.get('repair'), throwsA(isA<NetworkException>()));

    final String output = messages.join('\n');
    expect(output, contains('type: connectionTimeout'));
    expect(output, isNot(contains('status:')));
    expect(output, isNot(contains('body:')));
    expect(output, isNot(contains('timeout-token')));
  });

  test('logging does not traverse large nested response data', () async {
    final Map<String, dynamic> businessData = <String, dynamic>{
      'items': Iterable<int>.generate(1000000000, (int index) {
        throw StateError('日志不应遍历业务数据');
      }),
    };
    final Dio dio = Dio()..httpClientAdapter = _LoggingAdapter();
    dio.interceptors.add(InterceptorsWrapper(
      onResponse: (
        Response<dynamic> response,
        ResponseInterceptorHandler handler,
      ) {
        response.data = <String, dynamic>{
          'code': 10000,
          'data': businessData,
        };
        handler.next(response);
      },
    ));
    addTearDown(dio.close);
    final RequestDio client = RequestDio(client: dio);

    final dynamic result = await client.get('repair');

    expect(identical(result, businessData), isTrue);
    final String output = messages.join('\n');
    expect(output, contains('code: 10000'));
    expect(output.length, lessThan(2000));
  });

  test('diagnostic fields apply only to the selected request', () async {
    final Dio dio = Dio()
      ..httpClientAdapter = _FailingAdapter(
        500,
        jsonEncode(<String, dynamic>{
          'code': 50001,
          'message': 'houseId invalid; token=echoed-secret',
        }),
      );
    addTearDown(dio.close);
    final RequestDio client = RequestDio(client: dio);
    final Map<String, dynamic> requestData = <String, dynamic>{
      'houseId': 'H102',
      'revision': 3,
      'mobile': '13800138000',
      'token': 'request-secret',
    };

    await expectLater(
      client.post('repair', data: requestData,
          options: RequestDio.logDetails(
            requestLogFields: <String>['houseId', 'revision', 'mobile', 'token'],
            responseLogFields: <String>['message'],
          )),
      throwsA(isA<NetworkException>()),
    );
    final String output = messages.join('\n');
    expect(output, contains('request.houseId: H102'));
    expect(output, contains('request.revision: 3'));
    expect(output, contains('response.message: houseId invalid'));
    expect(output, isNot(contains('echoed-secret')));
    expect(output, isNot(contains('request-secret')));
    expect(output, isNot(contains('13800138000')));
    expect(requestData['token'], 'request-secret');

    messages.clear();
    await expectLater(client.post('repair', data: requestData),
        throwsA(isA<NetworkException>()));
    expect(messages.join('\n'), isNot(contains('request.houseId')));
    expect(messages.join('\n'), isNot(contains('response.message')));

    messages.clear();
    await expectLater(
      client.get('repair', params: <String, dynamic>{'page': 2},
          options: RequestDio.logDetails(requestLogFields: <String>['page'])),
      throwsA(isA<NetworkException>()),
    );
    expect(messages.join('\n'), contains('request.page: 2'));
  });

  test('diagnostics bound field count and text without traversing nested values',
      () async {
    final Iterable<int> unreadableItems = Iterable<int>.generate(1000000000,
        (int index) => throw StateError('诊断日志不应遍历嵌套值'));
    final Map<String, dynamic> resultData = <String, dynamic>{'saved': true};
    final Dio dio = Dio()..httpClientAdapter = _LoggingAdapter();
    dio.interceptors.add(InterceptorsWrapper(
      onResponse: (
        Response<dynamic> response,
        ResponseInterceptorHandler handler,
      ) {
        response.data = <String, dynamic>{
          'code': 10000,
          'data': resultData,
          'first': 'safe-value',
          'items': unreadableItems,
          'longText': List<String>.filled(10000, 'x').join(),
          'token': 'response-secret',
          'mobile': '13800138000',
          'sixth': 'must-not-be-logged',
        };
        handler.next(response);
      },
    ));
    addTearDown(dio.close);
    final RequestDio client = RequestDio(client: dio);

    final dynamic result = await client.get('repair',
        options: RequestDio.logDetails(responseLogFields: <String>[
          'first', 'items', 'longText', 'token', 'mobile', 'sixth',
        ]));

    final String output = messages.join('\n');
    expect(output, contains('response.first: safe-value'));
    expect(output, contains('response.longText: <omitted: long value>'));
    expect(output, isNot(contains('response.items')));
    expect(output, isNot(contains('response-secret')));
    expect(output, isNot(contains('13800138000')));
    expect(output, isNot(contains('must-not-be-logged')));
    expect(output.length, lessThan(3000));
    expect(identical(result, resultData), isTrue);
  });

  test('private requests suppress explicitly selected diagnostic fields', () async {
    final Dio dio = Dio()
      ..httpClientAdapter = _FailingAdapter(500,
          jsonEncode(<String, dynamic>{'code': 50001, 'message': 'private detail'}));
    addTearDown(dio.close);
    final RequestDio client = RequestDio(client: dio);
    final Options options = RequestDio.logDetails(
        requestLogFields: <String>['houseId'], responseLogFields: <String>['message']);
    options.extra!['privateResponse'] = true;

    await expectLater(
      client.post('repair', data: <String, dynamic>{'houseId': 'H102'},
          options: options),
      throwsA(isA<NetworkException>()),
    );
    expect(messages, isEmpty);
  });

  test('long request paths are omitted without expanding their contents', () async {
    final Dio dio = Dio()..httpClientAdapter = _LoggingAdapter();
    addTearDown(dio.close);
    final RequestDio client = RequestDio(client: dio);
    final String longPath =
        'repair?value=${List<String>.filled(10000, 'x').join()}';

    await client.get(longPath);

    final String output = messages.join('\n');
    expect(output, contains('<omitted: long path>'));
    expect(output.length, lessThan(2000));
  });
}

class _FailingAdapter implements HttpClientAdapter {
  _FailingAdapter(this.statusCode, this.body,
      {this.contentType = Headers.jsonContentType});

  final int statusCode;
  final String body;
  final String contentType;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _TimeoutAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionTimeout,
      message: 'Timeout while sending Authorization: Bearer timeout-token',
    );
  }

  @override
  void close({bool force = false}) {}
}

class _NestedCodeAdapter implements HttpClientAdapter {
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
          'code': '920739',
          'verificationCode': '888888',
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
