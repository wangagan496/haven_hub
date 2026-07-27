import 'package:flutter/material.dart';

import '../api/home.dart';
import '../pages/login/index.dart';
import '../pages/notice_detail/index.dart';
import '../pages/profile/index.dart';
import '../pages/tabs_page/index.dart';
import '../utils/token_manager.dart';

Widget getRouteWidget(
  String? routeName, {
  required AnnouncementLoader announcementLoader,
  required AnnouncementDetailLoader announcementDetailLoader,
}) {
  final Map<String, Widget Function()> routes = <String, Widget Function()>{
    '/': () => TabsPage(announcementLoader: announcementLoader),
    NoticeDetail.routeName: () => NoticeDetail(
          detailLoader: announcementDetailLoader,
        ),
    LoginPage.routeName: () => const LoginPage(),
    ProfilePage.routeName: () {
      if (tokenManager.getToken().isEmpty) {
        return const LoginPage(toName: ProfilePage.routeName);
      }
      return const ProfilePage();
    },
  };

  final Widget Function()? pageBuilder = routes[routeName];
  if (pageBuilder != null) {
    return pageBuilder();
  }

  return const Scaffold(
    body: Center(child: Text('页面不存在')),
  );
}
