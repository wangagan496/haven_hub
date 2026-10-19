import 'dart:convert';
import 'dart:js_interop';

@JS('havenPush')
external JSPromise<JSString> _havenPush(JSString request);

Future<Map<String, dynamic>> pushPlatformCall(Map<String, dynamic> request) async {
  final result = await _havenPush(jsonEncode(request).toJS).toDart;
  final data = Map<String, dynamic>.from(jsonDecode(result.toDart) as Map);
  if (data['error'] case final String error) throw FormatException(error);
  return data;
}
