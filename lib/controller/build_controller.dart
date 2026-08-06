import 'package:get/get.dart' show Get, GetxController, Inst;

import '../models/building_info.dart';

/// 选楼流程的状态控制器。
///
/// 管理从社区选择 → 楼栋选择 → 房间选择的整个流程状态。
class BuildController extends GetxController {
  /// 取当前选楼流程的控制器，未注册时就地创建。
  ///
  /// 选楼流程的四个页面都可以被直接导航到（Web 刷新、深链接不会经过 `/`，
  /// TabsPage 里的 `Get.put` 也就不会执行），因此不能假设控制器已存在。
  static BuildController instance() {
    return Get.isRegistered<BuildController>()
        ? Get.find<BuildController>()
        : Get.put(BuildController());
  }

  BuildingInfo _info = const BuildingInfo();

  /// 当前选中的建筑信息。
  BuildingInfo get buildingInfo => _info;

  /// 已选择的楼栋（向后兼容）。
  String get build => _info.building;

  /// 已选择的房间（向后兼容）。
  String get room => _info.room;

  /// 更新小区信息（重置楼栋和房间）。
  void updateBuildingInfo(Map<String, dynamic> info) {
    _info = BuildingInfo(
      name: info['name']?.toString().trim() ?? '',
      address: info['address']?.toString().trim() ?? '',
    );
    update();
  }

  /// 更新楼栋信息（重置房间）。
  void updateBuild(String value) {
    _info = _info.copyWith(building: value.trim(), room: '');
    update();
  }

  /// 更新房间信息。
  void updateRoom(String value) {
    _info = _info.copyWith(room: value.trim());
    update();
  }

  /// 清空所有选楼信息。
  void clearBuildingInfo() {
    _info = const BuildingInfo();
    update();
  }
}
