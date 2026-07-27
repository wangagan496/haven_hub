import 'package:flutter/material.dart';

import 'api/home.dart';
import 'pages/tabs_page/index.dart';

void main() {
  runApp(const HavenHubApp());
}

class HavenHubApp extends StatelessWidget {
  const HavenHubApp({
    this.announcementLoader = getAnnouncementListApi,
    super.key,
  });

  final AnnouncementLoader announcementLoader;

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
      home: TabsPage(announcementLoader: announcementLoader),
    );
  }
}
