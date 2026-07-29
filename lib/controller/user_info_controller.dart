import 'package:get/get.dart';

class UserInfoController extends GetxController {
  static const Map<String, dynamic> _emptyUserInfo = <String, dynamic>{
    'nickName': '',
    'avatar': '',
    'id': '',
  };

  Map<String, dynamic> userInfo = Map<String, dynamic>.from(_emptyUserInfo);

  void updateUserInfo(Map<String, dynamic> info) {
    userInfo = Map<String, dynamic>.from(info);
    update();
  }

  void clearUserInfo() {
    updateUserInfo(_emptyUserInfo);
  }
}
