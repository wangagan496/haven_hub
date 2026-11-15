import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/retry_strategy.dart';
import 'package:haven_hub/utils/token_manager.dart';

import '../helpers/http_adapter.dart';
import '../helpers/memory_token_storage.dart';

ResponseBody response({int status = 200, int code = 10000, Object? data = 'ok'}) => ResponseBody.fromString(
  jsonEncode({'code': code, 'data': data, 'message': '拒绝'}), status,
  headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('timeouts retry twice with spacing and cannot multiply in a page retry wrapper', () async {
    final times = <DateTime>[];
    final adapter = CallbackHttpAdapter((options, _) {
      times.add(DateTime.now());
      throw DioException(requestOptions: options, type: DioExceptionType.receiveTimeout);
    });
    final tokens = TokenManager(storage: MemoryTokenStorage(token: 'old', refreshToken: 'refresh'));
    final client = RequestDio(client: Dio()..httpClientAdapter = adapter, tokens: tokens);
    await expectLater(retryAsync(action: () => client.get('repair'), tokens: tokens),
      throwsA(isA<NetworkException>().having((e) => e.retryHandled, 'budget handled', true)));
    expect(adapter.calls, 3);
    expect(times[1].difference(times[0]).inMilliseconds, greaterThanOrEqualTo(450));
    expect(times[2].difference(times[1]).inMilliseconds, greaterThanOrEqualTo(950));
  });
  test('transient connection reset recovers; explicitly unreachable network does not retry', () async {
    for (final code in [104, 101]) {
      final adapter = CallbackHttpAdapter((options, call) {
        if (call == 1) {
          throw DioException(requestOptions: options, type: DioExceptionType.connectionError,
            error: SocketException('fixture', osError: OSError('fixture', code)));
        }
        return response();
      });
      final client = RequestDio(client: Dio()..httpClientAdapter = adapter, tokens: TokenManager(storage: MemoryTokenStorage(token: 'old', refreshToken: 'refresh')));
      if (code == 104) { expect(await client.get('announcement'), 'ok'); expect(adapter.calls, 2); }
      else { await expectLater(client.get('announcement'), throwsA(isA<NetworkException>())); expect(adapter.calls, 1); }
    }
  });
  test('auth recovery and weak network use one shared budget; auth cannot loop', () async {
    final refresh = CallbackHttpAdapter((_, __) => response(data: {'token': 'new', 'refreshToken': 'new-refresh'}));
    final adapter = CallbackHttpAdapter((_, call) => response(status: call == 1 ? 401 : 503));
    final client = RequestDio(client: Dio()..httpClientAdapter = adapter, tokens: TokenManager(storage: MemoryTokenStorage(token: 'old', refreshToken: 'refresh')),
      refreshDioFactory: () => Dio()..httpClientAdapter = refresh);
    await expectLater(client.get('repair'), throwsA(isA<NetworkException>()));
    expect(adapter.calls, 3); expect(refresh.calls, 1);
  });
  test('cancel, logout and account switch during backoff prevent any next request', () async {
    for (final mode in ['cancel', 'logout', 'switch']) {
      final tokens = TokenManager(storage: MemoryTokenStorage(token: 'old', refreshToken: 'refresh'));
      final cancel = CancelToken();
      final entered = Completer<void>();
      final adapter = CallbackHttpAdapter((_, __) { entered.complete(); return response(status: 503); });
      final client = RequestDio(client: Dio()..httpClientAdapter = adapter, tokens: tokens);
      final check = expectLater(client.get('repair', cancelToken: cancel), throwsA(isA<NetworkException>()));
      await entered.future;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (mode == 'cancel') { cancel.cancel(); }
      else if (mode == 'logout') { await tokens.deleteToken(); }
      else { await tokens.setToken('other'); }
      await check; expect(adapter.calls, 1);
    }
  });
  test('SMS GET, writes, permission and business rejection are never retried', () async {
    for (final mode in ['sms', 'post', 'permission', 'business']) {
      final adapter = CallbackHttpAdapter((_, __) => response(status: mode == 'permission' ? 403 : mode == 'business' ? 200 : 503, code: 40001));
      final client = RequestDio(client: Dio()..httpClientAdapter = adapter, tokens: TokenManager(storage: MemoryTokenStorage(token: 'old', refreshToken: 'refresh')));
      await expectLater(mode == 'post' ? client.post('repair') : client.get(mode == 'sms' ? 'code' : 'repair'), throwsException);
      expect(adapter.calls, 1);
    }
  });
  test('skill preview conflicts preserve latest data and never retry the old confirmation', () async {
    final latest = <String, dynamic>{'previewToken': 'latest-token', 'returned': <dynamic>[],
      'property': <dynamic>[], 'changed': <dynamic>[<String, dynamic>{'status': 5}]};
    final adapter = CallbackHttpAdapter((options, _) {
      expect((options.data as Map)['previewToken'], 'old-token');
      return response(code: 40901, data: latest);
    });
    final client = RequestDio(client: Dio()..httpClientAdapter = adapter,
      tokens: TokenManager(storage: MemoryTokenStorage(token: 'old', refreshToken: 'refresh')));
    await expectLater(client.put('worker/skills', data: <String, dynamic>{'previewToken': 'old-token'}),
      throwsA(isA<BusinessException>().having((error) => error.code, 'code', 40901)
        .having((error) => error.data, 'latest impact', latest)));
    expect(adapter.calls, 1);
  });
}
