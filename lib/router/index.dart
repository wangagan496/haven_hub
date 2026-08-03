import 'package:flutter/material.dart';

import '../api/home.dart';
import '../pages/Building/BuildingList.dart';
import '../pages/House/HouseForm.dart';
import '../pages/House/HouseList.dart';
import '../pages/Location/LocationList.dart';
import '../pages/Room/RoomList.dart';
import '../pages/login/index.dart';
import '../pages/notice_detail/index.dart';
import '../pages/profile/index.dart';
import '../pages/tabs_page/index.dart';
import '../utils/token_manager.dart';

Widget? getRouteWidget(
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
    HouseList.routeName: () {
      if (tokenManager.getToken().isEmpty) {
        return const LoginPage(toName: HouseList.routeName);
      }
      return const HouseList();
    },
    LocationList.routeName: () {
      if (tokenManager.getToken().isEmpty) {
        return const LoginPage(toName: LocationList.routeName);
      }
      return const LocationList();
    },
    BuildingList.routeName: () {
      if (tokenManager.getToken().isEmpty) {
        return const LoginPage(toName: LocationList.routeName);
      }
      return const BuildingList();
    },
    RoomList.routeName: () {
      if (tokenManager.getToken().isEmpty) {
        return const LoginPage(toName: LocationList.routeName);
      }
      return const RoomList();
    },
    HouseForm.routeName: () {
      if (tokenManager.getToken().isEmpty) {
        return const LoginPage(toName: LocationList.routeName);
      }
      return const HouseForm();
    },
  };

  final Widget Function()? pageBuilder = routes[routeName];
  if (pageBuilder != null) {
    return pageBuilder();
  }

  return null;
}
