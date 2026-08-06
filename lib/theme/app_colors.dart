import 'package:flutter/material.dart';

/// 全局配色。
///
/// 抽取前全项目有 80+ 处硬编码 `Color(0xFF...)`，页面背景分成 0xFFF8F3F8 和
/// 0xFFF5F1F1 两派，次要灰字散落着 0xFF666666/686868/777777/888888/999999 五个
/// 近似值——都是复制粘贴过程中漂移出来的，并非有意的设计区分。这里按语义收敛。
class AppColors {
  const AppColors._();

  /// 品牌主色。
  static const Color primary = Color(0xFF5591AF);

  /// 选楼流程里表示“已选中”的强调色。
  static const Color accent = Color(0xFF6552B5);

  /// 页面背景（原 0xFFF8F3F8 与 0xFFF5F1F1 统一为一种）。
  static const Color background = Color(0xFFF8F3F8);

  /// 卡片、列表项的表面色。
  static const Color surface = Colors.white;

  /// 主要文字。
  static const Color textPrimary = Color(0xFF262626);

  /// 正文文字：列表项右侧的值、当前地址等。
  static const Color textBody = Color(0xFF333333);

  /// 次要文字：小标题、说明文案。
  static const Color textSecondary = Color(0xFF686868);

  /// 弱化文字：占位、辅助说明。
  static const Color textTertiary = Color(0xFF999999);

  /// 分隔线、右侧箭头等装饰性图标。
  static const Color divider = Color(0xFFAAAAAA);

  /// 图片占位背景。
  static const Color placeholder = Color(0xFFF1F1F1);

  /// 危险操作（删除）。
  static const Color danger = Color(0xFFD64545);
}
