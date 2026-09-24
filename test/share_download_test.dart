import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/platform/visitor_pass_share.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/emitter.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ImageAdapter implements HttpClientAdapter {
  ImageAdapter(this.response);
  final ResponseBody Function() response;
  RequestOptions? request;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    request = options;
    return response();
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();
    await tokenManager.setToken('test-only-token',
        refreshToken: 'test-only-refresh');
  });

  test('image download keeps bytes and excludes auth and redirects', () async {
    final Uint8List bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII=');
    final ImageAdapter adapter =
        ImageAdapter(() => ResponseBody.fromBytes(bytes, 200));
    final Dio dio = Dio()..httpClientAdapter = adapter;
    final RequestDio client = RequestDio(client: dio);
    expect(
        await loadVisitorPassImage('https://example.invalid/pass.png',
            client: client),
        bytes);
    expect(adapter.request!.headers.containsKey('Authorization'), isFalse);
    expect(adapter.request!.followRedirects, isFalse);
    expect(adapter.request!.extra['privateResponse'], isTrue);
    dio.close();
  });

  test('external image 401 never refreshes or clears the app login', () async {
    int refreshes = 0;
    int logouts = 0;
    final StreamSubscription<LogoutEvent> events =
        eventBus.on<LogoutEvent>().listen((_) {
      logouts++;
    });
    final Dio dio = Dio()
      ..httpClientAdapter =
          ImageAdapter(() => ResponseBody.fromBytes(<int>[], 401));
    final RequestDio client = RequestDio(
        client: dio,
        refreshDioFactory: () {
          refreshes++;
          throw StateError('must not refresh');
        });
    await expectLater(
        loadVisitorPassImage('https://example.invalid/private.png',
            client: client),
        throwsA(isA<NetworkException>()));
    await Future<void>.delayed(Duration.zero);
    expect(refreshes, 0);
    expect(logouts, 0);
    expect(tokenManager.getToken(), 'test-only-token');
    await events.cancel();
    dio.close();
  });

  test('rejects bad URL and oversized streamed image', () async {
    await expectLater(
        loadVisitorPassImage('file:///private/file'), throwsFormatException);
    final Dio dio = Dio()
      ..httpClientAdapter = ImageAdapter(() => ResponseBody(
          Stream<Uint8List>.fromIterable(<Uint8List>[
            Uint8List(maxVisitorPassBytes),
            Uint8List(1),
          ]),
          200));
    await expectLater(
        loadVisitorPassImage('https://example.invalid/big.png',
            client: RequestDio(client: dio)),
        throwsFormatException);
    dio.close();
  });
}
