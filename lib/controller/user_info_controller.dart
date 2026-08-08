import 'package:get/get.dart' show GetxController;

import '../models/user_info.dart';

class UserInfoController extends GetxController {
  UserInfo currentUser = const UserInfo.empty();

  /// Compatibility projection for older callers. New code should use
  /// [currentUser] so field names are checked by the analyzer.
  Map<String, dynamic> get userInfo => <String, dynamic>{
        'id': currentUser.id,
        'avatar': currentUser.avatarUrl,
        'nickName': currentUser.nickName,
      };

  void updateUser(UserInfo user) {
    currentUser = user;
    update();
  }

  void updateUserInfo(Map<String, dynamic> info) {
    updateUser(UserInfo.fromJson(info));
  }

  void clearUserInfo() {
    updateUser(const UserInfo.empty());
  }
}
