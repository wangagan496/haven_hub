class GlobalVariable {
  const GlobalVariable._();

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

  static String announcementDetail(String id) {
    return '$announcement/${Uri.encodeComponent(id)}';
  }
}
