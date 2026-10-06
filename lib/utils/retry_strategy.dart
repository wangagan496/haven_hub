import 'package:flutter/foundation.dart';

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
  /// 总耗时：最多 3.5秒
  static const auto = RetryStrategy._(
    delays: [0, 500, 1000, 2000],
    name: 'auto',
  );

  /// 手动重试策略：快速延迟 [0ms, 1s, 2s]
  ///
  /// 适用于：用户点击重试按钮
  /// 总耗时：最多 3秒
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
  /// 是否是网络未连接错误
  ///
  /// 这种错误不应该重试，因为重试也不会成功
  bool get isNoConnection {
    final msg = toString().toLowerCase();
    return msg.contains('network') && msg.contains('unavailable') ||
        msg.contains('no connection') ||
        msg.contains('connection failed') ||
        msg.contains('unreachable');
  }

  /// 是否是超时或临时错误
  ///
  /// 这种错误可以重试
  bool get isRetryable {
    if (isNoConnection) return false;

    final msg = toString().toLowerCase();
    return msg.contains('timeout') ||
        msg.contains('timed out') ||
        msg.contains('connection reset') ||
        msg.contains('temporarily unavailable') ||
        msg.contains('503') ||
        msg.contains('502') ||
        msg.contains('504');
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
///   onRetry: (attempt, error) => print('第 $attempt 次重试: $error'),
/// );
/// ```
Future<T> retryAsync<T>({
  required Future<T> Function() action,
  RetryStrategy strategy = RetryStrategy.auto,
  void Function(int attempt, Object error)? onRetry,
}) async {
  Object? lastError;

  for (int i = 0; i < strategy.maxAttempts; i++) {
    // 如果不是第一次，先延迟
    if (i > 0) {
      final delay = strategy.getDelay(i);
      if (delay > 0) {
        await Future.delayed(Duration(milliseconds: delay));
      }
      onRetry?.call(i, lastError!);
    }

    try {
      return await action();
    } catch (error) {
      lastError = error;

      // 如果应该快速失败，不继续重试
      if (error.shouldFailFast) {
        if (kDebugMode) {
          print('[RetryStrategy] 快速失败: $error');
        }
        rethrow;
      }

      // 如果是最后一次尝试，抛出错误
      if (i == strategy.maxAttempts - 1) {
        if (kDebugMode) {
          print('[RetryStrategy] 重试 ${i + 1} 次后失败: $error');
        }
        rethrow;
      }

      // 否则继续下一次重试
      if (kDebugMode) {
        print('[RetryStrategy] 第 ${i + 1} 次尝试失败，将在 ${strategy.getDelay(i + 1)}ms 后重试');
      }
    }
  }

  // 理论上不会到这里，但为了类型安全
  throw lastError!;
}
