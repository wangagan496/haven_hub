import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'api/home.dart';
import 'constant/index.dart';
import 'core/app_initializer.dart';
import 'l10n/app_localizations.dart';
import 'pages/not_found/not_found.dart';
import 'router/app_routes.dart';
import 'router/index.dart';
import 'theme/app_theme.dart';
import 'utils/logger.dart';
import 'widgets/error_boundary.dart';
import 'widgets/push_lifecycle.dart';

Future<void> main() async {
  prepareFlutter();

  // 准备项目公共工具：登录凭证管理、网络请求。
  await prepareAppServices();

  // 准备错误处理；出错时调用 logAppError 记录日志。
  prepareErrorHandling(onError: logAppError);

  runApp(const HavenHubApp());
}

/// 准备 Flutter 的基础支持；已经准备好时直接继续。
const prepareFlutter = WidgetsFlutterBinding.ensureInitialized;

/// 准备项目公共工具，沿用原来的启动准备流程。
const prepareAppServices = AppInitializer.initialize;

/// 准备错误处理，接收发生错误时要执行的动作。
const prepareErrorHandling = GlobalErrorHandler.initialize;

/// 记录应用错误：error 是错误本身，callTrace 是出错时的调用路径。
void logAppError(Object error, StackTrace callTrace) {
  Logger.error('Global Error Caught', error, callTrace);
}

class HavenHubApp extends StatelessWidget {
  const HavenHubApp({
    this.announcementLoader = getAnnouncementListApi,
    this.announcementDetailLoader = getAnnouncementDetailApi,
    super.key,
  });

  final AnnouncementLoader announcementLoader;
  final AnnouncementDetailLoader announcementDetailLoader;

  @override
  Widget build(BuildContext context) {
    return ErrorBoundary(
      child: MaterialApp(
        navigatorKey: GlobalVariable.navigatorKey,
        onGenerateTitle: (BuildContext context) =>
            AppLocalizations.of(context)?.appTitle ?? 'Haven Hub',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        builder: (context, child) => CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape,
                includeRepeats: false): () {
              final navigator = GlobalVariable.navigatorKey.currentState;
              if (navigator != null && navigator.canPop()) {
                unawaited(navigator.maybePop());
              }
            },
          },
          child: PushLifecycle(child: child ?? const SizedBox.shrink()),
        ),

        // 国际化配置
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('zh', ''), // 中文
          Locale('en', ''), // 英文
        ],

        initialRoute: home,
        // Web 冷启动时地址栏 hash（如通知点击打开的 #/notifications/<id>）会成为初始路由。
        // 默认实现会按 "/" 逐级拆出 /、/notifications、/notifications/<id> 三层，
        // 导致同一条通知被打开两次；这里只保留首页加目标页两层。
        onGenerateInitialRoutes: (String initialRoute) => initialRouteNames(initialRoute)
            .map((String name) => _route(RouteSettings(name: name)))
            .whereType<Route<dynamic>>()
            .toList(),
        onGenerateRoute: _route,
        onUnknownRoute: (RouteSettings settings) {
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (BuildContext context) => NotFoundPage(
              routeName: settings.name,
            ),
          );
        },
      ),
    );
  }

  Route<dynamic>? _route(RouteSettings settings) {
    final Widget? page = getRouteWidget(
      settings.name,
      announcementLoader: announcementLoader,
      announcementDetailLoader: announcementDetailLoader,
      pageData: settings.arguments,
    );
    if (page == null) return null;

    // Mutation pages return true to refresh their calling list.
    return MaterialPageRoute<bool>(
      settings: settings,
      builder: (BuildContext context) => ErrorBoundary(child: page),
    );
  }
}
