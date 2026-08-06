import 'package:flutter/foundation.dart';

/// 日志工具类，统一管理应用日志输出。
///
/// 在 Debug 模式自动启用，Release 模式默认禁用（可通过 [enabled] 控制）。
class Logger {
  const Logger._();

  /// 是否启用日志输出。
  ///
  /// 默认在 Debug 模式启用，Release 模式禁用。
  static bool enabled = kDebugMode;

  /// 日志级别枚举。
  static const String _debug = '🔍 DEBUG';
  static const String _info = '💡 INFO';
  static const String _warning = '⚠️  WARNING';
  static const String _error = '❌ ERROR';
  static const String _network = '🌐 NETWORK';

  /// 输出调试日志。
  static void debug(String message, [Object? data]) {
    _log(_debug, message, data);
  }

  /// 输出信息日志。
  static void info(String message, [Object? data]) {
    _log(_info, message, data);
  }

  /// 输出警告日志。
  static void warning(String message, [Object? data]) {
    _log(_warning, message, data);
  }

  /// 输出错误日志。
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    _log(_error, message, error);
    if (stackTrace != null && enabled) {
      debugPrint('$stackTrace');
    }
  }

  /// 输出网络请求日志。
  static void network(String message, [Object? data]) {
    _log(_network, message, data);
  }

  static void _log(String level, String message, [Object? data]) {
    if (!enabled) return;

    final String timestamp = DateTime.now().toIso8601String();
    final String output = '[$timestamp] $level: $message';

    debugPrint(output);
    if (data != null) {
      debugPrint('  └─ Data: $data');
    }
  }
}
