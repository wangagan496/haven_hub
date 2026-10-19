import 'dart:convert';
import 'dart:io';

const String _tencentMapBaseUrl = 'https://apis.map.qq.com/';
const String _tencentMapProxyPrefix = '/tencent-map/';
const String _amapBaseUrl = 'https://restapi.amap.com/';
const String _amapProxyPrefix = '/amap-map/';
const int _defaultPort = 3001;

class _ProxyOptions {
  const _ProxyOptions({
    required this.port,
    required this.bindAddress,
    required this.bypassSystemProxy,
  });

  final int port;
  final InternetAddress bindAddress;
  final bool bypassSystemProxy;
}

const Set<String> _hopByHopHeaders = <String>{
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
};

Future<void> main(List<String> arguments) async {
  final _ProxyOptions options = _parseOptions(arguments);
  final int port = options.port;
  final HttpServer server = await HttpServer.bind(
    options.bindAddress,
    options.port,
  );

  stdout.writeln('Web 地图 API 开发代理已启动：http://127.0.0.1:$port/');
  stdout.writeln('腾讯位置服务：$_tencentMapBaseUrl');
  stdout.writeln('高德位置服务：$_amapBaseUrl');
  stdout.writeln('按 Ctrl+C 停止服务。');

  final HttpClient client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 Chrome/150 Safari/537.36';
  if (options.bypassSystemProxy) {
    client.findProxy = (_) => 'DIRECT';
  }

  await for (final HttpRequest request in server) {
    await _handleRequest(request, client, options.bindAddress);
  }
}

_ProxyOptions _parseOptions(List<String> arguments) {
  int port = _defaultPort;
  String bindAddress = InternetAddress.loopbackIPv4.address;
  bool bypassSystemProxy = false;

  for (int index = 0; index < arguments.length; index++) {
    final String argument = arguments[index];
    if (argument == '--direct') {
      bypassSystemProxy = true;
      continue;
    }
    if (argument == '--bind' && index + 1 < arguments.length) {
      bindAddress = arguments[++index];
      continue;
    }
    if (argument.startsWith('--bind=')) {
      bindAddress = argument.substring('--bind='.length);
      continue;
    }
    if (!argument.startsWith('-') && index == 0) {
      port = _parsePort(<String>[argument]);
      continue;
    }
    throw ArgumentError(
      'Usage: dart run tool/web_api_proxy.dart [port] '
      '[--bind=<host IPv4>] [--direct]',
    );
  }

  final InternetAddress? address = InternetAddress.tryParse(bindAddress);
  if (address == null || address.type != InternetAddressType.IPv4) {
    throw ArgumentError.value(bindAddress, 'bind', 'Only IPv4 is supported');
  }
  return _ProxyOptions(
    port: port,
    bindAddress: address,
    bypassSystemProxy: bypassSystemProxy,
  );
}

int _parsePort(List<String> arguments) {
  if (arguments.isEmpty) {
    return _defaultPort;
  }

  final int? port = int.tryParse(arguments.first);
  if (port == null || port < 1 || port > 65535) {
    stderr.writeln('端口无效：${arguments.first}');
    stderr.writeln('用法：dart run tool/web_api_proxy.dart [端口]');
    exit(64);
  }
  return port;
}

