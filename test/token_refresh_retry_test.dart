import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/emitter.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/utils/token_storage.dart';

/// 记录每次请求的凭证，并按顺序返回预设响应。
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.responses, {this.onFetch});

  /// 依次弹出的响应；用尽后重复最后一个。
  final List<ResponseBody Function()> responses;

  /// 每次请求返回前调用，拿到的是从 0 开始的请求序号。
  ///
  /// 用来在「请求已经发出去、响应还没回来」的窗口里改动外部状态——比如凭证
  /// 被并发的刷新换掉。靠请求头是造不出这个状态的：请求拦截器会用当时的凭证
  /// 覆盖调用方传进来的 Authorization。
  final FutureOr<void> Function(int index)? onFetch;

  final List<String?> authorizationHeaders = <String?>[];
  final List<String> paths = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    authorizationHeaders.add(options.headers['Authorization']?.toString());
    final int index = paths.length - 1;
    await onFetch?.call(index);
    final ResponseBody Function() response =
        responses[index.clamp(0, responses.length - 1)];
    return response();
  }

  @override
  void close({bool force = false}) {}
}

class _FakeTokenStorage implements TokenStorage {
  _FakeTokenStorage({this.token = '', this.refreshToken = ''});

  @override
  String token;

  @override
  String refreshToken;

  @override
  Future<void> load() async {}

  @override
  Future<bool> write(String token, String refreshToken) async {
    this.token = token;
    this.refreshToken = refreshToken;
    return true;
  }

  @override
  Future<bool> clear() async {
    token = '';
    refreshToken = '';
    return true;
  }

  @override
  void invalidate() {
    token = '';
    refreshToken = '';
  }
}

