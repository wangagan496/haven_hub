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

  // 响应里的 `code` 出现在两层，含义不同：信封顶层是业务状态码，要留；嵌进
  // `data` 之后是验证码，要脱。只按「请求侧/响应侧」分是分不出来的，会把验证
  // 码原样写进日志。
  test('keeps the business status code but redacts nested verification codes',
      () async {
    final Dio dio = Dio()..httpClientAdapter = _NestedCodeAdapter();
    final RequestDio client = RequestDio(client: dio);

    await client.get('sendCode');

    final String output = messages.join('\n');
    // 顶层业务状态码保留，否则排查「接口返回了非成功码」时没有依据。
    expect(output, contains('code: 10000'));
    // 嵌在 data 里的验证码必须脱敏。
    expect(output, contains('code: ***'));
    expect(output, contains('verificationCode: ***'));
    expect(output, isNot(contains('920739')));
    expect(output, isNot(contains('888888')));
    expect(output, contains('safe-value'));

    dio.close();
  });

  // 失败响应体只出现在错误分支：onResponse 拦截器不会经过这里，所以必须由
  // onError 自行记录，否则 5xx 的服务端说明在客户端完全不可见。
  test('logs status code and error body for failed responses', () async {
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
    expect(output, contains('houseId 不存在'));

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

  // 复用 _buildResponseLog 的同时也继承了它的脱敏；否则错误日志会成为新的泄漏面。
  test('redacts sensitive values in failed response bodies', () async {
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
    expect(output, contains('token: ***'));
    expect(output, contains('code: ***'));
    expect(output, isNot(contains('leaked-token')));
    expect(output, isNot(contains('920739')));

    dio.close();
  });

  test('redacts credentials echoed in JSON error messages', () async {
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
    expect(output, contains('houseId invalid'));
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

  test('sanitizes free text logs without mutating the actual request',
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
    expect(output, contains('houseId=7177501402628096'));
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
      expect(output, contains('body: <omitted: unstructured text>'));
      expect(output, contains('bodyLength: ${body.length}'));
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

  test('timeout logs redact echoed credentials without a response', () async {
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