Future<void> _handleRequest(
  HttpRequest request,
  HttpClient client,
  InternetAddress bindAddress,
) async {
  final String? origin = request.headers.value('origin');
  if (!_isAllowedOrigin(origin, bindAddress)) {
    request.response.statusCode = HttpStatus.forbidden;
    await _sendJson(
      request.response,
      <String, Object?>{
        'code': 40300,
        'message': '仅允许本机 Web 调试页面访问',
        'data': null,
      },
    );
    return;
  }

  _addCorsHeaders(request, origin);
  if (request.method == 'OPTIONS') {
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
    return;
  }

  final bool isTencentMapRequest =
      request.uri.path.startsWith(_tencentMapProxyPrefix);
  final bool isAmapRequest = request.uri.path.startsWith(_amapProxyPrefix);
  if (!isTencentMapRequest && !isAmapRequest) {
    request.response.statusCode = HttpStatus.notFound;
    await _sendJson(
      request.response,
      <String, Object?>{
        'code': 40400,
        'message': '地图代理只转发 /tencent-map/ 和 /amap-map/；'
            '业务接口请把 API_BASE_URL 设为 http://127.0.0.1:3000/',
        'data': null,
      },
    );
    return;
  }
  final Uri upstreamBaseUri = Uri.parse(
    isTencentMapRequest ? _tencentMapBaseUrl : _amapBaseUrl,
  );
  final String upstreamPath = isTencentMapRequest
      ? '/${request.uri.path.substring(_tencentMapProxyPrefix.length)}'
      : '/${request.uri.path.substring(_amapProxyPrefix.length)}';
  final Uri upstreamUri = upstreamBaseUri.replace(
    path: upstreamPath,
    query: request.uri.hasQuery ? request.uri.query : null,
    fragment: '',
  );
  bool responseStarted = false;
  try {
    final HttpClientRequest upstreamRequest = await client
        .openUrl(request.method, upstreamUri)
        .timeout(const Duration(seconds: 15));
    upstreamRequest.followRedirects = false;
    _copyRequestHeaders(request.headers, upstreamRequest.headers);

    if (request.contentLength >= 0) {
      upstreamRequest.contentLength = request.contentLength;
    }
    await upstreamRequest.addStream(request);

    final HttpClientResponse upstreamResponse =
        await upstreamRequest.close().timeout(const Duration(seconds: 30));
    request.response.statusCode = upstreamResponse.statusCode;
    request.response.reasonPhrase = upstreamResponse.reasonPhrase;
    _copyResponseHeaders(upstreamResponse.headers, request.response.headers);
    responseStarted = true;
    await request.response.addStream(upstreamResponse);
    await request.response.close();
  } on Object catch (error) {
    // 查询串可能带地图 Key；代理日志只记录路径和错误类型。
    stderr.writeln(
        '${request.method} ${request.uri.path} 转发失败：${error.runtimeType}');
    if (!responseStarted) {
      request.response.statusCode = HttpStatus.badGateway;
      await _sendJson(
        request.response,
        <String, Object?>{
          'code': 50200,
          'message': isTencentMapRequest
              ? '开发代理连接腾讯位置服务失败'
              : '开发代理连接高德位置服务失败',
          'data': null,
        },
      );
    } else {
      await request.response.close();
    }
  }
}

bool _isAllowedOrigin(String? origin, InternetAddress bindAddress) {
  if (origin == null || origin.isEmpty) {
    return true;
  }

  final Uri? uri = Uri.tryParse(origin);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  return uri.host == '127.0.0.1' ||
      uri.host == 'localhost' ||
      uri.host == bindAddress.address;
}

void _addCorsHeaders(HttpRequest request, String? origin) {
  final HttpResponse response = request.response;
  response.headers
    ..set(
      HttpHeaders.accessControlAllowOriginHeader,
      origin?.isNotEmpty ?? false ? origin! : '*',
    )
    ..set(
      HttpHeaders.accessControlAllowMethodsHeader,
      'GET, POST, PUT, PATCH, DELETE, OPTIONS',
    )
    ..set(
      HttpHeaders.accessControlAllowHeadersHeader,
      request.headers.value('access-control-request-headers') ??
          'Authorization, Content-Type, Accept',
    )
    ..set(HttpHeaders.accessControlMaxAgeHeader, '600')
    ..add(HttpHeaders.varyHeader, 'Origin')
    ..add(HttpHeaders.varyHeader, 'Access-Control-Request-Headers');
}

void _copyRequestHeaders(HttpHeaders source, HttpHeaders target) {
  source.forEach((String name, List<String> values) {
    final String normalizedName = name.toLowerCase();
    if (_hopByHopHeaders.contains(normalizedName) ||
        normalizedName == HttpHeaders.hostHeader ||
        normalizedName == HttpHeaders.contentLengthHeader ||
        normalizedName == HttpHeaders.cookieHeader ||
        normalizedName == 'origin' ||
        normalizedName == HttpHeaders.refererHeader ||
        normalizedName.startsWith('access-control-') ||
        normalizedName.startsWith('sec-fetch-')) {
      return;
    }
    target.set(name, values);
  });
}

void _copyResponseHeaders(HttpHeaders source, HttpHeaders target) {
  source.forEach((String name, List<String> values) {
    final String normalizedName = name.toLowerCase();
    if (_hopByHopHeaders.contains(normalizedName) ||
        normalizedName == HttpHeaders.contentLengthHeader ||
        normalizedName == HttpHeaders.setCookieHeader ||
        normalizedName.startsWith('access-control-')) {
      return;
    }
    target.set(name, values);
  });
}

Future<void> _sendJson(
  HttpResponse response,
  Map<String, Object?> body,
) async {
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  await response.close();
}
// ignore_for_file: cascade_invocations
