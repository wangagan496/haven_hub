import '../utils/request_dio.dart';
import '../utils/token_manager.dart';
import 'service_locator.dart';

/// 应用初始化器，负责依赖注册和预加载。
class AppInitializer {
  const AppInitializer._();

  /// 初始化应用依赖。
  ///
  /// 在 [main] 函数中调用，在 [runApp] 之前。
  static Future<void> initialize() async {
    // 注册核心服务
    _registerCoreServices();

    // 注册网络服务
    _registerNetworkServices();

    // 注册业务服务
    _registerBusinessServices();

    // 预加载必要数据
    await _preloadData();
  }

  /// 注册核心服务（单例）。
  static void _registerCoreServices() {
    sl.registerSingleton<TokenManager>(tokenManager);
  }

  /// 注册网络服务。
  static void _registerNetworkServices() {
    sl.registerSingleton<RequestDio>(requestDio);
  }

  /// 注册业务服务。
  static void _registerBusinessServices() {
    // 示例：注册其他业务服务
    // sl.registerLazySingleton<UserRepository>(() => UserRepository());
    // sl.registerFactory<Logger>(() => Logger());
  }

  /// 预加载数据。
  static Future<void> _preloadData() async {
    // 示例：预加载用户信息、缓存数据等
    // await sl.get<TokenManager>().loadToken();
  }
}