ResponseBody _json(Map<String, dynamic> body, {int status = 200}) {
  return ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeTokenStorage storage;
  late TokenManager tokens;

  setUp(() {
    storage = _FakeTokenStorage(
      token: 'old-token',
      refreshToken: 'old-refresh',
    );
    tokens = TokenManager(storage: storage);
  });

  test('replay after refresh carries the refreshed token', () async {
    final _RecordingAdapter business =
        _RecordingAdapter(<ResponseBody Function()>[
      () => _json(<String, dynamic>{'code': 401}, status: 401),
      () => _json(<String, dynamic>{
            'code': 10000,
            'data': <String, dynamic>{'ok': true}
          }),
    ]);
    final _RecordingAdapter refresh =
        _RecordingAdapter(<ResponseBody Function()>[
      () => _json(<String, dynamic>{
            'code': 10000,
            'data': <String, dynamic>{
              'token': 'new-token',
              'refreshToken': 'new-refresh',
            },
          }),
    ]);

    final Dio dio = Dio()..httpClientAdapter = business;
    final RequestDio client = RequestDio(
      client: dio,
      refreshDioFactory: () => Dio()..httpClientAdapter = refresh,
      tokens: tokens,
    );

    final dynamic data = await client.get('userInfo');

    expect(data, <String, dynamic>{'ok': true});
    expect(business.paths.length, 2, reason: '首次 401 后应重放一次');
    expect(business.authorizationHeaders.first, 'Bearer old-token');
    // 关键：重放带的是刷新后的凭证，不是重放时才去读的旧值。
    expect(business.authorizationHeaders.last, 'Bearer new-token');
    expect(tokens.getToken(), 'new-token');

    dio.close();
  });

  test('failed refresh logs out without replaying under the old request',
      () async {
    final _RecordingAdapter business =
        _RecordingAdapter(<ResponseBody Function()>[
      () => _json(<String, dynamic>{'code': 401}, status: 401),
    ]);
    final _RecordingAdapter refresh =
        _RecordingAdapter(<ResponseBody Function()>[
      () => _json(<String, dynamic>{'code': 500}, status: 500),
    ]);

    final Dio dio = Dio()..httpClientAdapter = business;
    final RequestDio client = RequestDio(
      client: dio,
      refreshDioFactory: () => Dio()..httpClientAdapter = refresh,
      tokens: tokens,
    );

    final Future<LogoutEvent> logout = eventBus.on<LogoutEvent>().first;
    await expectLater(client.get('userInfo'), throwsA(isA<NetworkException>()));

    // 刷新失败时不能拿当前凭证把业务请求重发一遍。
    expect(business.paths.length, 1, reason: '刷新失败不应重放');
    await logout;
    expect(tokens.getToken(), isEmpty);

    dio.close();
  });

  test('a request whose token was already replaced replays without refreshing',
      () async {
    final _RecordingAdapter business = _RecordingAdapter(
      <ResponseBody Function()>[
        () => _json(<String, dynamic>{'code': 401}, status: 401),
        () => _json(<String, dynamic>{
              'code': 10000,
              'data': <String, dynamic>{'ok': true},
            }),
      ],
      // 请求带着 old-token 飞出去，返回 401 之前并发的刷新已经换上了新凭证。
      onFetch: (int index) async {
        if (index == 0) {
          await tokens.setRefreshedToken(
            'new-token',
            refreshToken: 'new-refresh',
          );
        }
      },
    );
    final _RecordingAdapter refresh =
        _RecordingAdapter(<ResponseBody Function()>[
      () =>
          _json(<String, dynamic>{'code': 10000, 'data': <String, dynamic>{}}),
    ]);

    final Dio dio = Dio()..httpClientAdapter = business;
    final RequestDio client = RequestDio(
      client: dio,
      refreshDioFactory: () => Dio()..httpClientAdapter = refresh,
      tokens: tokens,
    );

    final dynamic data = await client.get('userInfo');

    expect(data, <String, dynamic>{'ok': true});
    expect(business.authorizationHeaders.first, 'Bearer old-token');
    // 凭证已经是新的了，不该再刷一次。
    expect(refresh.paths, isEmpty);
    expect(business.authorizationHeaders.last, 'Bearer new-token');

    dio.close();
  });

  test('does not replay a stale request after switching accounts', () async {
    final _RecordingAdapter business = _RecordingAdapter(
      <ResponseBody Function()>[
        () => _json(<String, dynamic>{'code': 401}, status: 401),
        () => _json(<String, dynamic>{
              'code': 10000,
              'data': <String, dynamic>{'ok': true},
            }),
      ],
      onFetch: (int index) async {
        if (index == 0) {
          await tokens.deleteToken();
          await tokens.setToken(
            'new-account-token',
            refreshToken: 'new-account-refresh',
          );
        }
      },
    );
    final _RecordingAdapter refresh =
        _RecordingAdapter(<ResponseBody Function()>[
      () =>
          _json(<String, dynamic>{'code': 10000, 'data': <String, dynamic>{}}),
    ]);

    final Dio dio = Dio()..httpClientAdapter = business;
    final RequestDio client = RequestDio(
      client: dio,
      refreshDioFactory: () => Dio()..httpClientAdapter = refresh,
      tokens: tokens,
    );

    await expectLater(client.get('userInfo'), throwsA(isA<NetworkException>()));

    expect(business.paths.length, 1, reason: '换号后旧请求不能在新账号下重放');
    expect(refresh.paths, isEmpty);
    expect(tokens.getToken(), 'new-account-token');

    dio.close();
  });

  test('does not replay a stale request after a direct login replacement',
      () async {
    final _RecordingAdapter business = _RecordingAdapter(
      <ResponseBody Function()>[
        () => _json(<String, dynamic>{'code': 401}, status: 401),
        () => _json(<String, dynamic>{
              'code': 10000,
              'data': <String, dynamic>{'ok': true},
            }),
      ],
      onFetch: (int index) async {
        if (index == 0) {
          await tokens.setToken(
            'new-login-token',
            refreshToken: 'new-login-refresh',
          );
        }
      },
    );
    final _RecordingAdapter refresh =
        _RecordingAdapter(<ResponseBody Function()>[
      () =>
          _json(<String, dynamic>{'code': 10000, 'data': <String, dynamic>{}}),
    ]);

    final Dio dio = Dio()..httpClientAdapter = business;
    final RequestDio client = RequestDio(
      client: dio,
      refreshDioFactory: () => Dio()..httpClientAdapter = refresh,
      tokens: tokens,
    );

    await expectLater(client.get('userInfo'), throwsA(isA<NetworkException>()));

    expect(business.paths.length, 1, reason: '新登录产生的凭证不能重放旧账号请求');
    expect(refresh.paths, isEmpty);
    expect(tokens.getToken(), 'new-login-token');

    dio.close();
  });
}
