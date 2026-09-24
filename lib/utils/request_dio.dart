import 'package:dio/dio.dart' as dio;

import '../constant/index.dart';
import 'app_exception.dart';
import 'emitter.dart';
import 'logger.dart';
import 'token_manager.dart';

typedef RefreshDioFactory = dio.Dio Function();

class RequestDio {
  /// 键名命中即整体脱敏的固定列表（比较前会去掉 `-`、`_` 并转小写）。
  static const Set<String> _sensitiveLogKeys = <String>{
    'authorization',
    'key',
    'mobile',
    'password',
    'phone',
    'secret',
    'telephone',
    'token',
  };

  /// 命中即脱敏的子串。地图 Key 各家 SDK 习惯写成 `appKey`、`apiKey`、
  /// `accessKey`，逐个子串列举必然漏，所以改由「以 key 结尾」兜住（见
  /// [_isSensitiveLogKey]）；这里只保留词根。
  static const Set<String> _sensitiveLogKeyFragments = <String>{
    'token',
    'password',
    'secret',
  };

  RequestDio({
    dio.Dio? client,
    RefreshDioFactory? refreshDioFactory,
    TokenManager? tokens,
  })  : _dio = client ?? dio.Dio(),
        _refreshDioFactory = refreshDioFactory ?? dio.Dio.new,
        _tokens = tokens ?? tokenManager {
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
          options.extra['sessionVersion'] = _tokens.sessionVersion;
          options.extra['sessionId'] = _tokens.sessionId;
          final String token = _tokens.getToken();
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

          if (error.response?.statusCode == 401 &&
              !isRetry &&
              error.requestOptions.extra['skipAuthorization'] != true) {
            final String refreshToken = _tokens.getRefreshToken();
            final int sessionVersion = _tokens.sessionVersion;
            final int requestSessionVersion =
                error.requestOptions.extra['sessionVersion'] as int? ??
                    sessionVersion;
            final int requestSessionId =
                error.requestOptions.extra['sessionId'] as int? ??
                    _tokens.sessionId;
            final String failedToken =
                error.requestOptions.headers['Authorization']?.toString() ?? '';
            final String currentToken = _tokens.getToken();
            final bool tokenChanged = failedToken.isNotEmpty &&
                currentToken.isNotEmpty &&
                failedToken != 'Bearer $currentToken';
            bool shouldLogout = refreshToken.isEmpty;

            if (tokenChanged) {
              // 三个条件缺一不可：
              //
              // 1. 同一个会话。会话 ID 只在登录/登出时变，刷新不动它。这一条
              //    挡住跨账号重放——A 的请求在 B 登录并刷新之后，版本号是
              //    「推进过」的，只比对版本会让它带着 B 的凭证重放出去。
              // 2. 凭证确实换过代。用「不等于原值」而不是「恰好 +1」：并发
              //    的刷新失败重试会把版本推进不止一次，+1 会把本该放行的常规
              //    重放挡掉，让偶发的 401 直接冒到用户面前。
              // 3. 这次推进来自刷新，而不是别的写入。
              if (_tokens.sessionId == requestSessionId &&
                  _tokens.sessionVersion != requestSessionVersion &&
                  _tokens.refreshSessionVersion == _tokens.sessionVersion) {
                // 请求在飞行途中凭证已经被换掉（多半是并发的刷新已经完成），
                // 用当前凭证直接重放即可，不必再刷一次。
                try {
                  final dio.Response<dynamic> retryResponse = await _dio.fetch(
                    _createRetryRequest(
                      error.requestOptions,
                      token: currentToken,
                    ),
                  );
                  return handler.resolve(retryResponse);
                } on dio.DioException catch (e) {
                  error = e;
                  shouldLogout = e.response?.statusCode == 401 &&
                      _tokens.sessionVersion == sessionVersion;
                }
              }
            } else if (refreshToken.isNotEmpty) {
              final bool refreshSuccess = await _tryRefreshToken(
                refreshToken,
                sessionVersion: sessionVersion,
              );
              // 只有刷新确实成功、且期间没有再次变更凭证时才重放。
              // 用「不等于原版本」而不是「恰好 +1」：并发的刷新失败重试可能
              // 再推进一次，那属于凭证又换了，但这种情况下 +1 判断会把本该
              // 放行的常规重放也挡掉。
              final String refreshedToken = _tokens.getToken();
              if (refreshSuccess &&
                  refreshedToken.isNotEmpty &&
                  _tokens.sessionVersion != sessionVersion) {
                try {
                  final dio.Response<dynamic> retryResponse = await _dio.fetch(
                    _createRetryRequest(
                      error.requestOptions,
                      token: refreshedToken,
                    ),
                  );
                  return handler.resolve(retryResponse);
                } on dio.DioException catch (e) {
                  error = e;
                  shouldLogout = e.response?.statusCode == 401 &&
                      _tokens.sessionVersion != sessionVersion;
                }
              } else {
                shouldLogout = _tokens.sessionVersion == sessionVersion &&
                    _tokens.getRefreshToken() == refreshToken;
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

  /// 凭证来源。构造时可替换，测试据此驱动「401 → 刷新 → 重放」这条链路，
  /// 不必去改全局单例。
  final TokenManager _tokens;
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
        if (options.extra['privateResponse'] == true) {
          handler.next(options);
          return;
        }
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
        if (response.requestOptions.extra['privateResponse'] == true) {
          handler.next(response);
          return;
        }
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
        if (error.requestOptions.extra['privateResponse'] == true) {
          handler.next(error);
          return;
        }
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
      log['params'] = _redactLogValue(
        options.queryParameters,
        requestSide: true,
      );
    }

    if (options.headers.isNotEmpty) {
      log['headers'] = _redactLogValue(options.headers, requestSide: true);
    }

    if (options.data != null && options.data is! dio.FormData) {
      log['body'] = _redactLogValue(options.data, requestSide: true);
    }

    return log;
  }

  /// 把 URL 里敏感查询参数的值换成 `***`。
  ///
  /// 只在该 URL 确实含敏感参数时才重建，其余情况原样返回：`Uri.replace` 会
  /// 对全部参数重新编码，把 `%2F`、`+`、重复键这些原样交出去更省事，也避免
  /// 日志里出现与真实请求不一致的编码。
  static Uri _redactUri(Uri uri) {
    if (uri.queryParameters.isEmpty) return uri;
    final bool hasSensitive = uri.queryParameters.keys.any(
      (String key) => _isSensitiveLogKey(key, requestSide: true),
    );
    if (!hasSensitive) return uri;

    // 逐段处理原始 query，而不是走 queryParameters 映射：映射会把重复键合并，
    // 也会让所有值经过一次 encode，`***` 就变成 `%2A%2A%2A` 了。
    final String query = uri.query
        .split('&')
        .map((String segment) {
          final int separator = segment.indexOf('=');
          if (separator < 0) return segment;
          final String rawKey = segment.substring(0, separator);
          final String decodedKey = Uri.decodeQueryComponent(rawKey);
          return _isSensitiveLogKey(decodedKey, requestSide: true)
              ? '$rawKey=***'
              : segment;
        })
        .join('&');
    return uri.replace(query: query);
  }

  /// 递归遍历要写进日志的值，把敏感键换成 `***`。
  ///
  /// [depth] 是从根值开始的嵌套层数。响应体最外层那一层是接口信封
  /// （`{"code": 10000, "data": {...}}`），它的 `code` 是业务状态码；嵌进
  /// `data` 之后的 `code` 才是验证码之类的秘密。所以只按 `requestSide` 分是
  /// 不够的，还得看层级——否则要么把业务码一起遮掉（排查失败码时无从下手），
  /// 要么把验证码原样打进日志。
  static dynamic _redactLogValue(
    dynamic value, {
    required bool requestSide,
    int depth = 0,
    String? key,
  }) {
    if (key != null &&
        _isSensitiveLogKey(key, requestSide: requestSide, depth: depth)) {
      return '***';
    }
    if (value is Map<dynamic, dynamic>) {
      return <String, dynamic>{
        for (final MapEntry<dynamic, dynamic> entry in value.entries)
          entry.key.toString(): _redactLogValue(
            entry.value,
            requestSide: requestSide,
            depth: depth + 1,
            key: entry.key.toString(),
          ),
      };
    }
    if (value is Iterable<dynamic>) {
      return <dynamic>[
        for (final dynamic item in value)
          _redactLogValue(
            item,
            requestSide: requestSide,
            depth: depth + 1,
          ),
      ];
    }
    return value;
  }

  /// 判断键名是否敏感。
  ///
  /// [requestSide] 与 [depth] 共同决定 `code` 系列是否计入：请求体里的 `code`
  /// 是验证码，响应信封顶层的 `code` 是业务状态码（保留），而响应体里嵌进
  /// `data` 的 `code` 又是验证码（脱敏）。
  static bool _isSensitiveLogKey(
    String key, {
    required bool requestSide,
    int depth = 0,
  }) {
    final String normalized =
        key.toLowerCase().replaceAll(RegExp(r'[-_]'), '');
    if (_sensitiveLogKeys.contains(normalized)) return true;
    for (final String fragment in _sensitiveLogKeyFragments) {
      if (normalized.contains(fragment)) return true;
    }
    // 地图 Key：`key`、`appKey`、`apiKey`、`accessKey`。用后缀而非子串，
    // 位置页的 `keyword` 是搜索词，不该被脱敏。
    if (normalized.endsWith('key')) return true;
    // 验证码：请求侧一律脱敏；响应侧只脱敏嵌在信封里面的那一层。
    //
    // 根值本身以 depth 0 进入，它的直接子键因此是 depth 1——那正是响应信封
    // （`{"code":..., "data":...}`）那一层，`code` 在那里是业务状态码，要留。
    // 再往里（`data.code`、`data.verificationCode`）才是验证码，depth ≥ 2。
    final bool isCodeLike =
        normalized == 'code' || normalized.endsWith('code');
    if (isCodeLike && (requestSide || depth > 1)) return true;
    return false;
  }

  /// 构建响应日志内容。
  static Map<String, dynamic> _buildResponseLog(
      dio.Response<dynamic> response) {
    final Map<String, dynamic> log = <String, dynamic>{
      'status': response.statusCode,
    };

    if (response.data != null) {
      // 限制响应体日志长度，避免过大的数据污染日志
      final dynamic safeData = _redactLogValue(
        response.data,
        requestSide: false,
      );
      final String dataStr = safeData.toString();
      // ignore: require_trailing_commas
      log['body'] = dataStr.length > 500
          ? '${dataStr.substring(0, 500)}... (truncated)'
          : safeData;
    }

    return log;
  }

  /// 用在 [token] 下的凭证重建一次请求。
  ///
  /// [token] 由调用处显式传入，重放不自己去读全局凭证：重放的前提是「凭证
  /// 确实已经更新」，而调用处正好知道这一点。若这里隐式读取，刷新失败却仍
  /// 走到重放分支时，就会把当前 token（可能是刚换上的另一个账号的）套到旧
  /// 请求体上重发。
  dio.RequestOptions _createRetryRequest(
    dio.RequestOptions requestOptions, {
    required String token,
  }) {
    final dynamic requestData = requestOptions.data;
    final dynamic retryData =
        requestData is dio.FormData ? requestData.clone() : requestData;
    return requestOptions.copyWith(
      data: retryData,
      headers: <String, dynamic>{
        ...requestOptions.headers,
        'Authorization': 'Bearer $token',
      },
      extra: <String, dynamic>{
        ...requestOptions.extra,
        'isRetry': true,
      },
    );
  }

  Future<void> _clearSessionAndNotify() async {
    // 被动登出（凭证已失效）不因为磁盘没删干净就把用户留在原地：先把内存
    // 凭证作废，界面必须退出登录态，磁盘残留留待下次登录覆盖。
    _tokens.invalidateLocalSession();
    try {
      await _tokens.deleteToken();
    } on Object {
      // 即使本地持久化清理失败，也必须通知界面退出当前登录态。
    }
    eventBus.fire(const LogoutEvent());
  }

  Future<bool> _tryRefreshToken(
    String refreshToken, {
    required int sessionVersion,
  }) {
    if (_refreshTokenFuture != null) {
      return _refreshTokenFuture!;
    }

    Future<bool>? refresh;
    refresh = _refreshTokenFuture = () async {
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
              if (newToken.isEmpty ||
                  newRefreshToken.isEmpty ||
                  _tokens.sessionVersion != sessionVersion ||
                  _tokens.getRefreshToken() != refreshToken) {
                return false;
              }
              final bool saved = await _tokens.setRefreshedToken(
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
        // 只清掉自己的那次。finally 在返回值送达调用方之前执行，直接置空会
        // 留下一个窗口：已经在 await 这次刷新的调用方还没醒，新来的 401 却
        // 看到「当前没有刷新在进行」，于是并发发起第二次刷新。
        if (identical(_refreshTokenFuture, refresh)) {
          _refreshTokenFuture = null;
        }
      }
    }();

    return refresh;
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
