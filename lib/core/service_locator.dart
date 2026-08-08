/// Lightweight type-safe dependency container used by application startup
/// and tests.  Register a singleton, lazy singleton, or fresh factory with
/// explicit semantics rather than relying on global mutable lookups.
class ServiceLocator {
  ServiceLocator._();

  static final ServiceLocator _instance = ServiceLocator._();

  static ServiceLocator get instance => _instance;

  final Map<Type, Object> _singletons = <Type, Object>{};
  final Map<Type, Object Function()> _lazyFactories =
      <Type, Object Function()>{};
  final Map<Type, Object Function()> _factories = <Type, Object Function()>{};

  void registerSingleton<T extends Object>(T instance) {
    _lazyFactories.remove(T);
    _factories.remove(T);
    _singletons[T] = instance;
  }

  void registerLazySingleton<T extends Object>(T Function() factory) {
    _singletons.remove(T);
    _factories.remove(T);
    _lazyFactories[T] = factory;
  }

  void registerFactory<T extends Object>(T Function() factory) {
    _singletons.remove(T);
    _lazyFactories.remove(T);
    _factories[T] = factory;
  }

  T get<T extends Object>() {
    final Object? singleton = _singletons[T];
    if (singleton != null) {
      return singleton as T;
    }

    final Object Function()? lazyFactory = _lazyFactories[T];
    if (lazyFactory != null) {
      final T instance = lazyFactory() as T;
      _singletons[T] = instance;
      return instance;
    }

    final Object Function()? factory = _factories[T];
    if (factory != null) {
      return factory() as T;
    }

    throw ServiceNotRegisteredException(T);
  }

  T? getOrNull<T extends Object>() {
    try {
      return get<T>();
    } on ServiceNotRegisteredException {
      return null;
    }
  }

  bool isRegistered<T extends Object>() {
    return _singletons.containsKey(T) ||
        _lazyFactories.containsKey(T) ||
        _factories.containsKey(T);
  }

  void unregister<T extends Object>() {
    _singletons.remove(T);
    _lazyFactories.remove(T);
    _factories.remove(T);
  }

  void reset() {
    _singletons.clear();
    _lazyFactories.clear();
    _factories.clear();
  }

  void replace<T extends Object>(T instance) {
    unregister<T>();
    registerSingleton<T>(instance);
  }
}

class ServiceNotRegisteredException implements Exception {
  const ServiceNotRegisteredException(this.type);

  final Type type;

  @override
  String toString() {
    return 'ServiceNotRegisteredException: service $type is not registered.';
  }
}

final ServiceLocator sl = ServiceLocator.instance;
