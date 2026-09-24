import 'dart:typed_data';

import 'package:dio/dio.dart' as dio;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/app_exception.dart';
import '../utils/request_dio.dart';

const int maxVisitorPassBytes = 5 * 1024 * 1024;
const MethodChannel _channel = MethodChannel('haven_hub/visitor_pass_share');

typedef VisitorPassImageLoader = Future<Uint8List> Function(String url);
typedef VisitorPassSharer = Future<void> Function(Uint8List bytes,
    {Rect? anchor});

bool get supportsVisitorPassShare =>
    !kIsWeb && defaultTargetPlatform.name == 'ohos';

/// Only public image requests: never attach the application's authentication.
Future<Uint8List> loadVisitorPassImage(String url, {RequestDio? client}) async {
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null ||
      !<String>{'https', 'http'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('通行码图片地址无效');
  }
  final dio.CancelToken cancelToken = dio.CancelToken();
  try {
    final dynamic body = await (client ?? requestDio).getExternal(
      uri.toString(),
      options: dio.Options(
        responseType: dio.ResponseType.stream,
        followRedirects: false,
        extra: <String, dynamic>{'privateResponse': true},
      ),
      cancelToken: cancelToken,
    );
    if (body is! dio.ResponseBody) {
      throw const FormatException('通行码图片响应无效');
    }
    final BytesBuilder buffer = BytesBuilder(copy: false);
    await for (final Uint8List chunk
        in body.stream.timeout(const Duration(seconds: 15))) {
      if (buffer.length + chunk.length > maxVisitorPassBytes) {
        throw const FormatException('通行码图片不能超过 5 MB');
      }
      buffer.add(chunk);
    }
    final Uint8List bytes = buffer.takeBytes();
    validateVisitorPassImage(bytes);
    return bytes;
  } finally {
    cancelToken.cancel();
  }
}

/// Check the file contents instead of trusting a URL suffix or MIME header.
void validateVisitorPassImage(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > maxVisitorPassBytes) {
    throw const FormatException('通行码图片为空或超过 5 MB');
  }
  final bool png = bytes.length >= 8 &&
      listEquals(bytes.sublist(0, 8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);
  final bool jpeg = bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255;
  if (!png && !jpeg) {
    throw const FormatException('通行码图片需为 PNG 或 JPEG 格式');
  }
}

/// Resolves when the system panel closes, not when a recipient receives it.
Future<void> shareVisitorPassImage(Uint8List bytes, {Rect? anchor}) async {
  validateVisitorPassImage(bytes);
  if (anchor != null && (!anchor.isFinite || anchor.isEmpty)) {
    throw const FormatException('分享按钮位置无效');
  }
  try {
    await _channel.invokeMethod<void>('shareImage', <String, Object>{
      'bytes': bytes,
      if (anchor != null) ...<String, Object>{
        'anchorX': anchor.left,
        'anchorY': anchor.top,
        'anchorWidth': anchor.width,
        'anchorHeight': anchor.height,
      },
    });
  } on MissingPluginException {
    throw const BusinessException('当前设备不支持通行码分享');
  } on PlatformException catch (error) {
    final String message = switch (error.code) {
      'busy' => '分享面板已经打开，请先完成或关闭',
      'unavailable' => '当前无法打开分享，请返回页面重试',
      'invalid_image' => '通行码图片无效，请重新加载',
      _ => '打开系统分享失败，请重试',
    };
    throw BusinessException(message);
  }
}
