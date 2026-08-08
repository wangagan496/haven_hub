import 'package:dio/dio.dart' as dio;

import '../constant/index.dart';
import 'app_exception.dart';
import 'emitter.dart';
import 'logger.dart';
import 'token_manager.dart';

typedef RefreshDioFactory = dio.Dio Function();

class RequestDio {
  RequestDio({
    dio.Dio? client,
    RefreshDioFactory? refreshDioFactory,
  })  : _dio = client ?? dio.Dio(),
        _refreshDioFactory = refreshDioFactory ?? dio.Dio.new {
    // 配置请求基地址和超时时间，使用级联（链式）调用。
    _configureDio(_dio);

    // 添加日志拦截器（在其他拦截器之前）
    if (Logger.enabled) {
      _dio.interceptors.add(_createLoggingInterceptor());
    }

    _dio.interceptors.add(
      dio.InterceptorsWrapper(
        // 请求拦截器：统一注入 Bearer Token。
        onRequest: (
          dio.RequestOptions options,
          dio.RequestInterceptorHandler handler,
        ) {
          final String token = tokenManager.getToken();
          final bool skipAuthorization =
              options.extra['skipAuthorization'] == true;
          if (token.isNotEmpty && !skipAuthorization) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        // 响应拦截器：直接透传，业务错误由 _handleResponse 处理。
        onResponse: (
          dio.Response<dynamic> response,
          dio.ResponseInterceptorHandler handler,
        ) {
          handler.next(response);
        },
        // 错误拦截器：将所有网络/HTTP 错误统一转换为 NetworkException，
        // 并附带对用户友好的中文提示。
        onError: (
          dio.DioException error,
          dio.ErrorInterceptorHandler handler,
        ) async {
          final bool isRetry = error.requestOptions.extra['isRetry'] == true;

          if (error.response?.statusCode == 401 && !isRetry) {
            final String refreshToken = tokenManager.getRefreshToken();
            bool shouldLogout = refreshToken.isEmpty;

            if (refreshToken.isNotEmpty) {
              final bool refreshSuccess = await _tryRefreshToken(refreshToken);
              if (refreshSuccess) {
                try {
                  // 重发原始请求，标记为重试防止无限循环
                  final dio.RequestOptions requestOptions =
                      _createRetryRequest(error.requestOptions);
                  final dio.Response<dynamic> retryResponse =
                      await _dio.fetch(requestOptions);
                  return handler.resolve(retryResponse);
                } on dio.DioException catch (e) {
                  error = e;
                  shouldLogout = e.response?.statusCode == 401;
                }
              } else {
                shouldLogout = true;
              }
            }

            if (shouldLogout) {
              await _clearSessionAndNotify();
            }
          }

          final NetworkException appError = _mapDioError(error);
          handler.reject(
            dio.DioException(
              requestOptions: error.requestOptions,
              response: error.response,
              type: error.type,
              error: appError,
              stackTrace: error.stackTrace,
              message: appError.message,
            ),
          );
        },
      ),
    );
  }

  final dio.Dio _dio;
  final RefreshDioFactory _refreshDioFactory;
  Future<bool>? _refreshTokenFuture;

  static void _configureDio(dio.Dio client) {
    client.options
      ..baseUrl = GlobalVariable.baseUrl
      ..connectTimeout = GlobalVariable.networkTimeout
      ..receiveTimeout = GlobalVariable.networkTimeout
      ..sendTimeout = GlobalVariable.networkTimeout
      ..responseType = dio.ResponseType.json;
  }

  /// 创建日志拦截器，记录请求和响应详情。
  static dio.InterceptorsWrapper _createLoggingInterceptor() {
    return dio.InterceptorsWrapper(
      onRequest: (
        dio.RequestOptions options,
        dio.RequestInterceptorHandler handler,
      ) {
        Logger.network(
          '→ ${options.method} ${_redactUri(options.uri)}',
          _buildRequestLog(options),
        );
        handler.next(options);
      },
      onResponse: (
        dio.Response<dynamic> response,
        dio.ResponseInterceptorHandler handler,
      ) {
        final int duration = DateTime.now()
            .difference(
              response.requestOptions.extra['request_time'] as DateTime? ??
                  DateTime.now(),
            )
            .inMilliseconds;
        Logger.network(
          '← ${response.statusCode} '
          '${_redactUri(response.requestOptions.uri)} (${duration}ms)',
          _buildResponseLog(response),
        );
        handler.next(response);
      },
      onError: (
        dio.DioException error,
        dio.ErrorInterceptorHandler handler,
      ) {
        Logger.error(
          '✖ ${error.requestOptions.method} '
          '${_redactUri(error.requestOptions.uri)}',
          error.message,
        );
        handler.next(error);
      },
    );
  }

  /// 构建请求日志内容。
  static Map<String, dynamic> _buildRequestLog(dio.RequestOptions options) {
    // 记录请求时间，用于计算耗时
    options.extra['request_time'] = DateTime.now();

    final Map<String, dynamic> log = <String, dynamic>{
      'method': options.method,
      'url': _redactUri(options.uri).toString(),
    };

    if (options.queryParameters.isNotEmpty) {
      log['params'] = _redactSensitiveValues(options.queryParameters);
    }

    if (options.headers.isNotEmpty) {
      // 隐藏敏感信息
      final Map<String, dynamic> safeHeaders = Map<String, dynamic>.from(
        options.headers,
      );
      if (safeHeaders.containsKey('Authorization')) {
        safeHeaders['Authorization'] = '***';
      }
      log['headers'] = safeHeaders;
    }

    if (options.data != null && options.data is! dio.FormData) {
      log['body'] = options.data;
    }

    return log;
  }

  static Uri _redactUri(Uri uri) {
    if (!uri.queryParameters.containsKey('key')) return uri;
    return uri.replace(
      queryParameters: <String, String>{
        ...uri.queryParameters,
        'key': '***',
      },
    );
  }

  static Map<String, dynamic> _redactSensitiveValues(
    Map<String, dynamic> values,
  ) {
    return <String, dynamic>{
      for (final MapEntry<String, dynamic> entry in values.entries)
        entry.key: entry.key.toLowerCase() == 'key' ? '***' : entry.value,
    };
  }

  /// 构建响应日志内容。
  static Map<String, dynamic> _buildResponseLog(
      dio.Response<dynamic> response) {
    final Map<String, dynamic> log = <String, dynamic>{
      'status': response.statusCode,
    };

    if (response.data != null) {
      // 限制响应体日志长度，避免过大的数据污染日志
      final String dataStr = response.data.toString();
      // ignore: require_trailing_commas
      log['body'] = dataStr.length > 500
          ? '${dataStr.substring(0, 500)}... (truncated)'
          : response.data;
    }

    return log;
  }

  dio.RequestOptions _createRetryRequest(
    dio.RequestOptions requestOptions,
  ) {
    final dynamic requestData = requestOptions.data;
    final dynamic retryData =
        requestData is dio.FormData ? requestData.clone() : requestData;
    return requestOptions.copyWith(
      data: retryData,
      headers: <String, dynamic>{
        ...requestOptions.headers,
        'Authorization': 'Bearer ${tokenManager.getToken()}',
      },
      extra: <String, dynamic>{
        ...requestOptions.extra,
        'isRetry': true,
      },
    );
  }

  Future<void> _clearSessionAndNotify() async {
    try {
      await tokenManager.deleteToken();
    } on Object {
      // 即使本地持久化清理失败，也必须通知界面退出当前登录态。
    }
    eventBus.fire(const LogoutEvent());
  }

  Future<bool> _tryRefreshToken(String refreshToken) {
    if (_refreshTokenFuture != null) {
      return _refreshTokenFuture!;
    }

    _refreshTokenFuture = () async {
      try {
        final dio.Dio tokenDio = _refreshDioFactory();
        _configureDio(tokenDio);
        final dio.Response<dynamic> response = await tokenDio.post<dynamic>(
          HttpPath.refreshToken,
          options: dio.Options(
            headers: <String, dynamic>{
              'Authorization': 'Bearer $refreshToken',
            },
          ),
        );
        final dynamic body = response.data;

        if (body is Map<dynamic, dynamic>) {
          final int? businessCode = _parseBusinessCode(body['code']);
          if (businessCode == GlobalVariable.successCode) {
            final dynamic data = body['data'];
            if (data is Map<dynamic, dynamic>) {
              final String newToken = data['token']?.toString() ?? '';
              final String newRefreshToken =
                  data['refreshToken']?.toString() ?? '';
              if (newToken.isEmpty || newRefreshToken.isEmpty) {
                return false;
              }
              final bool saved = await tokenManager.setToken(
                newToken,
                refreshToken: newRefreshToken,
              );
              if (saved) {
                eventBus.fire(const RefreshEvent());
              }
              return saved;
            }
          }
        }
        return false;
      } on Object catch (_) {
        return false;
      } finally {
        _refreshTokenFuture = null;
      }
    }();

    return _refreshTokenFuture!;
  }

  /// 将 Dio 底层异常映射为 [NetworkException]，提供友好中文错误文案。
  static NetworkException _mapDioError(dio.DioException error) {
    switch (error.type) {
      case dio.DioExceptionType.connectionTimeout:
        return const NetworkException('连接服务器超时，请检查网络');
      case dio.DioExceptionType.sendTimeout:
        return const NetworkException('数据发送超时，请检查网络');
      case dio.DioExceptionType.receiveTimeout:
        return const NetworkException('数据接收超时，请检查网络');
      case dio.DioExceptionType.transformTimeout:
        return const NetworkException('响应数据解析超时，请稍后重试');
      case dio.DioExceptionType.connectionError:
        return const NetworkException('网络连接失败，请检查网络设置');
      case dio.DioExceptionType.badCertificate:
        return const NetworkException('SSL 证书验证失败，连接不安全');
      case dio.DioExceptionType.cancel:
        return const NetworkException('请求已取消');
      case dio.DioExceptionType.badResponse:
        return _mapHttpStatus(error.response?.statusCode);
      case dio.DioExceptionType.unknown:
        return NetworkException('未知网络错误：${error.message ?? ''}');
    }
  }

  /// 将 HTTP 状态码映射为 [NetworkException]。
  static NetworkException _mapHttpStatus(int? statusCode) {
    final String message = switch (statusCode) {
      400 => '请求参数有误，请检查输入',
      401 => '登录已过期，请重新登录',
      403 => '您没有权限执行此操作',
      404 => '请求的接口不存在',
      405 => '请求方式不被允许',
      408 => '请求超时，请稍后重试',
      409 => '数据冲突，请刷新后重试',
      422 => '请求数据格式有误',
      429 => '操作过于频繁，请稍后再试',
      500 => '服务器内部错误，请稍后重试',
      502 => '网关错误，服务暂时不可用',
      503 => '服务器维护中，请稍后重试',
      504 => '网关响应超时，请稍后重试',
      _ => '网络异常（HTTP ${statusCode ?? '未知'}）',
    };
    return NetworkException(message, statusCode: statusCode);
  }

  Future<dynamic> get(
    String url, {
    Map<String, dynamic>? params,
    dio.Options? options,
    dio.CancelToken? cancelToken,
  }) {
    return _handleResponse(
      _dio.get<dynamic>(
        url,
        queryParameters: params,
        options: options,
        cancelToken: cancelToken,
      ),
    );
  }

  /// 请求第三方公开接口，不注入登录 Token，也不按本项目业务 code 解析。
  Future<dynamic> getExternal(
    String url, {
    Map<String, dynamic>? params,
    dio.Options? options,
    dio.CancelToken? cancelToken,
  }) {
    final dio.Options requestOptions = (options ?? dio.Options()).copyWith(
      extra: <String, dynamic>{
        ...?options?.extra,
        'skipAuthorization': true,
      },
    );
    return _handleRawResponse(
      _dio.get<dynamic>(
        url,
        queryParameters: params,
        options: requestOptions,
        cancelToken: cancelToken,
      ),
    );
  }

  Future<dynamic> post(
    String url, {
    Object? data,
    Map<String, dynamic>? params,
    dio.Options? options,
    dio.CancelToken? cancelToken,
  }) {
    return _handleResponse(
      _dio.post<dynamic>(
        url,
        data: data,
        queryParameters: params,
        options: options,
        cancelToken: cancelToken,
      ),
    );
  }

  Future<dynamic> put(
    String url, {
    Object? data,
    Map<String, dynamic>? params,
    dio.Options? options,
    dio.CancelToken? cancelToken,
  }) {
    return _handleResponse(
      _dio.put<dynamic>(
        url,
        data: data,
        queryParameters: params,
        options: options,
        cancelToken: cancelToken,
      ),
    );
  }

  Future<dynamic> delete(
    String url, {
    Object? data,
    Map<String, dynamic>? params,
    dio.Options? options,
    dio.CancelToken? cancelToken,
  }) {
    return _handleResponse(
      _dio.delete<dynamic>(
        url,
        data: data,
        queryParameters: params,
        options: options,
        cancelToken: cancelToken,
      ),
    );
  }

  Future<dynamic> upload(
    String url, {
    String? filePath,
    List<int>? fileBytes,
    String fileKey = 'file',
    String? fileName,
    Map<String, dynamic>? data,
    Map<String, dynamic>? params,
    dio.Options? options,
    dio.ProgressCallback? onSendProgress,
    dio.CancelToken? cancelToken,
  }) async {
    if ((filePath == null) == (fileBytes == null)) {
      throw ArgumentError(
        'filePath 和 fileBytes 必须且只能提供一个',
      );
    }
    final dio.MultipartFile file = fileBytes != null
        ? dio.MultipartFile.fromBytes(fileBytes, filename: fileName)
        : await dio.MultipartFile.fromFile(
            filePath!,
            filename: fileName,
          );
    final Map<String, dynamic> formData = <String, dynamic>{
      ...?data,
      fileKey: file,
    };

    return _handleResponse(
      _dio.post<dynamic>(
        url,
        data: dio.FormData.fromMap(formData),
        queryParameters: params,
        options: (options ?? dio.Options()).copyWith(
          contentType: dio.Headers.multipartFormDataContentType,
        ),
        onSendProgress: onSendProgress,
        cancelToken: cancelToken,
      ),
    );
  }

  /// 解析响应体，成功返回 data 字段，业务失败抛出 [BusinessException]。
  Future<dynamic> _handleResponse(
    Future<dio.Response<dynamic>> task,
  ) async {
    final dio.Response<dynamic> response;
    try {
      response = await task;
    } on dio.DioException catch (error, stackTrace) {
      final Object? appError = error.error;
      if (appError is NetworkException) {
        Error.throwWithStackTrace(appError, stackTrace);
      }
      rethrow;
    }

    final dynamic body = response.data;

    if (body is! Map<dynamic, dynamic>) {
      throw const BusinessException('服务器响应格式不正确');
    }

    final int? businessCode = _parseBusinessCode(body['code']);
    if (businessCode == GlobalVariable.successCode) {
      return body['data'];
    }

    final String message = body['message']?.toString() ?? '业务请求失败';

    throw BusinessException(message, code: businessCode);
  }

  Future<dynamic> _handleRawResponse(
    Future<dio.Response<dynamic>> task,
  ) async {
    try {
      final dio.Response<dynamic> response = await task;
      return response.data;
    } on dio.DioException catch (error, stackTrace) {
      final Object? appError = error.error;
      if (appError is NetworkException) {
        Error.throwWithStackTrace(appError, stackTrace);
      }
      rethrow;
    }
  }

  static int? _parseBusinessCode(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }
}

final RequestDio requestDio = RequestDio();
