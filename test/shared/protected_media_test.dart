import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MediaAdapter implements HttpClientAdapter {
  MediaAdapter(this.response);
  final Future<ResponseBody> Function() response;
  RequestOptions? request;
  final List<RequestOptions> requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancel) { request = options; requests.add(options); return response(); }
  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final url = Uri.parse(GlobalVariable.baseUrl).resolve('/media/${'a' * 64}').toString();
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.loadTokens();
    await tokenManager.setToken('private-image-test-token', refreshToken: 'private-image-refresh-token');
  });
  tearDown(tokenManager.deleteToken);

  test('private image uses authorization, no redirects, and no response logging', () async {
    final adapter = MediaAdapter(() async => ResponseBody.fromBytes(<int>[1,2,3], 200));
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    expect(await RequestDio(client: dio).getMedia(url), <int>[1,2,3]);
    expect(adapter.request!.headers['Authorization'], 'Bearer private-image-test-token');
    expect(adapter.request!.followRedirects, isFalse);
    expect(adapter.request!.extra['privateResponse'], isTrue);
  });

  test('401 refreshes credentials once and retries the private image', () async {
    var mediaRequests = 0;
    final adapter = MediaAdapter(() async {
      mediaRequests++;
      if (mediaRequests == 1) {
        return ResponseBody.fromString('{"code":401}', 401,
            headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
      }
      return ResponseBody.fromBytes(<int>[4, 5, 6], 200);
    });
    final refresh = MediaAdapter(() async => ResponseBody.fromString(
        '{"code":10000,"data":{"token":"refreshed-image-token","refreshToken":"next-image-refresh"}}', 200,
        headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]}));
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = RequestDio(client: dio, refreshDioFactory: () => Dio()..httpClientAdapter = refresh);

    expect(await client.getMedia(url), <int>[4, 5, 6]);
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.first.headers['Authorization'], 'Bearer private-image-test-token');
    expect(adapter.requests.last.headers['Authorization'], 'Bearer refreshed-image-token');
    expect(refresh.requests, hasLength(1));
  });

  test('getMedia does not cancel a caller-owned CancelToken on completion', () async {
    final adapter = MediaAdapter(() async => ResponseBody.fromBytes(<int>[1], 200));
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final cancelToken = CancelToken();
    await RequestDio(client: dio).getMedia(url, cancelToken: cancelToken);
    expect(cancelToken.isCancelled, isFalse);
  });

  test('external hosts, userinfo, query strings and non-media paths cannot receive the token', () async {
    final adapter = MediaAdapter(() async => ResponseBody.fromBytes(<int>[1], 200));
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = RequestDio(client: dio);
    for (final invalid in <String>[
      url.replaceFirst('127.0.0.1', 'attacker.invalid'), '$url?token=secret', '$url#fragment',
      Uri.parse(url).replace(userInfo: 'name:secret').toString(),
      Uri.parse(url).replace(path: '/userInfo').toString(),
    ]) {
      await expectLater(client.getMedia(invalid), throwsFormatException);
    }
    expect(adapter.request, isNull);
  });

  test('streamed images enforce their byte limit', () async {
    final adapter = MediaAdapter(() async => ResponseBody(Stream<Uint8List>.fromIterable(
        <Uint8List>[Uint8List(4), Uint8List(4)]), 200));
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    await expectLater(RequestDio(client: dio).getMedia(url, maxBytes: 7), throwsFormatException);
  });

  test('account switch discards private bytes from an earlier response', () async {
    final pending = Completer<ResponseBody>();
    final adapter = MediaAdapter(() => pending.future);
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final result = RequestDio(client: dio).getMedia(url);
    final assertion = expectLater(result, throwsA(isA<NetworkException>()));
    await Future<void>.delayed(Duration.zero);
    await tokenManager.setToken('another-account-token');
    pending.complete(ResponseBody.fromBytes(<int>[1,2,3], 200));
    await assertion;
  });

  test('logout prevents fetching even when an old private URL is still present', () async {
    final adapter = MediaAdapter(() async => ResponseBody.fromBytes(<int>[1], 200));
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    await tokenManager.deleteToken();
    await expectLater(RequestDio(client: dio).getMedia(url), throwsA(isA<NetworkException>()));
    expect(adapter.request, isNull);
  });
}
