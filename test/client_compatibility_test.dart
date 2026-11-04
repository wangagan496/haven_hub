import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/client_identity.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/toast.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/utils/token_storage.dart';

import 'helpers/widget_harness.dart';

const receipt = 'd63b531e-fbb5-44b5-893e-46c5203a3b2e';
const identity = ClientIdentity(version: '1.0.0', platform: 'ohos');
const upgradeMessage = '当前客户端版本不受支持，请升级至 1.2.0 或更高版本；请联系物业获取更新，本次操作未受理';

class _Storage implements TokenStorage {
  @override String token = 'old';
  @override String refreshToken = 'refresh';
  @override Future<void> load() async {}
  @override Future<bool> write(String value, String refresh) async { token = value; refreshToken = refresh; return true; }
  @override void invalidate() { token = ''; refreshToken = ''; }
  @override Future<bool> clear() async { invalidate(); return true; }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  int calls = 0;
  @override Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream, Future<void>? cancel) async {
    calls++;
    return respond(options);
  }
  @override void close({bool force = false}) {}
}

ResponseBody _response({int status = 426, Object? minimum = '1.2.0', int code = 42600, Object? data}) => ResponseBody.fromString(
    jsonEncode(<String, dynamic>{'code': code, 'message': 'untrusted text', 'data': data ?? <String, dynamic>{'minimumVersion': minimum}}),
    status, headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType], 'x-request-id': <String>[receipt]});

