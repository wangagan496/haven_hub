import 'package:flutter/material.dart';

class GlobalVariable {
  const GlobalVariable._();

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();
  static const String tokenKey = 'flutter_enjoy_plus';
  static const String refreshTokenKey = 'flutter_enjoy_plus_refresh';

  // 可通过 --dart-define=API_BASE_URL=... 切换正式、测试或本地 Mock 接口。
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://live-api.itheima.net/',
  );
  static const Duration networkTimeout = Duration(seconds: 10);
  static const int successCode = 10000;
}

class HttpPath {
  const HttpPath._();

  static const String announcement = 'announcement';
  static const String sendCode = 'code';
  static const String login = 'login';
  static const String userInfo = 'userInfo';
  static const String upload = 'upload';
  static const String houseList = 'room';
  static const String refreshToken = 'refreshToken';

  static String announcementDetail(String id) {
    return '$announcement/${Uri.encodeComponent(id)}';
  }
}
