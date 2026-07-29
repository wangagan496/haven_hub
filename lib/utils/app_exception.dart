/// 网络层错误：HTTP 状态码异常、连接超时、无网络等。
///
/// 由 [RequestDio] 的公开请求方法统一抛出，上层只需读取 [message]。
class NetworkException implements Exception {
  const NetworkException(this.message, {this.statusCode});

  final String message;

  /// HTTP 状态码；网络连接类错误（超时、断网等）为 null。
  final int? statusCode;

  @override
  String toString() => 'NetworkException($statusCode): $message';
}

/// 业务层错误：HTTP 200 但服务端 code != 10000。
///
/// 由 [RequestDio] 的公开请求方法统一抛出，上层只需读取 [message]。
class BusinessException implements Exception {
  const BusinessException(this.message, {this.code});

  final String message;

  /// 服务端返回的业务 code。
  final int? code;

  @override
  String toString() => 'BusinessException($code): $message';
}
