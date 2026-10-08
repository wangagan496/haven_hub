import 'package:get/get.dart' show GetxController;

import '../models/user_info.dart';
import '../utils/token_manager.dart';

class UserInfoController extends GetxController {
  UserInfo currentUser = const UserInfo.empty();
  int? _currentUserSessionId;

  /// 用户信息属于哪次登录；换账号后不能用尚未刷新的旧 ID 读取草稿。
  int? get currentUserSessionId => _currentUserSessionId;

  /// Compatibility projection for older callers. New code should use
  /// [currentUser] so field names are checked by the analyzer.
  Map<String, dynamic> get userInfo => <String, dynamic>{
        'id': currentUser.id,
        'avatar': currentUser.avatarUrl,
        'nickName': currentUser.nickName,
      };

  void updateUser(UserInfo user) {
    currentUser = user;
    _currentUserSessionId = user.id.isEmpty ? null : tokenManager.sessionId;
    update();
  }

  void updateUserInfo(Map<String, dynamic> info) {
    updateUser(UserInfo.fromJson(info));
  }

  void clearUserInfo() {
    updateUser(const UserInfo.empty());
  }
}
