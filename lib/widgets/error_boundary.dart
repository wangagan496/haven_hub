import 'dart:ui' show PlatformDispatcher;

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

  @override
  void initState() {
    super.initState();
    // 在开发模式下，错误会直接抛出，方便调试
    // 在生产模式下，错误会被捕获并显示友好界面
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && _stackTrace != null) {
      return widget.errorBuilder?.call(_error!, _stackTrace!) ??
          _buildDefaultErrorWidget(context);
    }

    ErrorWidget.builder = (FlutterErrorDetails details) {
      if (!mounted) {
        return ErrorWidget(details.exception);
      }

      // 记录错误日志
      Logger.error(
        'Widget Error',
        details.exception,
        details.stack,
      );

      // 触发错误回调
      widget.onError
          ?.call(details.exception, details.stack ?? StackTrace.empty);

      // 在当前帧结束后更新状态
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
    };

    return widget.child;
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
              onPressed: () {
                setState(() {
                  _error = null;
                  _stackTrace = null;
                });
              },
              icon: const Icon(Icons.refresh),
              label: const Text('重新加载'),
            ),
            if (_error != null) ...[
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
                Text(
                  '错误信息：',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  _error.toString(),
                  style: const TextStyle(fontSize: 12),
                ),
                if (_stackTrace != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    '堆栈跟踪：',
                    style: const TextStyle(fontWeight: FontWeight.bold),
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
