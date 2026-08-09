import 'package:flutter/material.dart';

/// 全局常量配置类。
///
/// 包含应用级别的配置项，如 API 地址、超时设置、密钥等。
/// 支持通过 `--dart-define` 在编译时覆盖默认值。
class GlobalVariable {
  const GlobalVariable._();

  /// 全局导航器 Key，用于在无 BuildContext 时执行导航。
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// 本地存储的 Token 键名。
  static const String tokenKey = 'flutter_enjoy_plus';

  /// 本地存储的 Refresh Token 键名。
  static const String refreshTokenKey = 'flutter_enjoy_plus_refresh';

  /// API 基础地址。
  ///
  /// 可通过 `--dart-define=API_BASE_URL=...` 切换正式、测试或本地 Mock 接口。
  ///
  /// 示例：
  /// ```bash
  /// flutter run --dart-define=API_BASE_URL=https://test-api.example.com/
  /// ```
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://live-api.itheima.net/',
  );

  /// 网络请求超时时间。
  static const Duration networkTimeout = Duration(seconds: 10);

  /// 业务成功的状态码。
  static const int successCode = 10000;

  /// 腾讯地图服务密钥。
  ///
  /// 必须通过 `--dart-define=TENCENT_MAP_KEY=...` 显式提供，避免把真实密钥
  /// 编译进客户端产物。生产环境更推荐使用服务端代理。
  static const String tencentMapKey = String.fromEnvironment(
    'TENCENT_MAP_KEY',
  );

  /// 腾讯位置服务的基础地址。
  ///
  /// 原生平台默认直连腾讯；Flutter Web 调试时可通过
  /// `TENCENT_MAP_API_BASE_URL` 指向本机开发代理，绕过浏览器 CORS 限制。
  static const String tencentMapApiBaseUrl = String.fromEnvironment(
    'TENCENT_MAP_API_BASE_URL',
    defaultValue: 'https://apis.map.qq.com/',
  );

  /// 定位坐标系类型。
  ///
  /// 支持的值：
  /// - `auto`: 自动判断（模拟器用 GCJ-02，真机用 WGS84）
  /// - `wgs84`: 强制使用 WGS84（GPS 原始坐标）
  /// - `gcj02`: 强制使用 GCJ-02（火星坐标系）
  static const String locationCoordinateSystem = String.fromEnvironment(
    'LOCATION_COORDINATE_SYSTEM',
    defaultValue: 'auto',
  );
}

/// HTTP 接口路径常量。
///
/// 集中管理所有 API 端点，避免硬编码路径字符串分散在代码各处。
class HttpPath {
  const HttpPath._();

  // 业务接口路径（相对于 baseUrl）
  static const String announcement = 'announcement';
  static const String sendCode = 'code';
  static const String login = 'login';
  static const String userInfo = 'userInfo';
  static const String upload = 'upload';
  static const String houseList = 'room';
  static const String refreshToken = 'refreshToken';
  static const String repair = 'repair';
  static const String repairItem = 'repairItem';
  static const String visitor = 'visitor';

  // 腾讯地图服务接口（相对于可配置的 tencentMapApiBaseUrl）
  static final String tencentCoordinateTranslate =
      _tencentMapUrl('ws/coord/v1/translate');
  static final String tencentReverseGeocode = _tencentMapUrl('ws/geocoder/v1/');
  static final String tencentPlaceSearch = _tencentMapUrl('ws/place/v1/search');
  static final String tencentIpLocation = _tencentMapUrl('ws/location/v1/ip');

  static String _tencentMapUrl(String path) {
    const String baseUrl = GlobalVariable.tencentMapApiBaseUrl;
    return '${baseUrl.endsWith('/') ? baseUrl : '$baseUrl/'}$path';
  }

  /// 获取公告详情路径。
  ///
  /// [id] 会被自动 URI 编码，防止特殊字符导致的路径错误。
  static String announcementDetail(String id) {
    return '$announcement/${Uri.encodeComponent(id)}';
  }

  /// 获取房屋详情路径。
  ///
  /// [id] 会被自动 URI 编码。
  static String houseDetail(String id) {
    return '$houseList/${Uri.encodeComponent(id)}';
  }

  static String repairDetail(String id) => '$repair/${Uri.encodeComponent(id)}';

  static String cancelRepair(String id) =>
      'cancel/repair/${Uri.encodeComponent(id)}';

  static String visitorDetail(String id) =>
      '$visitor/${Uri.encodeComponent(id)}';
}