RequestDio _client(_Adapter adapter, TokenManager tokens, {_Adapter? refresh}) {
  final dio = Dio()..httpClientAdapter = adapter;
  addTearDown(dio.close);
  return RequestDio(client: dio, tokens: tokens, identity: identity,
      refreshDioFactory: refresh == null ? null : () => Dio()..httpClientAdapter = refresh);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('client reports compile-time release and actual runtime platform', () {
    expect(ClientIdentity.current.version, const String.fromEnvironment('HAVEN_CLIENT_VERSION'));
    expect(ClientIdentity.current.platform, 'android');
    expect(identity.headers, <String, String>{'X-Client-Version': '1.0.0', 'X-Client-Platform': 'ohos'});
  });

  test('service calls include identity; external calls exclude it and credentials', () async {
    final adapter = _Adapter((options) {
      if (options.path.startsWith('https://example.test')) {
        expect(options.headers['X-Client-Version'], isNull);
        expect(options.headers['X-Client-Platform'], isNull);
        expect(options.headers['Authorization'], isNull);
      } else {
        expect(options.headers['X-Client-Version'], '1.0.0');
        expect(options.headers['X-Client-Platform'], 'ohos');
      }
      return _response(status: 200, code: 10000, data: 'ok');
    });
    final client = _client(adapter, TokenManager(storage: _Storage()));
    expect(await client.get('announcement'), 'ok');
    expect(await client.post('room'), 'ok');
    await client.getExternal('https://example.test/map');
    expect(adapter.calls, 3);
  });

  test('upgrade rejection preserves session and receipt, never retries reads or writes', () async {
    for (final method in <String>['get', 'sms', 'post', 'put', 'delete']) {
      final tokens = TokenManager(storage: _Storage());
      final adapter = _Adapter((_) => _response());
      final refresh = _Adapter((_) => throw StateError('must not refresh'));
      final client = _client(adapter, tokens, refresh: refresh);
      final request = switch (method) {
        'get' => client.get('repair'),
        'sms' => client.get('code'),
        'post' => client.post('repair'),
        'put' => client.put('repair'),
        _ => client.delete('room/1'),
      };
      await expectLater(request, throwsA(isA<NetworkException>()
          .having((e) => e.statusCode, 'status', 426)
          .having((e) => e.message, 'message', upgradeMessage)
          .having((e) => e.requestId, 'receipt', receipt)));
      expect(adapter.calls, 1);
      expect(refresh.calls, 0);
      expect(tokens.getToken(), 'old');
      expect(tokens.getRefreshToken(), 'refresh');
    }
  });

  test('malformed upgrade payload never shows server text or fabricated minimum', () async {
    for (final minimum in <Object?>[null, '01.2.0', '1.2', '1.2.0-beta', '<script>', 120, '9999999.0.0']) {
      final adapter = _Adapter((_) => _response(minimum: minimum));
      final client = _client(adapter, TokenManager(storage: _Storage()));
      await expectLater(client.post('room'), throwsA(isA<NetworkException>()
          .having((e) => e.message, 'message', '当前客户端版本不受支持，请升级应用后重试；请联系物业获取更新')));
      expect(adapter.calls, 1);
    }
  });

  test('refresh includes identity and upgrade failure does not log out or replay', () async {
    for (final write in <bool>[false, true]) {
      final tokens = TokenManager(storage: _Storage());
      final adapter = _Adapter((_) => _response(status: 401));
      final refresh = _Adapter((options) {
        expect(options.headers['X-Client-Version'], '1.0.0');
        expect(options.headers['X-Client-Platform'], 'ohos');
        expect(options.headers['Authorization'], 'Bearer refresh');
        return _response();
      });
      final client = _client(adapter, tokens, refresh: refresh);
      await expectLater(write ? client.post('room') : client.get('repair'), throwsA(isA<NetworkException>()
          .having((e) => e.statusCode, 'status', 426)
          .having((e) => e.message, 'message', upgradeMessage)
          .having((e) => e.requestId, 'receipt', receipt)));
      expect(adapter.calls, 1);
      expect(refresh.calls, 1);
      expect(tokens.getToken(), 'old');
      expect(tokens.getRefreshToken(), 'refresh');
    }
  });

  test('successful refresh retains normal recovery and sends identity on every attempt', () async {
    final tokens = TokenManager(storage: _Storage());
    var calls = 0;
    final adapter = _Adapter((options) {
      expect(options.headers['X-Client-Version'], '1.0.0');
      return ++calls == 1 ? _response(status: 401) : _response(status: 200, code: 10000, data: 'ok');
    });
    final refresh = _Adapter((options) {
      expect(options.headers['X-Client-Version'], '1.0.0');
      return _response(status: 200, code: 10000, data: <String, dynamic>{'token': 'new', 'refreshToken': 'next'});
    });
    expect(await _client(adapter, tokens, refresh: refresh).get('repair'), 'ok');
    expect(tokens.getToken(), 'new');
    expect(adapter.calls, 2);
    expect(refresh.calls, 1);
  });

  test('account change while upgrade response is pending discards old-session result', () async {
    for (final duringRefresh in <bool>[false, true]) {
      final tokens = TokenManager(storage: _Storage());
      final entered = Completer<void>();
      final result = Completer<ResponseBody>();
      Future<ResponseBody> pending(RequestOptions _) { entered.complete(); return result.future; }
      final adapter = _Adapter(duringRefresh ? (_) => _response(status: 401) : pending);
      final refresh = duringRefresh ? _Adapter(pending) : null;
      final client = _client(adapter, tokens, refresh: refresh);
      final assertion = expectLater(client.get('repair'), throwsA(isA<SessionChangedException>()));
      await entered.future;
      await tokens.setToken('other', refreshToken: 'other-refresh');
      result.complete(_response());
      await assertion;
      expect(tokens.getToken(), 'other');
      expect(adapter.calls, 1);
    }
  });

  test('concurrent obsolete requests share refresh and preserve session', () async {
    final tokens = TokenManager(storage: _Storage());
    final release = Completer<ResponseBody>();
    final entered = Completer<void>();
    final adapter = _Adapter((_) => _response(status: 401));
    final refresh = _Adapter((_) { entered.complete(); return release.future; });
    final client = _client(adapter, tokens, refresh: refresh);
    final requests = <Future<void>>[
      expectLater(client.get('repair'), throwsA(isA<NetworkException>().having((e) => e.statusCode, 'status', 426))),
      expectLater(client.get('room'), throwsA(isA<NetworkException>().having((e) => e.statusCode, 'status', 426))),
    ];
    await entered.future;
    await Future<void>.delayed(Duration.zero);
    release.complete(_response());
    await Future.wait(requests);
    expect(refresh.calls, 1);
    expect(adapter.calls, 2);
    expect(tokens.getToken(), 'old');
  });

  testWidgets('existing prompt displays actionable upgrade message and copyable receipt', (tester) async {
    await pumpPage(tester, const Scaffold());
    await AppPrompt.showException(const NetworkException(upgradeMessage, statusCode: 426, requestId: receipt), fallback: '失败');
    await tester.pump();
    expect(find.text(upgradeMessage), findsOneWidget);
    expect(find.text('复制排查编号'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 11));
    await finishPage(tester);
  });
}
