import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 列表页面的分组小标题，例如“房屋信息”“业主信息”“附近社区”。
///
/// 抽取前各页面各写了一份私有实现，灰度和字号在复制粘贴中发生了漂移
/// （0xFF615E5E/16、0xFF686868/14、0xFF888888/14）。这里统一为一种样式。
class SectionTitle extends StatelessWidget {
  const SectionTitle(
    this.title, {
    this.padding = const EdgeInsets.fromLTRB(16, 18, 16, 8),
    super.key,
  });

  final String title;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        title,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
      ),
    );
  }
}
