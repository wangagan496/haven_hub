import 'package:flutter/material.dart';

import '../utils/app_exception.dart';
import '../utils/toast.dart';

/// 异步加载状态管理 Mixin。
///
/// 为需要处理异步加载的 StatefulWidget 提供统一的状态管理模式。
/// 自动处理加载状态、错误处理和用户提示。
///
/// 使用示例：
/// ```dart
/// class _MyPageState extends State<MyPage> with LoadingStateMixin {
///   @override
///   void initState() {
///     super.initState();
///     loadData(() async {
///       final data = await fetchData();
///       setState(() {
///         _data = data;
///       });
///     });
///   }
/// }
/// ```
mixin LoadingStateMixin<T extends StatefulWidget> on State<T> {
  bool _isLoading = false;
  String? _errorMessage;

  /// 当前是否正在加载。
  bool get isLoading => _isLoading;

  /// 当前错误消息，无错误时为 null。
  String? get errorMessage => _errorMessage;

  /// 执行异步加载任务。
  ///
  /// [task] 要执行的异步任务。
  /// [onError] 自定义错误处理回调，返回 null 使用默认错误描述。
  /// [showErrorToast] 是否在错误时显示 Toast 提示，默认为 true。
  /// [fallbackMessage] 默认错误提示文案。
  ///
  /// 返回任务是否成功完成。
  Future<bool> loadData(
    Future<void> Function() task, {
    String? Function(Object error)? onError,
    bool showErrorToast = true,
    String fallbackMessage = '加载失败，请重试',
  }) async {
    if (_isLoading) {
      return false;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await task();
      if (mounted) {
        setState(() {
          _errorMessage = null;
        });
      }
      return true;
    } on Object catch (error) {
      final String message = onError?.call(error) ??
          describeError(
            error,
            fallback: fallbackMessage,
          );

      if (!mounted) return false;

      setState(() {
        _errorMessage = message;
      });

      if (showErrorToast) {
        await PromptAction.showError(message);
      }
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// 重置加载状态。
  void resetLoadingState() {
    if (mounted) {
      setState(() {
        _isLoading = false;
        _errorMessage = null;
      });
    }
  }

  /// 手动设置错误消息。
  void setError(String message) {
    if (mounted) {
      setState(() {
        _errorMessage = message;
      });
    }
  }

  /// 清除错误消息。
  void clearError() {
    if (mounted) {
      setState(() {
        _errorMessage = null;
      });
    }
  }
}
