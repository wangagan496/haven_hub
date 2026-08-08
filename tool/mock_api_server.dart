import 'dart:convert';
import 'dart:io';

const List<Map<String, String>> _announcements = <Map<String, String>>[
  <String, String>{
    'id': 'mock-notice-1',
    'title': '中秋、国庆温馨提示',
    'content': '<p>尊敬的业主（住户）：</p>'
        '<p>您好！值此双节来临之际，预祝大家节日快乐、工作顺利。</p>',
    'createdAt': '2026-07-27T12:00:00.000Z',
    'creatorName': '享家社区',
  },
  <String, String>{
    'id': 'mock-notice-2',
    'title': '社区公共区域维护通知',
    'content': '<p>本周六上午将对社区公共区域进行维护，'
        '请大家合理安排出行时间，感谢理解与配合。</p>',
    'createdAt': '2026-07-26T10:30:00.000Z',
    'creatorName': '物业服务中心',
  },
];

Future<void> main(List<String> arguments) async {
  final int port = arguments.isEmpty ? 3000 : int.parse(arguments.first);
  final HttpServer server = await HttpServer.bind(
    InternetAddress.anyIPv4,
    port,
  );

  stdout.writeln('Mock API 已启动：http://0.0.0.0:$port/');
  stdout.writeln('按 Ctrl+C 停止服务。');

  await for (final HttpRequest request in server) {
    _addCorsHeaders(request.response);

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      continue;
    }

    final List<String> segments = request.uri.pathSegments;
    if (request.method == 'GET' &&
        segments.length == 1 &&
        segments.first == 'announcement') {
      await _sendJson(
        request.response,
        <String, Object>{
          'code': 10000,
          'message': '查询成功',
          'data': _announcements,
        },
      );
      continue;
    }

    if (request.method == 'GET' &&
        segments.length == 2 &&
        segments.first == 'announcement') {
      final String id = segments[1];
      final Map<String, String>? detail =
          _announcements.where((Map<String, String> item) {
        return item['id'] == id;
      }).firstOrNull;

      if (detail == null) {
        request.response.statusCode = HttpStatus.notFound;
        await _sendJson(
          request.response,
          <String, Object?>{
            'code': 40400,
            'message': '公告不存在',
            'data': null,
          },
        );
      } else {
        await _sendJson(
          request.response,
          <String, Object>{
            'code': 10000,
            'message': '查询成功',
            'data': detail,
          },
        );
      }
      continue;
    }

    request.response.statusCode = HttpStatus.notFound;
    await _sendJson(
      request.response,
      <String, Object?>{
        'code': 40400,
        'message': '接口不存在',
        'data': null,
      },
    );
  }
}

void _addCorsHeaders(HttpResponse response) {
  response.headers
    ..set(HttpHeaders.accessControlAllowOriginHeader, '*')
    ..set(
      HttpHeaders.accessControlAllowMethodsHeader,
      'GET, OPTIONS',
    )
    ..set(HttpHeaders.accessControlAllowHeadersHeader, 'Content-Type');
}

Future<void> _sendJson(
  HttpResponse response,
  Map<String, Object?> body,
) async {
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  await response.close();
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final Iterator<T> iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
// ignore_for_file: cascade_invocations
