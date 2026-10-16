import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/l10n/app_localizations.dart';
import 'package:haven_hub/models/notice_data.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/home/index.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/emitter.dart';
import 'package:haven_hub/utils/repair_list_preloader.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/utils/token_storage.dart';

import 'helpers/widget_harness.dart';

class _MemoryTokens implements TokenStorage {
  @override
  String token = 'account-a';
  @override
  String refreshToken = '';

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
    invalidate();
    return true;
  }

  @override
  void invalidate() {
    token = '';
    refreshToken = '';
  }
}

const List<RepairRecord> _records = <RepairRecord>[
  RepairRecord(id: 'repair-a', repairItemName: '预加载的水管维修', status: 1),
];

void main() {
  late _MemoryTokens storage;
  late TokenManager tokens;

  setUp(() {
    storage = _MemoryTokens();
    tokens = TokenManager(storage: storage);
  });

  test('guest startup never requests account repair records', () async {
    storage.token = '';
    int calls = 0;
    final preloader = RepairListPreloader(
        tokens: tokens,
        loader: () async {
          calls++;
          return _records;
        });
    await preloader.preload();
    expect(calls, 0);
  });

  test('completed preload is reused once and later loads fetch again',
      () async {
    int calls = 0;
    final preloader = RepairListPreloader(
        tokens: tokens,
        loader: () async {
          calls++;
          return _records;
        });
    await preloader.preload();
    await preloader.preload();
    expect(await preloader.load(), _records);
    expect(calls, 1);
    await preloader.load();
    expect(calls, 2);
  });

  test('opening before preload completes joins the running request', () async {
    final response = Completer<List<RepairRecord>>();
    int calls = 0;
    final preloader = RepairListPreloader(
        tokens: tokens,
        loader: () {
          calls++;
          return response.future;
        });
    final loading = preloader.preload();
    await preloader.preload();
    final pageLoad = preloader.load();
    expect(calls, 1);
    response.complete(_records);
    expect(await pageLoad, _records);
    await loading;
  });

  test('failed background preload is silent and next load retries', () async {
    int calls = 0;
    final preloader = RepairListPreloader(
        tokens: tokens,
        loader: () async {
          if (++calls == 1) throw const FormatException('invalid response');
          return _records;
        });
    await preloader.preload();
    expect(await preloader.load(), _records);
    expect(calls, 2);
  });

  test('joined failure reaches page and does not poison later loads', () async {
    final response = Completer<List<RepairRecord>>();
    int calls = 0;
    final preloader = RepairListPreloader(
        tokens: tokens,
        loader: () {
          return ++calls == 1 ? response.future : Future.value(_records);
        });
    final loading = preloader.preload();
    final failure = expectLater(preloader.load(), throwsFormatException);
    response.completeError(const FormatException('invalid response'));
    await failure;
    await loading;
    expect(await preloader.load(), _records);
    expect(calls, 2);
  });

  test('successful empty preload is reusable without another request',
      () async {
    int calls = 0;
    final preloader = RepairListPreloader(
        tokens: tokens,
        loader: () async {
          calls++;
          return <RepairRecord>[];
        });
    await preloader.preload();
    expect(await preloader.load(), isEmpty);
    expect(calls, 1);
  });

  test('expired preload fetches current records', () async {
    DateTime now = DateTime(2026, 10, 11);
    int calls = 0;
    final preloader = RepairListPreloader(
      tokens: tokens,
      now: () => now,
      loader: () async {
        calls++;
        return _records;
      },
    );
    await preloader.preload();
    now = now.add(const Duration(seconds: 30));
    await preloader.load();
    expect(calls, 2);
  });

  test('account switch discards the completed previous account preload',
      () async {
    final preloader = RepairListPreloader(
        tokens: tokens,
        loader: () async {
          return <RepairRecord>[RepairRecord(id: tokens.getToken())];
        });
    await preloader.preload();
    await tokens.setToken('account-b');
    expect((await preloader.load()).single.id, 'account-b');
  });

  test('late old-account completion cannot replace a new account preload',
      () async {
    final oldResponse = Completer<List<RepairRecord>>();
    int calls = 0;
    final preloader = RepairListPreloader(
        tokens: tokens,
        loader: () {
          calls++;
          return calls == 1
              ? oldResponse.future
              : Future.value(
                  <RepairRecord>[const RepairRecord(id: 'account-b')]);
        });
    final oldLoading = preloader.preload();
    await tokens.setToken('account-b');
    await preloader.preload();
    oldResponse.complete(_records);
    await oldLoading;
    expect((await preloader.load()).single.id, 'account-b');
    expect(calls, 2);
  });

  test('account switch rejects a pending preload already joined by a page',
      () async {
    final response = Completer<List<RepairRecord>>();
    final preloader =
        RepairListPreloader(tokens: tokens, loader: () => response.future);
    final loading = preloader.preload();
    final failure = expectLater(
      preloader.load(),
      throwsA(isA<SessionChangedException>()),
    );
    await tokens.deleteToken();
    response.complete(_records);
    await failure;
    await loading;
  });

  test('invalidating an in-flight preload prevents late reuse after a mutation',
      () async {
    final response = Completer<List<RepairRecord>>();
    int calls = 0;
    final preloader = RepairListPreloader(
        tokens: tokens,
        loader: () {
          return ++calls == 1
              ? response.future
              : Future.value(<RepairRecord>[]);
        });
    final loading = preloader.preload();
    preloader.invalidate();
    response.complete(_records);
    await loading;
    expect(await preloader.load(), isEmpty);
    expect(calls, 2);
  });

  testWidgets('home renders while preloading and rebuilds do not preload twice',
      (tester) async {
    final response = Completer<List<RepairRecord>>();
    int calls = 0;
    SchedulerPhase? preloadPhase;
    final preloader = RepairListPreloader(
        tokens: tokens,
        loader: () {
          preloadPhase = WidgetsBinding.instance.schedulerPhase;
          calls++;
          return response.future;
        });
    // 使用真实首页和受控慢接口，验证首帧不依赖报修接口完成。
    Widget buildHome() => MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
              body: HomePage(
            announcementLoader: () async => <NoticeData>[],
            repairPreloader: preloader.preload,
          )),
        );
    await tester.pumpWidget(buildHome());
    await tester.pump();
    expect(response.isCompleted, isFalse);
    expect(calls, 1);
    expect(preloadPhase, SchedulerPhase.postFrameCallbacks);
    expect(find.text('社区'), findsWidgets);
    await tester.pumpWidget(buildHome());
    expect(calls, 1);
    response.complete(_records);
    await tester.pumpAndSettle();
    await finishPage(tester);
  });

  testWidgets('login starts preload and disposed home stops listening',
      (tester) async {
    int calls = 0;
    final preloader = RepairListPreloader(
        tokens: tokens,
        loader: () async {
          calls++;
          return _records;
        });
    storage.token = '';
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
          body: HomePage(
        announcementLoader: () async => <NoticeData>[],
        repairPreloader: preloader.preload,
      )),
    ));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.runAsync(() => tokens.setToken('account-b'));
    eventBus.fire(const LoginSuccessEvent());
    await tester.pump();
    await tester.pumpAndSettle();
    expect(calls, 1);
    await finishPage(tester);
    preloader.invalidate();
    eventBus.fire(const LoginSuccessEvent());
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets('repair page reuses preload and refresh fetches new data',
      (tester) async {
    int calls = 0;
    final preloader = RepairListPreloader(
        tokens: tokens,
        loader: () async {
          calls++;
          return calls == 1 ? _records : <RepairRecord>[];
        });
    await preloader.preload();
    await pumpPage(tester, RepairListPage(loader: preloader.load));
    expect(find.text('预加载的水管维修'), findsOneWidget);
    expect(calls, 1);
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('预加载的水管维修'), findsNothing);
    expect(find.text('还没有报修记录，点击下方按钮新增吧'), findsOneWidget);
    await finishPage(tester);
  });
}
