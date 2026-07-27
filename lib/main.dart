import 'package:flutter/material.dart';

import 'api/home.dart';
import 'pages/notice_detail/index.dart';
import 'pages/tabs_page/index.dart';

void main() {
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
      routes: <String, WidgetBuilder>{
        '/': (BuildContext context) {
          return TabsPage(announcementLoader: announcementLoader);
        },
        NoticeDetail.routeName: (BuildContext context) {
          return NoticeDetail(detailLoader: announcementDetailLoader);
        },
      },
    );
  }
}
