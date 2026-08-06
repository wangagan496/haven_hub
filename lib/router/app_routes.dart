import 'package:flutter/material.dart';

/// 应用路由配置类。
///
/// 集中管理所有路由路径和导航方法，提供类型安全的路由访问。
class AppRoutes {
  const AppRoutes._();

  // ==================== 路由路径常量 ====================

  /// 首页（底部导航容器）。
  static const String home = '/';

  /// 登录页。
  static const String login = '/login';

  /// 个人资料页。
  static const String profile = '/profile';

  /// 公告详情页。
  static const String noticeDetail = '/notice-detail';

  /// 房屋列表页。
  static const String houseList = '/house-list';

  /// 房屋详情页。
  static const String houseDetail = '/house-detail';

  /// 房屋表单页（新增/编辑）。
  static const String houseForm = '/house-form';

  /// 位置选择页。
  static const String locationList = '/location-list';

  /// 楼栋选择页。
  static const String buildingList = '/building-list';

  /// 房间选择页。
  static const String roomList = '/room-list';

  // ==================== 类型安全的导航方法 ====================

  /// 导航到登录页。
  static Future<T?> toLogin<T>(
    BuildContext context, {
    String? toName,
    Object? toArguments,
  }) {
    return Navigator.pushNamed<T>(
      context,
      login,
      arguments: LoginArguments(
        toName: toName,
        toArguments: toArguments,
      ),
    );
  }

  /// 导航到个人资料页。
  static Future<T?> toProfile<T>(BuildContext context) {
    return Navigator.pushNamed<T>(context, profile);
  }

  /// 导航到公告详情页。
  static Future<T?> toNoticeDetail<T>(
    BuildContext context, {
    required String noticeId,
  }) {
    return Navigator.pushNamed<T>(
      context,
      noticeDetail,
      arguments: NoticeDetailArguments(noticeId: noticeId),
    );
  }

  /// 导航到房屋列表页。
  static Future<T?> toHouseList<T>(BuildContext context) {
    return Navigator.pushNamed<T>(context, houseList);
  }

  /// 导航到房屋详情页。
  static Future<T?> toHouseDetail<T>(
    BuildContext context, {
    required String houseId,
  }) {
    return Navigator.pushNamed<T>(
      context,
      houseDetail,
      arguments: HouseDetailArguments(houseId: houseId),
    );
  }

  /// 导航到房屋表单页（新增模式）。
  static Future<T?> toHouseFormCreate<T>(BuildContext context) {
    return Navigator.pushNamed<T>(
      context,
      houseForm,
      arguments: const HouseFormArguments(mode: HouseFormMode.create),
    );
  }

  /// 导航到房屋表单页（编辑模式）。
  static Future<T?> toHouseFormEdit<T>(
    BuildContext context, {
    required String houseId,
  }) {
    return Navigator.pushNamed<T>(
      context,
      houseForm,
      arguments: HouseFormArguments(
        mode: HouseFormMode.edit,
        houseId: houseId,
      ),
    );
  }

  /// 导航到位置选择页。
  static Future<T?> toLocationList<T>(BuildContext context) {
    return Navigator.pushNamed<T>(context, locationList);
  }

  /// 导航到楼栋选择页。
  static Future<T?> toBuildingList<T>(BuildContext context) {
    return Navigator.pushNamed<T>(context, buildingList);
  }

  /// 导航到房间选择页。
  static Future<T?> toRoomList<T>(BuildContext context) {
    return Navigator.pushNamed<T>(context, roomList);
  }

  /// 替换当前路由（不保留历史记录）。
  static Future<T?> replaceTo<T>(
    BuildContext context,
    String routeName, {
    Object? arguments,
  }) {
    return Navigator.pushReplacementNamed<T, void>(
      context,
      routeName,
      arguments: arguments,
    );
  }

  /// 清空路由栈并导航到指定页面。
  static Future<T?> offAllTo<T>(
    BuildContext context,
    String routeName, {
    Object? arguments,
  }) {
    return Navigator.pushNamedAndRemoveUntil<T>(
      context,
      routeName,
      (Route<dynamic> route) => false,
      arguments: arguments,
    );
  }

  /// 返回上一页。
  static void back<T>(BuildContext context, [T? result]) {
    Navigator.pop<T>(context, result);
  }

  /// 判断是否可以返回上一页。
  static bool canPop(BuildContext context) {
    return Navigator.canPop(context);
  }
}

// ==================== 路由参数类 ====================

/// 登录页参数。
class LoginArguments {
  const LoginArguments({
    this.toName,
    this.toArguments,
  });

  /// 登录成功后跳转的路由名称。
  final String? toName;

  /// 登录成功后跳转携带的参数。
  final Object? toArguments;
}

/// 公告详情页参数。
class NoticeDetailArguments {
  const NoticeDetailArguments({required this.noticeId});

  /// 公告 ID。
  final String noticeId;
}

/// 房屋详情页参数。
class HouseDetailArguments {
  const HouseDetailArguments({required this.houseId});

  /// 房屋 ID。
  final String houseId;
}

/// 房屋表单模式。
enum HouseFormMode {
  /// 新增模式。
  create,

  /// 编辑模式。
  edit,
}

/// 房屋表单页参数。
class HouseFormArguments {
  const HouseFormArguments({
    required this.mode,
    this.houseId,
  });

  /// 表单模式（新增/编辑）。
  final HouseFormMode mode;

  /// 房屋 ID（编辑模式必传）。
  final String? houseId;

  /// 是否为新增模式。
  bool get isCreate => mode == HouseFormMode.create;

  /// 是否为编辑模式。
  bool get isEdit => mode == HouseFormMode.edit;
}
