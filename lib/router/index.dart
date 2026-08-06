import 'package:flutter/material.dart';

import '../api/home.dart';
import '../pages/building/building_list.dart';
import '../pages/house/house_detail.dart';
import '../pages/house/house_form.dart';
import '../pages/house/house_list.dart';
import '../pages/location/location_list.dart';
import '../pages/login/index.dart';
import '../pages/notice_detail/index.dart';
import '../pages/profile/index.dart';
import '../pages/room/room_list.dart';
import '../pages/tabs_page/index.dart';
import '../utils/token_manager.dart';
import 'app_routes.dart';

/// 未登录时跳转到登录页，登录成功后回到 [routeName] 并带回原始 [arguments]。
///
/// 参数必须透传：房屋表单等页面依赖 route arguments 里的 id 区分”新增”和”修改”，
/// 丢掉参数会让用户登录后回到一个空白的新增表单。
Widget _requireLogin(
  String routeName,
  Object? arguments,
  Widget Function() builder,
) {
  if (tokenManager.getToken().isEmpty) {
    return LoginPage(toName: routeName, toArguments: arguments);
  }
  return builder();
}

/// 根据路由名称生成对应的页面组件。
///
/// 使用 [AppRoutes] 中定义的路由常量匹配路径。
Widget? getRouteWidget(
  String? routeName, {
  required AnnouncementLoader announcementLoader,
  required AnnouncementDetailLoader announcementDetailLoader,
  Object? arguments,
}) {
  return switch (routeName) {
    AppRoutes.home => TabsPage(announcementLoader: announcementLoader),
    AppRoutes.noticeDetail => NoticeDetail(
        detailLoader: announcementDetailLoader,
      ),
    AppRoutes.login => const LoginPage(),
    AppRoutes.profile => _requireLogin(
        AppRoutes.profile,
        arguments,
        () => const ProfilePage(),
      ),
    AppRoutes.houseList => _requireLogin(
        AppRoutes.houseList,
        arguments,
        () => const HouseList(),
      ),
    AppRoutes.locationList => _requireLogin(
        AppRoutes.locationList,
        arguments,
        () => const LocationList(),
      ),
    AppRoutes.buildingList => _requireLogin(
        AppRoutes.buildingList,
        arguments,
        () => const BuildingList(),
      ),
    AppRoutes.roomList => _requireLogin(
        AppRoutes.roomList,
        arguments,
        () => const RoomList(),
      ),
    AppRoutes.houseForm => _requireLogin(
        AppRoutes.houseForm,
        arguments,
        () => const HouseForm(),
      ),
    AppRoutes.houseDetail => _requireLogin(
        AppRoutes.houseDetail,
        arguments,
        () => const HouseDetail(),
      ),
    _ => null,
  };
}
