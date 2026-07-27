import 'package:flutter/material.dart';

import 'api/home.dart';
import 'router/index.dart';
import 'utils/token_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await tokenManager.init();
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
    return MaterialApp(
      title: 'Haven Hub',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5591AF)),
        scaffoldBackgroundColor: const Color(0xFFFFF8FF),
        useMaterial3: true,
      ),
      initialRoute: '/',
      onGenerateRoute: (RouteSettings settings) {
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (BuildContext context) {
            return getRouteWidget(
              settings.name,
              announcementLoader: announcementLoader,
              announcementDetailLoader: announcementDetailLoader,
            );
          },
        );
      },
    );
  }
}
