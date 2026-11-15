import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart' as dio;

import '../constant/index.dart';
import 'app_exception.dart';
import 'client_identity.dart';
import 'emitter.dart';
import 'logger.dart';
import 'network_failure_stub.dart'
    if (dart.library.io) 'network_failure_io.dart';
import 'token_manager.dart';

typedef RefreshDioFactory = dio.Dio Function();

class _ReadCredentialsRefreshed extends SessionChangedException {
  const _ReadCredentialsRefreshed();
}

class _SessionExpired extends NetworkException {
  const _SessionExpired(this.clearedSessionId)
      : super('登录已失效，请重新登录', statusCode: 401);

  final int clearedSessionId;
}

const Set<int> _refreshCredentialRejectedStatuses = <int>{401, 403};

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

  static final RegExp _authorizationText =
      RegExp(r'\b(Bearer|Basic)\s+[a-zA-Z0-9._~+/=-]+', caseSensitive: false);
  static final RegExp _credentialAssignmentText = RegExp(
    r'''(["']?)([a-zA-Z][\w-]*)(\1\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;&}\]]+)''',
  );
  static final RegExp _jwtText =
      RegExp(r'\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b');
  static final RegExp _mobileText = RegExp(r'\b1[3-9]\d{9}\b');

  /// 仅为使用这份 Options 的请求开启诊断字段，不改变全局日志模式。
  /// 每侧最多 5 个字段，只读取第一层；敏感字段、嵌套值和长文字不输出。
  static dio.Options logDetails({
    List<String> requestLogFields = const <String>[],
    List<String> responseLogFields = const <String>[],
  }) {
    return dio.Options(extra: <String, dynamic>{
      'requestLogFields': List<String>.unmodifiable(requestLogFields.take(5)),
      'responseLogFields': List<String>.unmodifiable(responseLogFields.take(5)),
    });
  }

  RequestDio({
    dio.Dio? client,
    RefreshDioFactory? refreshDioFactory,
    TokenManager? tokens,
    ClientIdentity? identity,
  })  : _dio = client ?? dio.Dio(),
        _refreshDioFactory = refreshDioFactory ?? dio.Dio.new,
        _tokens = tokens ?? tokenManager,
        _identity = identity ?? ClientIdentity.current {
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
          if (!skipAuthorization) options.headers.addAll(_identity.headers);
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
          final int? requestSessionId =
              response.requestOptions.extra['sessionId'] as int?;
          if (response.requestOptions.extra['skipAuthorization'] != true &&
              requestSessionId != null &&
              requestSessionId != _tokens.sessionId) {
            const NetworkException appError = SessionChangedException();
            handler.reject(dio.DioException(
              requestOptions: response.requestOptions,
              response: response,
              error: appError,
              message: appError.message,
            ));
            return;
          }
          handler.next(response);
        },
        // 错误拦截器：将所有网络/HTTP 错误统一转换为 NetworkException，
        // 并附带对用户友好的中文提示。
        onError: (
          dio.DioException error,
          dio.ErrorInterceptorHandler handler,
        ) async {
          NetworkException? stoppedError;
          if (error.requestOptions.extra['skipAuthorization'] != true) {
            final int requestSessionVersion =
                error.requestOptions.extra['sessionVersion'] as int? ??
                    _tokens.sessionVersion;
            final int requestSessionId =
                error.requestOptions.extra['sessionId'] as int? ??
                    _tokens.sessionId;
            bool sessionChanged() =>
                _tokens.sessionId != requestSessionId ||
                _tokens.sessionVersion != requestSessionVersion;

            if (sessionChanged()) {
              stoppedError = const SessionChangedException();
            } else if (error.response?.statusCode == 401 &&
                error.requestOptions.extra['authRecoveryUsed'] != true &&
                !(error.requestOptions.cancelToken?.isCancelled ?? false)) {
              final String refreshToken = _tokens.getRefreshToken();
              var refreshSuccess = false;
              int? clearedSessionId;
              try {
                if (refreshToken.isEmpty) {
                  // 访问凭证已经被服务端明确拒绝，而本地没有可用于确认会话的
                  // 刷新凭证；此时继续保留访问凭证只会让后续请求反复 401。
                  clearedSessionId = await _clearSessionAndNotify();
                  stoppedError = clearedSessionId == null
                      ? const SessionChangedException()
                      : _SessionExpired(clearedSessionId);
                } else {
                  refreshSuccess = await _tryRefreshToken(
                    refreshToken,
                    sessionId: requestSessionId,
                    sessionVersion: requestSessionVersion,
                  );
                }
              } on NetworkException catch (upgrade) {
                stoppedError = sessionChanged()
                    ? const SessionChangedException()
                    : upgrade;
              }
              // 本次主动清理产生的会话变更保留失效提示，其他登录仍停止旧请求。
              if (sessionChanged() && _tokens.sessionId != clearedSessionId) {
                // Reads may recover once in get(); writes still stop here.
                stoppedError = const SessionChangedException();
              } else if (!refreshSuccess && stoppedError == null) {
                await _clearSessionAndNotify();
              }
            }
          }

          if (stoppedError is SessionChangedException &&
              error.response?.statusCode == 401 &&
              error.requestOptions.extra['sessionId'] == _tokens.sessionId &&
              _tokens.refreshSessionVersion == _tokens.sessionVersion &&
              _tokens.getToken().isNotEmpty) {
            stoppedError = const _ReadCredentialsRefreshed();
          }
          final NetworkException mapped = stoppedError ?? _mapDioError(error);
          final NetworkException appError = stoppedError != null
              ? mapped
              : NetworkException(
                  mapped.message,
                  statusCode: mapped.statusCode,
                  isTimeout: mapped.isTimeout,
                  isTemporary: mapped.isTemporary,
                  retryHandled: mapped.retryHandled,
                  requestId: _serverRequestId(error.response),
                );
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
  final ClientIdentity _identity;

  /// 凭证来源。构造时可替换，测试据此驱动「401 → 刷新 → 停止」这条链路，
  /// 不必去改全局单例。
  final TokenManager _tokens;
  Future<bool>? _refreshTokenFuture;
  int? _refreshSessionId;
  int? _refreshSessionVersion;

  static void _configureDio(dio.Dio client) {
    client.options
      ..baseUrl = GlobalVariable.baseUrl
      ..connectTimeout = GlobalVariable.networkTimeout
      ..receiveTimeout = GlobalVariable.networkTimeout
      ..sendTimeout = GlobalVariable.networkTimeout
      ..responseType = dio.ResponseType.json;
  }

  /// 只记录固定摘要，不遍历请求体或响应中的业务数据。
  static dio.InterceptorsWrapper _createLoggingInterceptor() {
    return dio.InterceptorsWrapper(
      onRequest: (
        dio.RequestOptions options,
        dio.RequestInterceptorHandler handler,
      ) {
        if (!Logger.enabled || options.extra['privateResponse'] == true) {
          handler.next(options);
          return;
        }
        Logger.network(
          '→ ${options.method} ${_getLogPath(options.path)}',
          _buildRequestLog(options),
        );
        handler.next(options);
      },
      onResponse: (
        dio.Response<dynamic> response,
        dio.ResponseInterceptorHandler handler,
      ) {
        if (!Logger.enabled ||
            response.requestOptions.extra['privateResponse'] == true) {
          handler.next(response);
          return;
        }
        final DateTime responseTime = DateTime.now();
        final DateTime requestTime =
            response.requestOptions.extra['request_time'] as DateTime? ??
                DateTime.now();
        final Duration requestDuration = responseTime.difference(requestTime);
        final int elapsedMilliseconds = requestDuration.inMilliseconds;
        Logger.network(
          '← ${response.statusCode} '
          '${_getLogPath(response.requestOptions.path)} (${elapsedMilliseconds}ms)',
          _buildResponseLog(response),
        );
        handler.next(response);
      },
      onError: (
        dio.DioException error,
        dio.ErrorInterceptorHandler handler,
      ) {
        if (!Logger.enabled ||
            error.requestOptions.extra['privateResponse'] == true) {
          handler.next(error);
          return;
        }
        final dio.Response<dynamic>? response = error.response;
        Logger.error(
          '✖ ${error.requestOptions.method} '
          '${_getLogPath(error.requestOptions.path)}',
          <String, dynamic>{
            // 区分「服务端返回了错误状态」与「压根没连上」：后者没有响应。
            'type': error.type.name,
            // 默认只记错误类型和状态；单次诊断只读取明确选定的字段。
            if (response != null) ..._buildResponseLog(response),
          },
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
      'path': _getLogPath(options.path),
    };
    // 有键值形式的请求正文就从正文取值，否则从查询参数取值。
    Map<dynamic, dynamic> requestDataForLog = options.queryParameters;
    if (options.data is Map<dynamic, dynamic>) {
      requestDataForLog = options.data;
    }
    _addLogFields(
      log,
      requestDataForLog,
      options.extra['requestLogFields'],
      'request',
    );
    return log;
  }

  /// 按指定名字直接取值，不扫描对象、不展开列表、不改变业务数据。
  static void _addLogFields(
    Map<String, dynamic> log,
    dynamic businessData,
    dynamic selectedLogFields,
    String logSide,
  ) {
    if (businessData is! Map<dynamic, dynamic> ||
        selectedLogFields is! List<dynamic>) {
      return;
    }
    for (final dynamic fieldName in selectedLogFields.take(5)) {
      if (fieldName is! String ||
          fieldName.length > 40 ||
          _isSensitiveLogKey(fieldName)) {
        continue;
      }
      if (!businessData.containsKey(fieldName)) continue;
      final String logKey = '$logSide.$fieldName';
      final dynamic fieldValue = businessData[fieldName];
      if (fieldValue is String) {
        // 整段省略过长文字，避免扫描大字符串或截断后露出半截凭证。
        if (fieldValue.length > 200) {
          log[logKey] = '<omitted: long value>';
        } else {
          log[logKey] = _redactLogText(fieldValue);
        }
      } else if (fieldValue == null ||
          fieldValue is num ||
          fieldValue is bool) {
        log[logKey] = fieldValue;
      }
    }
  }

  /// 路径最多检查 512 个字符，省略查询参数、片段和 URL 中的账号信息。
  static String _getLogPath(String requestPath) {
    if (requestPath.length > 512) return '<omitted: long path>';
    final Uri? uri = Uri.tryParse(requestPath);
    if (uri == null) return '<omitted: invalid path>';
    return _redactLogText(uri.path);
  }

  /// 隐藏短路径中能识别出的凭证和手机号，不改变实际请求。
  static String _redactLogText(String value) {
    final String safeAuthorization = value.replaceAllMapped(
      _authorizationText,
      (Match match) => '${match.group(1)} ***',
    );
    final String safeAssignments = safeAuthorization.replaceAllMapped(
      _credentialAssignmentText,
      (Match match) {
        if (!_isSensitiveLogKey(match.group(2)!)) {
          return match.group(0)!;
        }
        return '${match.group(1)}${match.group(2)}${match.group(3)}***';
      },
    );
    return safeAssignments
        .replaceAll(_jwtText, '***')
        .replaceAll(_mobileText, '***');
  }

  /// 判断路径文字里出现的字段名是否敏感。
  static bool _isSensitiveLogKey(String key) {
    final String normalized = key.toLowerCase().replaceAll(RegExp(r'[-_]'), '');
    if (_sensitiveLogKeys.contains(normalized)) return true;
    for (final String fragment in _sensitiveLogKeyFragments) {
      if (normalized.contains(fragment)) return true;
    }
    // 地图 Key：`key`、`appKey`、`apiKey`、`accessKey`。用后缀而非子串，
    // 位置页的 `keyword` 是搜索词，不该被脱敏。
    if (normalized.endsWith('key')) return true;
    return normalized == 'code' || normalized.endsWith('code');
  }

  /// 默认只取外层数字业务码；单次诊断可额外取指定字段，不展开 data。
  static Map<String, dynamic> _buildResponseLog(
      dio.Response<dynamic> response) {
    final Map<String, dynamic> log = <String, dynamic>{
      'status': response.statusCode,
      if (_serverRequestId(response) case final String id) 'requestId': id,
    };

    final dynamic body = response.data;
    if (body is Map<dynamic, dynamic>) {
      final dynamic businessCode = body['code'];
      if (businessCode is int) log['code'] = businessCode;
    }
    _addLogFields(
      log,
      body,
      response.requestOptions.extra['responseLogFields'],
      'response',
    );

    return log;
  }

  static String? _serverRequestId(dio.Response<dynamic>? response) {
    if (response == null ||
        response.requestOptions.extra['skipAuthorization'] == true) {
      return null;
    }
    final values = response.headers['x-request-id'];
    return values != null && values.length == 1
        ? validRequestId(values.single)
        : null;
  }

  Future<int?> _clearSessionAndNotify() async {
    // 被动登出（凭证已失效）不因为磁盘没删干净就把用户留在原地：先把内存
    // 凭证作废，界面必须退出登录态，磁盘残留留待下次登录覆盖。
    _tokens.invalidateLocalSession();
    final int logoutSessionId = _tokens.sessionId;
    try {
      await _tokens.deleteToken(expectedSessionId: logoutSessionId);
    } on Object {
      // 即使本地持久化清理失败，也必须通知界面退出当前登录态。
    }
    if (_tokens.sessionId == logoutSessionId + 1 &&
        _tokens.getToken().isEmpty) {
      eventBus.fire(const LogoutEvent());
      return logoutSessionId + 1;
    }
    return null;
  }

  Future<bool> _tryRefreshToken(
    String refreshToken, {
    required int sessionId,
    required int sessionVersion,
  }) {
    if (_refreshTokenFuture != null &&
        _refreshSessionId == sessionId &&
        _refreshSessionVersion == sessionVersion) {
      return _refreshTokenFuture!;
    }

    _refreshSessionId = sessionId;
    _refreshSessionVersion = sessionVersion;
    Future<bool>? refresh;
    refresh = _refreshTokenFuture = () async {
      dio.Dio? tokenDio;
      try {
        tokenDio = _refreshDioFactory();
        _configureDio(tokenDio);
        final dio.Response<dynamic> response = await tokenDio.post<dynamic>(
          HttpPath.refreshToken,
          options: dio.Options(
            headers: <String, dynamic>{
              ..._identity.headers,
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
                throw const NetworkException('刷新凭证响应不完整，请稍后重试');
              }
              if (_tokens.sessionId != sessionId ||
                  _tokens.sessionVersion != sessionVersion ||
                  _tokens.getRefreshToken() != refreshToken) {
                return false;
              }
              final bool saved = await _tokens.setRefreshedToken(
                newToken,
                refreshToken: newRefreshToken,
                expectedSessionId: sessionId,
                expectedSessionVersion: sessionVersion,
              );
              if (saved &&
                  _tokens.sessionId == sessionId &&
                  _tokens.sessionVersion == sessionVersion + 1 &&
                  _tokens.getToken() == newToken) {
                eventBus.fire(const RefreshEvent());
                return true;
              }
              throw const NetworkException('刷新凭证未能保存，请稍后重试');
            }
          }
        }
        throw const NetworkException('刷新凭证状态无法确认，请稍后重试');
      } on dio.DioException catch (error) {
        final int? statusCode = error.response?.statusCode;
        if (_refreshCredentialRejectedStatuses.contains(statusCode)) {
          return false;
        }
        final mapped = _mapDioError(error);
        throw NetworkException(mapped.message,
            statusCode: statusCode,
            isTimeout: mapped.isTimeout,
            isTemporary: mapped.isTemporary,
            requestId: _serverRequestId(error.response));
      } on NetworkException {
        rethrow;
      } on Object {
        throw const NetworkException('刷新失败，请检查网络后重试');
      } finally {
        tokenDio?.close(force: true);
        // 换会话后可以有新刷新；迟到的 finally 只清理自己的 Future。
        if (identical(_refreshTokenFuture, refresh)) {
          _refreshTokenFuture = null;
          _refreshSessionId = null;
          _refreshSessionVersion = null;
        }
      }
    }();

    return refresh;
  }

  /// 将 Dio 底层异常映射为 [NetworkException]，提供友好中文错误文案。
  static NetworkException _mapDioError(dio.DioException error) {
    switch (error.type) {
      case dio.DioExceptionType.connectionTimeout:
        return const NetworkException('连接服务器超时，请检查网络', isTimeout: true);
      case dio.DioExceptionType.sendTimeout:
        return const NetworkException('数据发送超时，请检查网络', isTimeout: true);
      case dio.DioExceptionType.receiveTimeout:
        return const NetworkException('数据接收超时，请检查网络', isTimeout: true);
      case dio.DioExceptionType.transformTimeout:
        return const NetworkException('响应数据解析超时，请稍后重试', isTimeout: true);
      case dio.DioExceptionType.connectionError:
        return NetworkException('网络连接失败，请检查网络设置',
            isTemporary: isTemporarySocketFailure(error.error));
      case dio.DioExceptionType.badCertificate:
        return const NetworkException('SSL 证书验证失败，连接不安全');
      case dio.DioExceptionType.cancel:
        return const NetworkException('请求已取消');
      case dio.DioExceptionType.badResponse:
        final Object? body = error.response?.data;
        if (error.response?.statusCode == 426 &&
            error.requestOptions.extra['skipAuthorization'] != true &&
            body is Map &&
            body['code'] == 42600) {
          final data = body['data'];
          final minimum = data is Map ? data['minimumVersion'] : null;
          if (minimum is String &&
              RegExp(r'^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$')
                  .hasMatch(minimum)) {
            return NetworkException(
                '当前客户端版本不受支持，请升级至 $minimum 或更高版本；请联系物业获取更新，本次操作未受理',
                statusCode: 426);
          }
        }
        if (error.response?.statusCode == 409 &&
            body is Map &&
            body.containsKey('code')) {
          final Object? message = body['message'];
          if (message is String && message.trim().isNotEmpty) {
            return NetworkException(message.trim(), statusCode: 409);
          }
        }
        return _mapHttpStatus(error.response?.statusCode);
      case dio.DioExceptionType.unknown:
        return const NetworkException('网络请求失败，请稍后重试');
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
      426 => '当前客户端版本不受支持，请升级应用后重试；请联系物业获取更新',
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
  }) async {
    // Only audited read routes. GET /code sends an SMS and is deliberately absent.
    final path = Uri.tryParse(url)?.path.replaceFirst(RegExp(r'^/'), '') ?? '';
    final safe = options?.extra?['safeRead'] != false &&
        RegExp(r'^(announcement(?:/[^/]+)?|userInfo|room(?:/[^/]+)?|repair(?:/.*)?|repairItem|visitor(?:/[^/]+)?|worker/(?:repairs(?:/[^/]+)?|repair-pool|skills)|notifications(?:/config)?)$')
            .hasMatch(path);
    final sessionId = _tokens.sessionId;
    var authRecoveryUsed = false;
    for (var attempt = 0;; attempt++) {
      if (_tokens.sessionId != sessionId) {
        throw const SessionChangedException();
      }
      if (cancelToken?.isCancelled ?? false) {
        throw const NetworkException('请求已取消', retryHandled: true);
      }
      final version = _tokens.sessionVersion;
      try {
        return await _handleResponse(_dio.get<dynamic>(url,
            queryParameters: params,
            options:
                (options ?? dio.Options()).copyWith(extra: <String, dynamic>{
              ...?options?.extra,
              'authRecoveryUsed': authRecoveryUsed,
            }),
            cancelToken: cancelToken));
      } on NetworkException catch (error) {
        if (error is _SessionExpired &&
            error.clearedSessionId == _tokens.sessionId) {
          rethrow;
        }
        if (_tokens.sessionId != sessionId) {
          throw const SessionChangedException();
        }
        if (cancelToken?.isCancelled ?? false) {
          throw const NetworkException('请求已取消', retryHandled: true);
        }
        final refreshed = _tokens.sessionVersion > version &&
            _tokens.refreshSessionVersion == _tokens.sessionVersion &&
            _tokens.getToken().isNotEmpty;
        if (safe &&
            attempt < 2 &&
            !authRecoveryUsed &&
            refreshed &&
            error is _ReadCredentialsRefreshed) {
          authRecoveryUsed = true;
          continue;
        }
        final transient = error.isTimeout ||
            error.isTemporary ||
            const <int>{502, 503, 504}.contains(error.statusCode);
        if (!safe || attempt >= 2 || !transient) {
          if (!safe || error is SessionChangedException) rethrow;
          throw NetworkException(error.message,
              statusCode: error.statusCode,
              isTimeout: error.isTimeout,
              isTemporary: error.isTemporary,
              requestId: error.requestId,
              retryHandled: true);
        }
        // Two extra attempts total, shared with auth recovery: 500ms then 1000ms.
        final delay =
            Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        if (cancelToken == null) {
          await delay;
        } else {
          await Future.any<dynamic>(
              <Future<dynamic>>[delay, cancelToken.whenCancel]);
        }
      }
    }
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

  /// Only this server's media endpoint may receive the application's token.
  static bool isServiceMedia(String value) {
    final base = Uri.tryParse(GlobalVariable.baseUrl);
    final uri = Uri.tryParse(value);
    return base != null &&
        uri != null &&
        uri.hasAuthority &&
        const <String>{'https', 'http'}.contains(uri.scheme) &&
        uri.scheme == base.scheme &&
        uri.host == base.host &&
        uri.port == base.port &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        RegExp(r'^/media/[a-f0-9]{64}$').hasMatch(uri.path);
  }

  /// Stream private images without disk caching, redirects or cross-account reuse.
  Future<Uint8List> getMedia(String url,
      {int maxBytes = 20 * 1024 * 1024, dio.CancelToken? cancelToken}) async {
    if (!isServiceMedia(url)) throw const FormatException('图片地址不属于当前服务');
    if (_tokens.getToken().isEmpty) {
      throw const NetworkException('请先登录', statusCode: 401);
    }
    final session = _tokens.sessionId;
    final bool ownsCancelToken = cancelToken == null;
    final cancel = cancelToken ?? dio.CancelToken();
    var authRecoveryUsed = false;
    void sessionChanged() {
      if (_tokens.sessionId != session && ownsCancelToken) {
        cancel.cancel('session changed');
      }
    }

    _tokens.sessionChanges.addListener(sessionChanged);
    try {
      dynamic body;
      while (true) {
        try {
          body = await _handleRawResponse(_dio.get<dynamic>(url,
              options: dio.Options(
                  responseType: dio.ResponseType.stream,
                  followRedirects: false,
                  extra: <String, dynamic>{
                    'privateResponse': true,
                    'authRecoveryUsed': authRecoveryUsed,
                  }),
              cancelToken: cancel));
          break;
        } on NetworkException catch (error) {
          final bool refreshed =
              _tokens.refreshSessionVersion == _tokens.sessionVersion &&
                  _tokens.getToken().isNotEmpty;
          if (!authRecoveryUsed &&
              _tokens.sessionId == session &&
              refreshed &&
              error is _ReadCredentialsRefreshed) {
            authRecoveryUsed = true;
            continue;
          }
          rethrow;
        }
      }
      if (body is! dio.ResponseBody) throw const FormatException('图片响应无效');
      final builder = BytesBuilder(copy: false);
      await for (final chunk
          in body.stream.timeout(GlobalVariable.networkTimeout)) {
        if (_tokens.sessionId != session) throw const SessionChangedException();
        if (builder.length + chunk.length > maxBytes) {
          throw const FormatException('图片超过允许的大小');
        }
        builder.add(chunk);
      }
      if (_tokens.sessionId != session) throw const SessionChangedException();
      if (builder.isEmpty) throw const FormatException('图片为空');
      return builder.takeBytes();
    } on TimeoutException {
      throw const NetworkException('图片接收超时，请稍后重试', isTimeout: true);
    } finally {
      _tokens.sessionChanges.removeListener(sessionChanged);
      if (ownsCancelToken) cancel.cancel();
    }
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
      throw BusinessException('服务器响应格式不正确',
          requestId: _serverRequestId(response));
    }

    final int? businessCode = _parseBusinessCode(body['code']);
    if (businessCode == GlobalVariable.successCode) {
      return body['data'];
    }

    final String message = body['message']?.toString() ?? '业务请求失败';

    throw BusinessException(message,
        code: businessCode,
        data: body['data'],
        requestId: _serverRequestId(response));
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
