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
  final List<String> methods = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    methods.add(options.method);
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

  bool failWrites = false;

  @override
  Future<void> load() async {}

  @override
  Future<bool> write(String token, String refreshToken) async {
    if (failWrites) return false;
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

class _LoginReplacingTokenManager extends TokenManager {
  _LoginReplacingTokenManager({required super.storage});

  @override
  Future<bool> deleteToken({int? expectedSessionId}) async {
    final bool cleared =
        await super.deleteToken(expectedSessionId: expectedSessionId);
    // 保证新登录在清理调用返回前完成，避免依赖事件监听器的调度时序。
    await setToken('replacement-token', refreshToken: 'replacement-refresh');
    return cleared;
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

  test('refresh keeps login and automatically restores the safe read once',
      () async {
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

    expect(await client.get('userInfo'), <String, dynamic>{'ok': true});
    expect(business.paths.length, 2, reason: '安全读取恢复一次');
    expect(business.authorizationHeaders.first, 'Bearer old-token');
    expect(tokens.getToken(), 'new-token');
    expect(tokens.getRefreshToken(), 'new-refresh');
    expect(business.authorizationHeaders.last, 'Bearer new-token');
    expect(refresh.paths, hasLength(1));

    dio.close();
  });

  test(
      'explicitly rejected refresh logs out without replaying under the old request',
      () async {
    final _RecordingAdapter business =
        _RecordingAdapter(<ResponseBody Function()>[
      () => _json(<String, dynamic>{'code': 401}, status: 401),
    ]);
    final _RecordingAdapter refresh =
        _RecordingAdapter(<ResponseBody Function()>[
      () => _json(<String, dynamic>{'code': 401}, status: 401),
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

  test(
      'missing refresh credential logs out after a 401 without calling refresh',
      () async {
    storage = _FakeTokenStorage(token: 'access-only');
    tokens = TokenManager(storage: storage);
    final business = _RecordingAdapter(<ResponseBody Function()>[
      () => _json(<String, dynamic>{'code': 401}, status: 401),
    ]);
    final refresh = _RecordingAdapter(<ResponseBody Function()>[
      () => _json(<String, dynamic>{
            'code': 10000,
            'data': <String, dynamic>{
              'token': 'should-not-be-used',
              'refreshToken': 'should-not-be-used',
            }
          }),
    ]);
    final Dio dio = Dio()..httpClientAdapter = business;
    final RequestDio client = RequestDio(
      client: dio,
      refreshDioFactory: () => Dio()..httpClientAdapter = refresh,
      tokens: tokens,
    );
    final Future<LogoutEvent> logout = eventBus.on<LogoutEvent>().first;

    await expectLater(
      client.get('userInfo'),
      throwsA(isA<NetworkException>()
          .having((error) => error.message, 'message', '登录已失效，请重新登录')
          .having((error) => error.statusCode, 'statusCode', 401)),
    );
    await expectLater(
      logout.timeout(const Duration(seconds: 1)),
      completes,
    );
    expect(tokens.getToken(), isEmpty);
    expect(tokens.getRefreshToken(), isEmpty);
    expect(refresh.paths, isEmpty);
    expect(business.paths, hasLength(1));
    dio.close();
  });

  test('missing refresh credential preserves a replacement login during logout',
      () async {
    storage = _FakeTokenStorage(token: 'access-only');
    tokens = _LoginReplacingTokenManager(storage: storage);
    final business = _RecordingAdapter(<ResponseBody Function()>[
      () => _json(<String, dynamic>{'code': 401}, status: 401),
    ]);
    final Dio dio = Dio()..httpClientAdapter = business;
    addTearDown(() => dio.close(force: true));
    var refreshCalls = 0;
    final RequestDio client = RequestDio(
      client: dio,
      tokens: tokens,
      refreshDioFactory: () {
        refreshCalls++;
        return Dio();
      },
    );
    var logouts = 0;
    final subscription = eventBus.on<LogoutEvent>().listen((_) => logouts++);
    addTearDown(subscription.cancel);

    await expectLater(
        client.get('userInfo'), throwsA(isA<SessionChangedException>()));
    await Future<void>.delayed(Duration.zero);
    expect(tokens.getToken(), 'replacement-token');
    expect(tokens.getRefreshToken(), 'replacement-refresh');
    expect(business.paths, hasLength(1));
    expect(refreshCalls, 0);
    expect(logouts, 0);
  });

  for (final int status in <int>[429, 503]) {
    test('refresh HTTP $status preserves the current login', () async {
      final _RecordingAdapter business =
          _RecordingAdapter(<ResponseBody Function()>[
        () => _json(<String, dynamic>{'code': 401}, status: 401),
      ]);
      final _RecordingAdapter refresh =
          _RecordingAdapter(<ResponseBody Function()>[
        () => _json(<String, dynamic>{'code': status}, status: status),
      ]);
      final Dio dio = Dio()..httpClientAdapter = business;
      final RequestDio client = RequestDio(
        client: dio,
        refreshDioFactory: () => Dio()..httpClientAdapter = refresh,
        tokens: tokens,
      );
      var loggedOut = false;
      final subscription =
          eventBus.on<LogoutEvent>().listen((_) => loggedOut = true);
      try {
        await expectLater(
            client.get('userInfo'), throwsA(isA<NetworkException>()));
        final int requestCount = status == 503 ? 3 : 1;
        expect(business.paths, hasLength(requestCount));
        expect(refresh.paths, hasLength(requestCount));
        expect(tokens.getToken(), 'old-token');
        expect(tokens.getRefreshToken(), 'old-refresh');
        expect(loggedOut, isFalse);
      } finally {
        await subscription.cancel();
        dio.close();
      }
    });
  }

  for (final String failure in [
    'malformed',
    'persistence',
    'timeout',
    'offline'
  ]) {
    test('refresh $failure failure preserves the current login', () async {
      final business = _RecordingAdapter([
        () => _json(<String, dynamic>{'code': 401}, status: 401),
      ]);
      final refresh = _RecordingAdapter([
        () {
          if (failure == 'timeout' || failure == 'offline') {
            throw DioException(
                requestOptions: RequestOptions(path: 'refreshToken'),
                type: failure == 'timeout'
                    ? DioExceptionType.receiveTimeout
                    : DioExceptionType.connectionError);
          }
          return _json(<String, dynamic>{
            'code': 10000,
            'data': <String, dynamic>{
              'token': 'new-token',
              if (failure != 'malformed') 'refreshToken': 'new-refresh',
            }
          });
        },
      ]);
      storage.failWrites = failure == 'persistence';
      final dio = Dio()..httpClientAdapter = business;
      final client = RequestDio(
          client: dio,
          tokens: tokens,
          refreshDioFactory: () => Dio()..httpClientAdapter = refresh);
      var loggedOut = false;
      final subscription =
          eventBus.on<LogoutEvent>().listen((_) => loggedOut = true);
      try {
        await expectLater(
            client.get('userInfo'), throwsA(isA<NetworkException>()));
        expect(tokens.getToken(), 'old-token');
        expect(tokens.getRefreshToken(), 'old-refresh');
        expect(loggedOut, isFalse);
      } finally {
        await subscription.cancel();
        dio.close();
      }
    });
  }

  test(
      'a request whose token was already refreshed recovers without another refresh',
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

    expect(await client.get('userInfo'), <String, dynamic>{'ok': true});
    expect(business.paths, hasLength(2));
    expect(business.authorizationHeaders.first, 'Bearer old-token');
    // 凭证已经是新的了，不该再刷一次。
    expect(refresh.paths, isEmpty);
    expect(tokens.getToken(), 'new-token');

    dio.close();
  });

  // 同一会话更新一次或多次凭证，都应停止旧请求。
  test('same account can recover with the latest concurrently refreshed token',
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
          // 两次并发刷新先后落盘：版本推进两次，最后一次仍来自刷新。
          await tokens.setRefreshedToken(
            'first-new-token',
            refreshToken: 'first-new-refresh',
          );
          await tokens.setRefreshedToken(
            'second-new-token',
            refreshToken: 'second-new-refresh',
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

    expect(await client.get('userInfo'), <String, dynamic>{'ok': true});
    expect(business.paths, hasLength(2));
    expect(business.authorizationHeaders.first, 'Bearer old-token');
    // 凭证已经是最新的了，不该再刷一次。
    expect(refresh.paths, isEmpty);
    expect(tokens.getToken(), 'second-new-token');

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

  // 换号之后再刷新一次，是最容易漏掉的组合：只比对版本号的话，这次刷新让
  // 版本「相对旧请求推进过」了，于是旧账号的请求会带着新账号的凭证重放出去。
  // 会话 ID 必须在登录时就变，刷新不能把它带回来。
  test('does not replay a stale request when the new account then refreshes',
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
          await tokens.deleteToken();
          await tokens.setToken(
            'account-b-token',
            refreshToken: 'account-b-refresh',
          );
          // B 随后自己刷新了一次。
          await tokens.setRefreshedToken(
            'account-b-refreshed',
            refreshToken: 'account-b-refreshed-refresh',
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

    expect(business.paths.length, 1, reason: 'A 的旧请求不能带着 B 的凭证重放');
    expect(business.authorizationHeaders, <String?>['Bearer old-token']);
    expect(refresh.paths, isEmpty);

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

  for (final String method in <String>['POST', 'PUT', 'DELETE']) {
    test('$method is sent once even when token refresh succeeds', () async {
      final _RecordingAdapter business = _RecordingAdapter(
        <ResponseBody Function()>[
          () => _json(<String, dynamic>{'code': 401}, status: 401),
        ],
      );
      final _RecordingAdapter refresh = _RecordingAdapter(
        <ResponseBody Function()>[
          () => _json(<String, dynamic>{
                'code': 10000,
                'data': <String, dynamic>{
                  'token': 'new-token',
                  'refreshToken': 'new-refresh'
                },
              }),
        ],
      );
      final Dio dio = Dio()..httpClientAdapter = business;
      addTearDown(() => dio.close(force: true));
      final RequestDio client = RequestDio(
        client: dio,
        tokens: tokens,
        refreshDioFactory: () => Dio()..httpClientAdapter = refresh,
      );
      final Future<dynamic> request = switch (method) {
        'POST' =>
          client.post('repair', data: <String, String>{'description': 'test'}),
        'PUT' => client.put('repair/1'),
        _ => client.delete('repair/1'),
      };
      await expectLater(request, throwsA(isA<NetworkException>()));
      expect(business.methods, <String>[method]);
      expect(refresh.paths, hasLength(1));
      expect(tokens.getToken(), 'new-token');
    });
  }

  test(
      'concurrent 401 shares one refresh, only GET recovers and a second 401 stops',
      () async {
    final Completer<void> refreshing = Completer<void>();
    final Completer<void> releaseRefresh = Completer<void>();
    final _RecordingAdapter business = _RecordingAdapter(
      <ResponseBody Function()>[
        () => _json(<String, dynamic>{'code': 401}, status: 401),
      ],
    );
    final _RecordingAdapter refresh = _RecordingAdapter(
      <ResponseBody Function()>[
        () => _json(<String, dynamic>{
              'code': 10000,
              'data': <String, dynamic>{
                'token': 'new-token',
                'refreshToken': 'new-refresh'
              },
            }),
      ],
      onFetch: (_) async {
        if (!refreshing.isCompleted) refreshing.complete();
        await releaseRefresh.future;
      },
    );
    final Dio dio = Dio()..httpClientAdapter = business;
    addTearDown(() => dio.close(force: true));
    final RequestDio client = RequestDio(
      client: dio,
      tokens: tokens,
      refreshDioFactory: () => Dio()..httpClientAdapter = refresh,
    );
    final Future<void> first =
        expectLater(client.get('repair'), throwsA(isA<NetworkException>()));
    final Future<void> second =
        expectLater(client.post('repair'), throwsA(isA<NetworkException>()));
    await refreshing.future;
    releaseRefresh.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(business.methods, <String>['GET', 'POST', 'GET']);
    expect(refresh.paths, hasLength(1));
    expect(tokens.getToken(), 'new-token');
  });

  test('a late failed refresh cannot log out the new account', () async {
    int logouts = 0;
    final StreamSubscription<LogoutEvent> subscription =
        eventBus.on<LogoutEvent>().listen((_) => logouts++);
    addTearDown(subscription.cancel);
    final _RecordingAdapter business = _RecordingAdapter(
      <ResponseBody Function()>[
        () => _json(<String, dynamic>{'code': 401}, status: 401)
      ],
    );
    final _RecordingAdapter refresh = _RecordingAdapter(
      <ResponseBody Function()>[
        () => _json(<String, dynamic>{'code': 500}, status: 500)
      ],
      onFetch: (_) =>
          tokens.setToken('account-b-token', refreshToken: 'account-b-refresh'),
    );
    final Dio dio = Dio()..httpClientAdapter = business;
    addTearDown(() => dio.close(force: true));
    final RequestDio client = RequestDio(
      client: dio,
      tokens: tokens,
      refreshDioFactory: () => Dio()..httpClientAdapter = refresh,
    );
    await expectLater(client.get('repair'), throwsA(isA<NetworkException>()));
    await Future<void>.delayed(Duration.zero);
    expect(tokens.getToken(), 'account-b-token');
    expect(logouts, 0);
    expect(business.paths, hasLength(1));
  });

  test('session replacement stops old 401 even if token text is unchanged',
      () async {
    final _RecordingAdapter business = _RecordingAdapter(
      <ResponseBody Function()>[
        () => _json(<String, dynamic>{'code': 401}, status: 401)
      ],
      onFetch: (_) => tokens.setToken('old-token', refreshToken: 'old-refresh'),
    );
    final _RecordingAdapter refresh = _RecordingAdapter(
      <ResponseBody Function()>[
        () => _json(<String, dynamic>{'code': 500}, status: 500)
      ],
    );
    final Dio dio = Dio()..httpClientAdapter = business;
    addTearDown(() => dio.close(force: true));
    final RequestDio client = RequestDio(
      client: dio,
      tokens: tokens,
      refreshDioFactory: () => Dio()..httpClientAdapter = refresh,
    );
    await expectLater(client.get('repair'), throwsA(isA<NetworkException>()));
    expect(refresh.paths, isEmpty);
    expect(tokens.getToken(), 'old-token');
  });

  test('late successful response from the previous account is not published',
      () async {
    final _RecordingAdapter business = _RecordingAdapter(
      <ResponseBody Function()>[
        () => _json(<String, dynamic>{'code': 10000, 'data': 'account-a-data'}),
      ],
      onFetch: (_) => tokens.setToken('account-b', refreshToken: 'refresh-b'),
    );
    final Dio dio = Dio()..httpClientAdapter = business;
    addTearDown(() => dio.close(force: true));
    final RequestDio client = RequestDio(client: dio, tokens: tokens);
    await expectLater(
        client.get('repair'), throwsA(isA<SessionChangedException>()));
    expect(tokens.getToken(), 'account-b');
    expect(business.paths, hasLength(1));
  });

  test('public external fetch remains independent of account changes',
      () async {
    final _RecordingAdapter business = _RecordingAdapter(
      <ResponseBody Function()>[
        () => _json(<String, dynamic>{'public': true})
      ],
      onFetch: (_) => tokens.setToken('account-b', refreshToken: 'refresh-b'),
    );
    final Dio dio = Dio()..httpClientAdapter = business;
    addTearDown(() => dio.close(force: true));
    final RequestDio client = RequestDio(client: dio, tokens: tokens);
    expect(await client.getExternal('https://example.com/public'),
        <String, dynamic>{'public': true});
    expect(business.authorizationHeaders, <String?>[null]);
  });

  test('new account refresh does not wait for the old account refresh',
      () async {
    final Completer<void> oldRefreshStarted = Completer<void>();
    final Completer<void> releaseOldRefresh = Completer<void>();
    final _RecordingAdapter business = _RecordingAdapter(
      <ResponseBody Function()>[
        () => _json(<String, dynamic>{'code': 401}, status: 401),
      ],
    );
    final _RecordingAdapter oldRefresh = _RecordingAdapter(
      <ResponseBody Function()>[
        () => _json(<String, dynamic>{
              'code': 10000,
              'data': <String, dynamic>{
                'token': 'refreshed-a',
                'refreshToken': 'refreshed-ra',
              }
            }),
      ],
      onFetch: (_) async {
        oldRefreshStarted.complete();
        await releaseOldRefresh.future;
      },
    );
    final _RecordingAdapter newRefresh = _RecordingAdapter(
      <ResponseBody Function()>[
        () => _json(<String, dynamic>{
              'code': 10000,
              'data': <String, dynamic>{
                'token': 'refreshed-b',
                'refreshToken': 'refreshed-rb',
              }
            }),
      ],
    );
    int refreshClients = 0;
    final Dio dio = Dio()..httpClientAdapter = business;
    addTearDown(() => dio.close(force: true));
    final RequestDio client = RequestDio(
        client: dio,
        tokens: tokens,
        refreshDioFactory: () => Dio()
          ..httpClientAdapter =
              refreshClients++ == 0 ? oldRefresh : newRefresh);
    final Future<void> oldRequest = expectLater(
        client.get('repair-a'), throwsA(isA<SessionChangedException>()));
    await oldRefreshStarted.future;
    await tokens.setToken('account-b', refreshToken: 'refresh-b');
    await expectLater(
        client.get('repair-b'), throwsA(isA<SessionChangedException>()));
    expect(refreshClients, 2);
    expect(tokens.getToken(), 'refreshed-b');
    releaseOldRefresh.complete();
    await oldRequest;
    expect(tokens.getToken(), 'refreshed-b');
    expect(tokens.getRefreshToken(), 'refreshed-rb');
    expect(business.paths, <String>['repair-a', 'repair-b']);
  });
}
