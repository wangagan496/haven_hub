import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../utils/logger.dart';

/// 错误边界组件，捕获子组件树中的构建错误。
///
/// 类似于 React 的 Error Boundary，防止单个组件错误导致整个应用崩溃。
class ErrorBoundary extends StatefulWidget {
  /// 创建错误边界。
  const ErrorBoundary({
    required this.child,
    this.onError,
    this.errorBuilder,
    super.key,
  });

  /// 子组件。
  final Widget child;

  /// 错误回调，用于上报错误。
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// 自定义错误视图构建器。
  final Widget Function(Object error, StackTrace stackTrace)? errorBuilder;

  @override
  State<ErrorBoundary> createState() => _ErrorBoundaryState();
}

class _ErrorBoundaryState extends State<ErrorBoundary> {
  Object? _error;
  StackTrace? _stackTrace;

  /// 每次重试递增，作为子树的 key，逼 Flutter 丢弃旧元素树重建。
  int _revision = 0;

  /// 上一个 [ErrorWidget.builder]，用于销毁时还原。
  ErrorWidgetBuilder? _previousErrorWidgetBuilder;

  /// 本边界安装进 [ErrorWidget.builder] 的那个闭包。
  ///
  /// 必须存成字段：方法 tear-off 每次取值未必是同一个对象，拿 `identical`
  /// 去比对 `ErrorWidget.builder` 和 `_handleWidgetError` 会得到 false，于是
  /// dispose 时判断成「别人后来装过」，还原被静默跳过，这个定制就永久留在
  /// 全局了。
  late final ErrorWidgetBuilder _installedErrorWidgetBuilder;

  @override
  void initState() {
    super.initState();
    _previousErrorWidgetBuilder = ErrorWidget.builder;
    _installedErrorWidgetBuilder = _handleWidgetError;
    // 只在这里装一次。放在 build 里会每帧覆盖别的定制，而且 dispose 时无从
    // 还原——同一个构建错误会反复安装，把别人装的换掉再也换不回来。
    ErrorWidget.builder = _installedErrorWidgetBuilder;
  }

  @override
  void dispose() {
    if (identical(ErrorWidget.builder, _installedErrorWidgetBuilder)) {
      ErrorWidget.builder = _previousErrorWidgetBuilder ?? ErrorWidget.new;
    }
    super.dispose();
  }

  Widget _handleWidgetError(FlutterErrorDetails details) {
    if (!mounted) {
      return ErrorWidget(details.exception);
    }

    Logger.error(
      'Widget Error',
      details.exception,
      details.stack,
    );

    widget.onError?.call(details.exception, details.stack ?? StackTrace.empty);

    // 构建期间不能 setState，推到当前帧结束后再切到错误界面。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {
          _error = details.exception;
          _stackTrace = details.stack;
        });
      }
    });

    // 返回默认错误组件（会在下一帧被替换）
    return _buildDefaultErrorWidget(context);
  }

  void _retry() {
    setState(() {
      _error = null;
      _stackTrace = null;
      // 只清错误不够：widget.child 是同一个 Widget 实例，元素树会照原样
      // 复用，同一个构建错误立刻再抛一次，界面看起来毫无反应。换 key 才会
      // 真正重建子树。
      _revision++;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && _stackTrace != null) {
      return widget.errorBuilder?.call(_error!, _stackTrace!) ??
          _buildDefaultErrorWidget(context);
    }

    return KeyedSubtree(key: ValueKey<int>(_revision), child: widget.child);
  }

  /// 构建默认错误视图。
  Widget _buildDefaultErrorWidget(BuildContext context) {
    return Material(
      child: Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              size: 64,
              color: Colors.red,
            ),
            const SizedBox(height: 16),
            const Text(
              '页面加载失败',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '抱歉，页面遇到了一些问题',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('重新加载'),
            ),
            // 堆栈只给调试用：生产环境把它摊开给终端用户看，等于把内部结构
            // 和文件路径直接暴露出去。
            if (kDebugMode && _error != null) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  _showErrorDetails(context);
                },
                child: const Text('查看详情'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 显示错误详情对话框。
  void _showErrorDetails(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('错误详情'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '错误信息：',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  _error.toString(),
                  style: const TextStyle(fontSize: 12),
                ),
                if (_stackTrace != null) ...[
                  const SizedBox(height: 16),
                  const Text(
                    '堆栈跟踪：',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _stackTrace.toString(),
                    style: const TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}

/// 全局错误处理器，捕获未被 [ErrorBoundary] 捕获的错误。
class GlobalErrorHandler {
  const GlobalErrorHandler._();

  /// 初始化全局错误处理。
  static void initialize({
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    // 捕获 Flutter 框架错误
    FlutterError.onError = (FlutterErrorDetails details) {
      Logger.error(
        'Flutter Error',
        details.exception,
        details.stack,
      );
      onError?.call(details.exception, details.stack ?? StackTrace.empty);

      // 在开发模式显示红屏，生产模式静默处理
      if (const bool.fromEnvironment('dart.vm.product')) {
        // 生产模式：不显示红屏
        FlutterError.dumpErrorToConsole(details, forceReport: true);
      } else {
        // 开发模式：显示红屏
        FlutterError.presentError(details);
      }
    };

    // 捕获异步错误
    PlatformDispatcher.instance.onError =
        (Object error, StackTrace stackTrace) {
      Logger.error('Uncaught Error', error, stackTrace);
      onError?.call(error, stackTrace);
      return true; // 返回 true 表示错误已处理
    };
  }
}
