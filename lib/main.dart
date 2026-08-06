import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'api/home.dart';
import 'constant/index.dart';
import 'core/app_initializer.dart';
import 'pages/not_found/not_found.dart';
import 'router/index.dart';
import 'theme/app_theme.dart';
import 'utils/logger.dart';
import 'widgets/error_boundary.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化应用依赖
  await AppInitializer.initialize();

  // 初始化全局错误处理
  GlobalErrorHandler.initialize(
    onError: (Object error, StackTrace stackTrace) {
      // 这里可以添加错误上报逻辑（如上报到 Sentry、Firebase Crashlytics 等）
      Logger.error('Global Error Caught', error, stackTrace);
    },
  );

  runApp(const HavenHubApp());
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
        title: 'Haven Hub',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),

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

        initialRoute: '/',
        onGenerateRoute: (RouteSettings settings) {
          final Widget? page = getRouteWidget(
            settings.name,
            announcementLoader: announcementLoader,
            announcementDetailLoader: announcementDetailLoader,
            arguments: settings.arguments,
          );
          if (page == null) return null;

          return MaterialPageRoute<void>(
            settings: settings,
            builder: (BuildContext context) => ErrorBoundary(child: page),
          );
        },
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
}
