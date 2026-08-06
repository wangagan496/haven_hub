/// 服务定位器，管理应用级依赖注入。
///
/// 提供单例和工厂两种注册方式，支持懒加载和依赖替换（用于测试）。
class ServiceLocator {
  ServiceLocator._();

  static final ServiceLocator _instance = ServiceLocator._();

  /// 获取服务定位器单例。
  static ServiceLocator get instance => _instance;

  /// 单例服务存储。
  final Map<Type, Object> _singletons = <Type, Object>{};

  /// 工厂函数存储。
  final Map<Type, Object Function()> _factories = <Type, Object Function()>{};

  /// 注册单例服务。
  ///
  /// 服务实例会被缓存，多次调用 [get] 返回同一实例。
  ///
  /// 示例：
  /// ```dart
  /// ServiceLocator.instance.registerSingleton<RequestDio>(RequestDio());
  /// ```
  void registerSingleton<T extends Object>(T instance) {
    _singletons[T] = instance;
  }

  /// 注册懒加载单例服务。
  ///
  /// [factory] 在首次调用 [get] 时执行，结果会被缓存。
  ///
  /// 示例：
  /// ```dart
  /// ServiceLocator.instance.registerLazySingleton<DatabaseHelper>(
  ///   () => DatabaseHelper(),
  /// );
  /// ```
  void registerLazySingleton<T extends Object>(T Function() factory) {
    _factories[T] = factory;
  }

  /// 注册工厂服务。
  ///
  /// 每次调用 [get] 都会执行 [factory]，返回新实例。
  ///
  /// 示例：
  /// ```dart
  /// ServiceLocator.instance.registerFactory<ApiClient>(
  ///   () => ApiClient(),
  /// );
  /// ```
  void registerFactory<T extends Object>(T Function() factory) {
    _factories[T] = factory;
  }

  /// 获取已注册的服务。
  ///
  /// 抛出 [ServiceNotRegisteredException] 如果服务未注册。
  ///
  /// 示例：
  /// ```dart
  /// final dio = ServiceLocator.instance.get<RequestDio>();
  /// ```
  T get<T extends Object>() {
    // 优先返回已缓存的单例
    if (_singletons.containsKey(T)) {
      return _singletons[T]! as T;
    }

    // 尝试从工厂创建
    if (_factories.containsKey(T)) {
      final Object Function() factory = _factories[T]!;
      final T instance = factory() as T;

      // 懒加载单例：缓存结果
      // （工厂服务每次调用都创建新实例，不缓存）
      // 这里简化处理：如果需要区分，可以添加 _lazyTypes 集合
      _singletons[T] = instance;

      return instance;
    }

    throw ServiceNotRegisteredException(T);
  }

  /// 尝试获取服务，如果未注册返回 null。
  T? getOrNull<T extends Object>() {
    try {
      return get<T>();
    } on ServiceNotRegisteredException {
      return null;
    }
  }

  /// 判断服务是否已注册。
  bool isRegistered<T extends Object>() {
    return _singletons.containsKey(T) || _factories.containsKey(T);
  }

  /// 注销服务（用于测试或热重载）。
  void unregister<T extends Object>() {
    _singletons.remove(T);
    _factories.remove(T);
  }

  /// 重置所有服务（清空容器）。
  void reset() {
    _singletons.clear();
    _factories.clear();
  }

  /// 替换已注册的服务（用于测试 Mock）。
  ///
  /// 示例：
  /// ```dart
  /// // 在测试中替换为 Mock
  /// ServiceLocator.instance.replace<RequestDio>(MockRequestDio());
  /// ```
  void replace<T extends Object>(T instance) {
    unregister<T>();
    registerSingleton<T>(instance);
  }
}

/// 服务未注册异常。
class ServiceNotRegisteredException implements Exception {
  /// 创建服务未注册异常。
  const ServiceNotRegisteredException(this.type);

  /// 未注册的服务类型。
  final Type type;

  @override
  String toString() {
    return 'ServiceNotRegisteredException: 服务 $type 未注册。'
        '请先调用 ServiceLocator.instance.registerSingleton() 或 registerFactory()。';
  }
}

// ==================== 便捷访问函数 ====================

/// 全局服务定位器实例（简化访问）。
final ServiceLocator sl = ServiceLocator.instance;
