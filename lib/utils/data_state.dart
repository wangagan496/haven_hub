/// 数据加载状态枚举
enum LoadState {
  /// 初始状态，还未开始加载
  idle,

  /// 加载中
  loading,

  /// 加载成功
  success,

  /// 加载失败
  error,
}

/// 统一的数据状态包装类
///
/// 将加载状态、数据、错误信息统一管理，避免状态不一致。
///
/// 使用示例：
/// ```dart
/// DataState<List<Item>> _state = DataState.idle();
///
/// // 开始加载，保留旧数据
/// setState(() => _state = DataState.loading(_state.data));
///
/// // 加载成功
/// setState(() => _state = DataState.success(items));
///
/// // 加载失败，保留旧数据
/// setState(() => _state = DataState.error('网络错误', _state.data));
/// ```
class DataState<T> {
  /// 当前加载状态
  final LoadState state;

  /// 数据（可能为空）
  final T? data;

  /// 错误信息（仅在 state == error 时有值）
  final String? errorMessage;

  /// 初始状态：还未开始加载
  DataState.idle()
      : state = LoadState.idle,
        data = null,
        errorMessage = null;

  /// 加载中状态
  ///
  /// [oldData] 保留的旧数据，用于刷新场景
  DataState.loading([T? oldData])
      : state = LoadState.loading,
        data = oldData,
        errorMessage = null;

  /// 加载成功状态
  DataState.success(T this.data)
      : state = LoadState.success,
        errorMessage = null;

  /// 加载失败状态
  ///
  /// [message] 错误信息
  /// [oldData] 保留的旧数据，用于刷新失败场景
  DataState.error(String message, [T? oldData])
      : state = LoadState.error,
        data = oldData,
        errorMessage = message;

  /// 是否有数据（不管是旧数据还是新数据）
  bool get hasData => data != null;

  /// 是否正在加载
  bool get isLoading => state == LoadState.loading;

  /// 是否有错误
  bool get hasError => state == LoadState.error;

  /// 是否加载成功
  bool get isSuccess => state == LoadState.success;

  @override
  String toString() {
    return 'DataState<$T>(state: $state, hasData: $hasData, error: $errorMessage)';
  }
}
