import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 应用主题。
///
/// 各页面原本逐个手写 `centerTitle: true` + `surfaceTintColor: Colors.transparent`
/// + `backgroundColor`，共 6 份；统一收进 [AppBarTheme] 后页面只需给标题。
ThemeData buildAppTheme() {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primary),
    scaffoldBackgroundColor: AppColors.background,
    useMaterial3: true,
    appBarTheme: const AppBarTheme(
      centerTitle: true,
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
    ),
  );
}
