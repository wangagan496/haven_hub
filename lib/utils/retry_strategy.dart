import 'app_exception.dart';
import 'token_manager.dart';

/// 重试策略配置
class RetryStrategy {
  /// 重试延迟列表（毫秒）
  final List<int> delays;

  /// 策略名称（用于日志）
  final String name;

  const RetryStrategy._({
    required this.delays,
    required this.name,
  });

  /// 自动加载策略：渐进式延迟 [0ms, 500ms, 1s, 2s]
  ///
  /// 适用于：页面初始化、自动刷新
  /// 累计等待：最多 3.5 秒，不含请求耗时
  static const auto = RetryStrategy._(
    delays: [0, 500, 1000, 2000],
    name: 'auto',
  );

  /// 手动重试策略：快速延迟 [0ms, 1s, 2s]
  ///
  /// 适用于：用户点击重试按钮
  /// 累计等待：最多 3 秒，不含请求耗时
  /// 原因：用户在等待，需要更快的反馈
  static const manual = RetryStrategy._(
    delays: [0, 1000, 2000],
    name: 'manual',
  );

  /// 重试次数
  int get maxAttempts => delays.length;

  /// 获取第 n 次重试的延迟时间（毫秒）
  int getDelay(int attemptIndex) {
    if (attemptIndex < 0 || attemptIndex >= delays.length) {
      return 0;
    }
    return delays[attemptIndex];
  }

  @override
  String toString() => 'RetryStrategy.$name(attempts: $maxAttempts)';
}

/// 错误类型判断扩展
///
/// 用于决定是否应该重试
extension ErrorTypeChecker on Object {
  /// 是否是超时或临时错误
  ///
  /// 这种错误可以重试
  bool get isRetryable {
    final error = this;
    if (error is! NetworkException || error.retryHandled) return false;
    return error.isTimeout ||
        const <int>{502, 503, 504}.contains(error.statusCode);
  }

  /// 是否应该立即失败（不重试）
  bool get shouldFailFast => !isRetryable;
}

/// 带重试的异步执行函数
///
/// 使用示例：
/// ```dart
/// final result = await retryAsync(
///   action: () => getRepairListApi(),
///   strategy: RetryStrategy.auto,
/// );
/// ```
/// [shouldRetry] 在失败后及等待结束后检查；返回 false 时停止后续请求。
/// 会话或凭证更新后也停止整个操作；用户手动重试会捕获新的会话快照。
Future<T> retryAsync<T>({
  required Future<T> Function() action,
  RetryStrategy strategy = RetryStrategy.auto,
  void Function(int attempt, Object error)? onRetry,
  bool Function()? shouldRetry,
  TokenManager? tokens,
}) async {
  final TokenManager session = tokens ?? tokenManager;
  final int sessionId = session.sessionId;
  final int sessionVersion = session.sessionVersion;
  bool sessionChanged() =>
      session.sessionId != sessionId ||
      session.sessionVersion != sessionVersion;
  for (int i = 0; i < strategy.maxAttempts; i++) {
    try {
      if (sessionChanged()) throw const SessionChangedException();
      return await action();
    } on Object catch (error) {
      if (session.sessionId == sessionId && error is NetworkException && error.retryHandled) rethrow;
      if (sessionChanged()) throw const SessionChangedException();
      if (error.shouldFailFast ||
          i == strategy.maxAttempts - 1 ||
          !(shouldRetry?.call() ?? true)) {
        rethrow;
      }
      await Future<void>.delayed(
          Duration(milliseconds: strategy.getDelay(i + 1)));
      if (sessionChanged()) throw const SessionChangedException();
      if (!(shouldRetry?.call() ?? true)) {
        rethrow;
      }
      onRetry?.call(i + 1, error);
    }
  }

  // 理论上不会到这里，但为了类型安全
  throw StateError('Retry strategy must allow at least one attempt');
}
