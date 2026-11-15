import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 由每个用例提供响应；请求计数从 1 开始。
class CallbackHttpAdapter implements HttpClientAdapter {
  CallbackHttpAdapter(this.respond);

  final FutureOr<ResponseBody> Function(RequestOptions, int) respond;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      respond(options, ++calls);

  @override
  void close({bool force = false}) {}
}
