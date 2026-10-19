import 'package:flutter/services.dart';

const _channel = MethodChannel('haven_hub/push');

Future<Map<String, dynamic>> pushPlatformCall(Map<String, dynamic> request) async {
  try {
    final result = await _channel.invokeMapMethod<String, dynamic>(
        request['action'] as String, request);
    return result ?? <String, dynamic>{};
  } on MissingPluginException {
    if (request['action'] == 'enable') {
      throw const FormatException('当前平台尚不支持系统推送，报修待办仍可查看');
    }
    return <String, dynamic>{};
  } on PlatformException catch (error) {
    throw FormatException(error.message ?? '系统通知操作失败，请重试');
  }
}
