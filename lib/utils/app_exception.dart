/// 网络层错误：HTTP 状态码异常、连接超时、无网络等。
///
/// 由 [RequestDio] 的公开请求方法统一抛出，上层只需读取 [message]。
///
/// 示例：
/// ```dart
/// throw const NetworkException('连接超时', statusCode: null);
/// throw const NetworkException('未授权', statusCode: 401);
/// ```
class NetworkException implements Exception {
  const NetworkException(this.message, {this.statusCode});

  /// 用户友好的错误描述。
  final String message;

  /// HTTP 状态码；网络连接类错误（超时、断网等）为 null。
  final int? statusCode;

  @override
  String toString() => 'NetworkException($statusCode): $message';
}

/// 业务层错误：HTTP 200 但服务端 code != 10000。
///
/// 由 [RequestDio] 的公开请求方法统一抛出，上层只需读取 [message]。
///
/// 示例：
/// ```dart
/// throw const BusinessException('用户不存在', code: 40001);
/// ```
class BusinessException implements Exception {
  const BusinessException(this.message, {this.code});

  /// 服务端返回的错误描述。
  final String message;

  /// 服务端返回的业务 code。
  final int? code;

  @override
  String toString() => 'BusinessException($code): $message';
}

/// 把任意异常转换成可直接展示给用户的中文文案。
///
/// [BusinessException]、[NetworkException] 与 [FormatException] 自带面向用户的
/// 文案，直接透传；其余异常统一收敛到 [fallback]，避免把堆栈细节暴露到界面上。
///
/// 页面若还需识别自己领域内的异常（例如定位关闭、定位超时），可传入
/// [onOtherError]：返回非空字符串表示已处理，返回 null 则继续走 [fallback]。
String describeError(
  Object error, {
  required String fallback,
  String? Function(Object error)? onOtherError,
}) {
  return switch (error) {
    BusinessException() => error.message,
    NetworkException() => error.message,
    FormatException() => error.message,
    _ => onOtherError?.call(error) ?? fallback,
  };
}
