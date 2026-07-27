import 'package:dio/dio.dart';

import '../constant/index.dart';

class RequestDio {
  RequestDio({Dio? dio}) : _dio = dio ?? Dio() {
    // 配置请求基地址和超时时间，使用级联（链式）调用。
    _dio.options
      ..baseUrl = GlobalVariable.baseUrl
      ..connectTimeout = GlobalVariable.networkTimeout
      ..receiveTimeout = GlobalVariable.networkTimeout
      ..sendTimeout = GlobalVariable.networkTimeout
      ..responseType = ResponseType.json;

    _dio.interceptors.add(
      InterceptorsWrapper(
        // 请求拦截器：后续可以在 handler.next 前统一注入 Token。
        onRequest: (
          RequestOptions options,
          RequestInterceptorHandler handler,
        ) {
          handler.next(options);
        },
        // 响应拦截器：只有 HTTP 2xx 状态码才作为成功响应继续传递。
        onResponse: (
          Response<dynamic> response,
          ResponseInterceptorHandler handler,
        ) {
          final int statusCode = response.statusCode ?? 0;
          if (statusCode >= 200 && statusCode < 300) {
            handler.next(response);
            return;
          }

          handler.reject(
            DioException(
              requestOptions: response.requestOptions,
              response: response,
              message: 'HTTP 状态码异常：$statusCode',
            ),
          );
        },
        // 错误拦截器：将网络错误继续交给调用方处理。
        onError: (
          DioException error,
          ErrorInterceptorHandler handler,
        ) {
          handler.reject(error);
        },
      ),
    );
  }

  final Dio _dio;

  Future<dynamic> get(
    String url, {
    Map<String, dynamic>? params,
    Options? options,
    CancelToken? cancelToken,
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

  Future<dynamic> post(
    String url, {
    Object? data,
    Map<String, dynamic>? params,
    Options? options,
    CancelToken? cancelToken,
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
    Options? options,
    CancelToken? cancelToken,
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
    Options? options,
    CancelToken? cancelToken,
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

  Future<Response<dynamic>> upload(
    String url, {
    required String filePath,
    String fileKey = 'file',
    String? fileName,
    Map<String, dynamic>? data,
    Map<String, dynamic>? params,
    ProgressCallback? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    final Map<String, dynamic> formData = <String, dynamic>{
      ...?data,
      fileKey: await MultipartFile.fromFile(
        filePath,
        filename: fileName,
      ),
    };

    return _dio.post<dynamic>(
      url,
      data: FormData.fromMap(formData),
      queryParameters: params,
      options: Options(contentType: Headers.multipartFormDataContentType),
      onSendProgress: onSendProgress,
      cancelToken: cancelToken,
    );
  }

  Future<dynamic> _handleResponse(
    Future<Response<dynamic>> task,
  ) async {
    final Response<dynamic> response = await task;
    final dynamic body = response.data;

    if (body is Map<String, dynamic> &&
        body['code'] == GlobalVariable.successCode) {
      return body['data'];
    }

    final String message = body is Map<String, dynamic>
        ? body['message']?.toString() ?? '业务请求失败'
        : '服务器响应格式不正确';
    throw DioException(
      requestOptions: response.requestOptions,
      response: response,
      message: message,
    );
  }
}

final RequestDio requestDio = RequestDio();
