import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/retry_strategy.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final DioExceptionType type in <DioExceptionType>[
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.transformTimeout,
  ]) {
    test('$type recovers in the request layer without another page retry', () async {
      int calls = 0;
      final Dio client = Dio();
      addTearDown(() => client.close(force: true));
      client.interceptors.add(InterceptorsWrapper(
        onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
          calls++;
          if (calls == 1) {
            handler.reject(
                DioException(requestOptions: options, type: type), true);
          } else {
            handler.resolve(Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, Object>{'code': 10000, 'data': 'recovered'},
            ));
          }
        },
      ));
      final RequestDio request = RequestDio(client: client);
      final List<Object> retryErrors = <Object>[];
      final dynamic result = await retryAsync<dynamic>(
        action: () => request.get('repair'),
        onRetry: (_, Object error) => retryErrors.add(error),
      );
      expect(result, 'recovered');
      expect(calls, 2);
      expect(retryErrors, isEmpty);
    });
  }

  test('retry classification uses network metadata rather than message text',
      () {
    for (final int status in <int>[502, 503, 504]) {
      expect(
          NetworkException('Temporary failure', statusCode: status).isRetryable,
          isTrue);
    }
    for (final Object error in <Object>[
      const BusinessException('timeout', code: 503),
      const FormatException('invalid value 502'),
      const NetworkException('timeout', statusCode: 403),
      const NetworkException('No connection'),
      const NetworkException('Request cancelled'),
      StateError('timeout'),
    ]) {
      expect(error.isRetryable, isFalse, reason: '$error');
    }
  });

  test('inactive caller does not schedule another attempt on late failure',
      () async {
    int calls = 0;
    bool active = true;
    const NetworkException failure =
        NetworkException('Temporary failure', statusCode: 503);
    await expectLater(
      retryAsync<void>(
        action: () async {
          calls++;
          active = false;
          throw failure;
        },
        shouldRetry: () => active,
      ),
      throwsA(same(failure)),
    );
    expect(calls, 1);
  });

  for (final bool refresh in <bool>[true, false]) {
    test('credential change during backoff stops retries (refresh=$refresh)',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final TokenManager tokens = TokenManager();
      await tokens.setToken('old-token', refreshToken: 'old-refresh');
      int calls = 0;
      final Future<void> stopped = expectLater(
        retryAsync<void>(
          tokens: tokens,
          action: () async {
            calls++;
            throw const NetworkException('Temporary failure', statusCode: 503);
          },
        ),
        throwsA(isA<SessionChangedException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (refresh) {
        await tokens.setRefreshedToken('new-token',
            refreshToken: 'new-refresh');
      } else {
        tokens.invalidateLocalSession();
      }
      await stopped;
      expect(calls, 1);
    });
  }

  test('session change in retry callback cannot dispatch the next attempt',
      () async {
    final TokenManager tokens = TokenManager();
    int calls = 0;
    await expectLater(
      retryAsync<void>(
        tokens: tokens,
        action: () async {
          calls++;
          throw const NetworkException('Temporary failure', isTimeout: true);
        },
        onRetry: (_, __) => tokens.invalidateLocalSession(),
      ),
      throwsA(isA<SessionChangedException>()),
    );
    expect(calls, 1);
  });
}
