import 'package:flutter/material.dart';

import '../api/home.dart';
import '../models/device_map_location.dart';
import '../pages/building/building_list.dart';
import '../pages/house/house_detail.dart';
import '../pages/house/house_drafts.dart';
import '../pages/house/house_form.dart';
import '../pages/house/house_list.dart';
import '../pages/location/location_list.dart';
import '../pages/login/index.dart';
import '../pages/notice_detail/index.dart';
import '../pages/notifications/notification_page.dart';
import '../pages/profile/index.dart';
import '../pages/repair/repair_pages.dart';
import '../pages/room/room_list.dart';
import '../pages/tabs_page/index.dart';
import '../pages/visitor/visitor_pages.dart';
import '../utils/token_manager.dart';
import 'app_routes.dart';

/// 未登录时跳转到登录页，登录成功后回到 [routeName] 并带回原始 [pageData]。
///
/// 页面数据必须继续传递：房屋表单依靠其中的 id 区分“新增”和“修改”，
/// 丢掉页面数据会让用户登录后回到一个空白的新增表单。
Widget _requireLogin(
  String routeName,
  Object? pageData,
  Widget Function() builder,
) {
  if (tokenManager.getToken().isEmpty) {
    return FutureBuilder<void>(
      future: tokenManager.loadTokens(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.hasError || tokenManager.getToken().isEmpty) {
          return LoginPage(toName: routeName, toArguments: pageData);
        }
        return builder();
      },
    );
  }
  return builder();
}

/// 冷启动初始路由的页面栈：首页之上只放目标页，不按 "/" 逐级拆分。
///
/// 无法识别的目标页由调用方生成路由时过滤掉，最终只剩首页。
List<String> initialRouteNames(String initialRoute) =>
    initialRoute.isEmpty || initialRoute == home
        ? const <String>[home]
        : <String>[home, initialRoute];

/// 根据路由名称生成对应的页面组件。
///
/// 使用 [AppRoutes] 中定义的路由常量匹配路径。
Widget? getRouteWidget(
  String? routeName, {
  required AnnouncementLoader announcementLoader,
  required AnnouncementDetailLoader announcementDetailLoader,
  Object? pageData,
}) {
  final Match? notification = routeName == null
      ? null
      : RegExp('^$notifications(?:/([a-f0-9-]{36}))?\$')
          .firstMatch(routeName);
  if (notification != null) {
    return _requireLogin(routeName!, pageData,
        () => NotificationPage(notificationId: notification.group(1)));
  }
  return switch (routeName) {
    home => TabsPage(announcementLoader: announcementLoader),
    noticeDetail => NoticeDetail(
        detailLoader: announcementDetailLoader,
      ),
    login => const LoginPage(),
    profile => _requireLogin(
        profile,
        pageData,
        () => const ProfilePage(),
      ),
    houseList => _requireLogin(
        houseList,
        pageData,
        () => const HouseList(),
      ),
    houseDrafts => _requireLogin(houseDrafts, pageData, () => const HouseDraftsPage()),
    locationList => _requireLogin(
        locationList,
        pageData,
        () => LocationList(draftId: pageData is HouseSelectionArguments ? pageData.draftId : null),
      ),
    buildingList => _requireLogin(
        buildingList,
        pageData,
        () => BuildingList(
          draftId: pageData is HouseSelectionArguments ? pageData.draftId : null,
          deviceLocation: pageData is DeviceMapLocation ? pageData
              : pageData is HouseSelectionArguments ? pageData.deviceLocation : null,
        ),
      ),
    roomList => _requireLogin(
        roomList,
        pageData,
        () => RoomList(draftId: pageData is HouseSelectionArguments ? pageData.draftId : null),
      ),
    houseForm => _requireLogin(
        houseForm,
        pageData,
        () => HouseForm(draftId: pageData is HouseFormArguments ? pageData.draftId : null),
      ),
    houseDetail => _requireLogin(
        houseDetail,
        pageData,
        () => const HouseDetail(),
      ),
    repairList => _requireLogin(
        repairList,
        pageData,
        () => const RepairListPage(),
      ),
    repairDetail => _requireLogin(
        repairDetail,
        pageData,
        () => const RepairDetailPage(),
      ),
    repairForm => _requireLogin(
        repairForm,
        pageData,
        () => const RepairFormPage(),
      ),
    visitorList => _requireLogin(
        visitorList,
        pageData,
        () => const VisitorListPage(),
      ),
    visitorDetail => _requireLogin(
        visitorDetail,
        pageData,
        () => const VisitorDetailPage(),
      ),
    visitorForm => _requireLogin(
        visitorForm,
        pageData,
        () => const VisitorFormPage(),
      ),
    _ => null,
  };
}
