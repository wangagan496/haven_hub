import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 异步页面的“加载中 / 加载失败 / 内容”三态外壳。
///
/// 已有数据时（[hasContent] 为 true）不再被加载和错误态覆盖：刷新失败应该保留
/// 旧内容并靠 toast 提示，而不是把用户已经看到的列表换成一整屏错误页。
class AsyncStateView extends StatelessWidget {
  const AsyncStateView({
    required this.isLoading,
    required this.errorMessage,
    required this.onRetry,
    required this.builder,
    this.hasContent = false,
    super.key,
  });

  final bool isLoading;
  final String? errorMessage;
  final VoidCallback? onRetry;

  /// 是否已有可展示的内容。为 true 时直接渲染 [builder]。
  final bool hasContent;

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    if (isLoading && !hasContent) {
      return const Center(child: CircularProgressIndicator());
    }

    final String? message = errorMessage;
    if (message != null && !hasContent) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.error_outline_rounded,
                size: 44,
                color: AppColors.textTertiary,
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              if (onRetry != null) ...<Widget>[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: isLoading ? null : onRetry,
                  child: const Text('重新加载'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return builder(context);
  }
}
