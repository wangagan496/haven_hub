import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/utils/request_dio.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.body, {this.statusCode = 200});

  final Map<String, dynamic> body;
  final int statusCode;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('公告详情路径使用 id 拼接', () {
    expect(
      HttpPath.announcementDetail('notice/1'),
      'announcement/notice%2F1',
    );
  });

  test('业务状态码为 10000 时返回 data', () async {
    final Dio dio = Dio()
      ..httpClientAdapter = _FakeAdapter(
        <String, dynamic>{
          'code': GlobalVariable.successCode,
          'message': '查询成功',
          'data': <Map<String, dynamic>>[
            <String, dynamic>{'title': '社区公告'},
          ],
        },
      );
    final RequestDio client = RequestDio(dio: dio);

    final dynamic result = await client.get(HttpPath.announcement);

    expect(result, isA<List<dynamic>>());
    expect((result as List<dynamic>).first['title'], '社区公告');
  });

  test('业务状态码非 10000 时抛出 DioException', () async {
    final Dio dio = Dio()
      ..httpClientAdapter = _FakeAdapter(
        <String, dynamic>{
          'code': 400,
          'message': '业务发生异常',
          'data': null,
        },
      );
    final RequestDio client = RequestDio(dio: dio);

    expect(
      () => client.get(HttpPath.announcement),
      throwsA(
        isA<DioException>().having(
          (DioException error) => error.message,
          'message',
          '业务发生异常',
        ),
      ),
    );
  });

  test('HTTP 状态码非 2xx 时抛出 DioException', () async {
    final Dio dio = Dio();
    dio.options.validateStatus = (int? statusCode) => true;
    dio.httpClientAdapter = _FakeAdapter(
      <String, dynamic>{'message': '服务器异常'},
      statusCode: 500,
    );
    final RequestDio client = RequestDio(dio: dio);

    expect(
      () => client.get(HttpPath.announcement),
      throwsA(
        isA<DioException>().having(
          (DioException error) => error.response?.statusCode,
          'statusCode',
          500,
        ),
      ),
    );
  });
}
