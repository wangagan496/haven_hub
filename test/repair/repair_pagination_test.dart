import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/models/repair_page.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/widget_harness.dart';

RepairPage page(List<String> ids, {int current = 1, int total = 4, int pages = 2, int status = 1}) => RepairPage(
    rows: ids.map((id) => RepairRecord(id: id, repairItemName: id, status: status)).toList(),
    current: current, total: total, pageTotal: pages);

Future<void> tapMore(WidgetTester tester, [String label = '加载更多']) async {
  await tester.scrollUntilVisible(find.text(label), 180, scrollable: find.byType(Scrollable).first);
  await tester.tap(find.text(label));
  await tester.pump();
}

Future<void> choose(WidgetTester tester, RepairStatusFilter filter) async {
  await tester.tap(find.descendant(of: find.byType(GestureDetector), matching: find.text(filter.displayName)).first);
  await tester.pump();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await tokenManager.loadTokens();
  });
  setUp(() async => tokenManager.setToken('page-account'));

  testWidgets('initial load reads one page and load-more appends only on demand', (tester) async {
    final calls = <int>[];
    final preload = <bool>[];
    await pumpPage(tester, RepairListPage(loadPage: ({required current, required filter, usePreload = false}) async {
      calls.add(current);
      preload.add(usePreload);
      return current == 1 ? page(['first', 'second']) : page(['third', 'fourth'], current: 2);
    }));
    expect(calls, [1]);
    expect(find.text('third'), findsNothing);
    await tapMore(tester);
    await tester.pumpAndSettle();
    expect(calls, [1, 2]);
    expect(preload, [true, false]);
    await tester.scrollUntilVisible(find.text('已显示全部记录'), 180);
    expect(find.text('已加载 4 / 4 条'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    await finishPage(tester);
  });

  testWidgets('duplicate taps share one load-more and retry keeps the failed page number', (tester) async {
    final delayed = Completer<RepairPage>();
    final calls = <int>[];
    await pumpPage(tester, RepairListPage(loadPage: ({required current, required filter, usePreload = false}) {
      calls.add(current);
      if (current == 1) return Future.value(page(['first', 'second']));
      if (calls.length == 2) return delayed.future;
      return Future.value(page(['third', 'fourth'], current: 2));
    }));
    await tapMore(tester);
    await tester.tap(find.text('加载中…'));
    expect(calls, [1, 2]);
    delayed.completeError(const BusinessException('稍后再试'));
    await tester.pumpAndSettle();
    expect(find.text('已加载 2 / 4 条'), findsOneWidget);
    await tapMore(tester, '重试加载更多');
    await tester.pumpAndSettle();
    expect(calls, [1, 2, 2]);
    await tester.scrollUntilVisible(find.text('已显示全部记录'), 180);
    expect(find.text('已加载 4 / 4 条'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('filter finds records absent from loaded pages and ignores old in-flight responses', (tester) async {
    final oldMore = Completer<RepairPage>();
    final calls = <String>[];
    await pumpPage(tester, RepairListPage(loadPage: ({required current, required filter, usePreload = false}) {
      calls.add('${filter.name}:$current');
      if (filter == RepairStatusFilter.completed) return Future.value(page(['completed-remote'], total: 1, pages: 1, status: 3));
      if (current == 2) return oldMore.future;
      return Future.value(page(['first', 'second']));
    }));
    await tapMore(tester);
    await choose(tester, RepairStatusFilter.completed);
    await tester.pumpAndSettle();
    expect(find.text('completed-remote'), findsOneWidget);
    expect(find.text('first'), findsNothing);
    oldMore.complete(page(['old-third', 'old-fourth'], current: 2));
    await tester.pumpAndSettle();
    expect(find.text('old-third'), findsNothing);
    expect(find.text('completed-remote'), findsOneWidget);
    expect(calls, ['all:1', 'all:2', 'completed:1']);
    await finishPage(tester);
  });

  testWidgets('rapid filter changes discard earlier first-page success and errors', (tester) async {
    final pending = Completer<RepairPage>();
    final processing = Completer<RepairPage>();
    await pumpPage(tester, RepairListPage(loadPage: ({required current, required filter, usePreload = false}) {
      if (filter == RepairStatusFilter.pending) return pending.future;
      if (filter == RepairStatusFilter.processing) return processing.future;
      return Future.value(page(['current-${filter.name}'], total: 1, pages: 1, status: filter == RepairStatusFilter.completed ? 3 : 1));
    }));
    await choose(tester, RepairStatusFilter.pending);
    await choose(tester, RepairStatusFilter.processing);
    await choose(tester, RepairStatusFilter.completed);
    await tester.pumpAndSettle();
    pending.complete(page(['stale-success'], total: 1, pages: 1));
    processing.completeError(const BusinessException('stale-error'));
    await tester.pumpAndSettle();
    expect(find.text('current-completed'), findsOneWidget);
    expect(find.text('stale-success'), findsNothing);
    expect(find.text('stale-error'), findsNothing);
    expect(tester.takeException(), isNull);
    await finishPage(tester);
  });

  testWidgets('refresh replaces accumulated rows and supersedes an in-flight next page', (tester) async {
    final delayed = Completer<RepairPage>();
    int firstLoads = 0;
    final calls = <int>[];
    await pumpPage(tester, RepairListPage(loadPage: ({required current, required filter, usePreload = false}) {
      calls.add(current);
      if (current == 2) return delayed.future;
      firstLoads++;
      return Future.value(page(firstLoads == 1 ? ['old-first', 'old-second'] : ['fresh-first', 'fresh-second']));
    }));
    await tapMore(tester);
    await tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    delayed.complete(page(['old-third', 'old-fourth'], current: 2));
    await tester.pumpAndSettle();
    expect(find.text('old-third'), findsNothing);
    expect(find.text('old-first'), findsNothing);
    expect(calls, [1, 2, 1]);
    await finishPage(tester);
  });

  testWidgets('refresh failure retains rows and the selected filter; later refresh resets paging', (tester) async {
    int completedLoads = 0;
    final calls = <String>[];
    await pumpPage(tester, RepairListPage(loadPage: ({required current, required filter, usePreload = false}) async {
      calls.add('${filter.name}:$current:$usePreload');
      if (filter == RepairStatusFilter.all) return page([], total: 0, pages: 0);
      completedLoads++;
      if (completedLoads == 2) throw const BusinessException('刷新暂不可用');
      return page([if (completedLoads == 1) 'kept' else 'replaced'], total: 1, pages: 1, status: 3);
    }));
    await choose(tester, RepairStatusFilter.completed);
    await tester.pumpAndSettle();
    await tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    await tester.pumpAndSettle();
    expect(find.text('kept'), findsOneWidget);
    await tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    await tester.pumpAndSettle();
    expect(find.text('kept'), findsNothing);
    expect(find.text('replaced'), findsOneWidget);
    expect(calls, ['all:1:true', 'completed:1:false', 'completed:1:false', 'completed:1:false']);
    await finishPage(tester);
  });

  for (final changedTotal in [false, true]) {
    testWidgets('detected ${changedTotal ? 'total change' : 'duplicate'} preserves rows and offers a fresh restart', (tester) async {
      await pumpPage(tester, RepairListPage(loadPage: ({required current, required filter, usePreload = false}) async {
        return current == 1 ? page(['first', 'second']) :
            page(changedTotal ? ['third', 'fourth'] : ['second', 'third'], current: 2, total: changedTotal ? 5 : 4);
      }));
      await tapMore(tester);
      await tester.pumpAndSettle();
      expect(find.text('已加载 2 / 4 条'), findsOneWidget);
      expect(find.text('报修记录已变化，请刷新列表后继续'), findsOneWidget);
      expect(find.text('刷新列表'), findsOneWidget);
      await finishPage(tester);
    });
  }

  testWidgets('switching accounts clears displayed rows immediately and rejects late old-account pages', (tester) async {
    final delayed = Completer<RepairPage>();
    final newAccount = Completer<RepairPage>();
    await pumpPage(tester, RepairListPage(loadPage: ({required current, required filter, usePreload = false}) {
      if (tokenManager.getToken() == 'new-account') return newAccount.future;
      if (current == 2) return delayed.future;
      return Future.value(page(['private-first', 'private-second']));
    }));
    await tapMore(tester);
    await tokenManager.setToken('new-account');
    await tester.pump();
    expect(find.text('private-first'), findsNothing);
    expect(find.text('private-second'), findsNothing);
    delayed.complete(page(['private-third', 'private-fourth'], current: 2));
    newAccount.complete(page(['new-account-row'], total: 1, pages: 1));
    await tester.pumpAndSettle();
    expect(find.text('new-account-row'), findsOneWidget);
    expect(find.text('private-third'), findsNothing);
    await tokenManager.deleteToken();
    await tester.pumpAndSettle();
    expect(find.text('new-account-row'), findsNothing);
    expect(find.text('登录状态已变化，请重新登录'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('dispose stops delayed load-more retries and removes session listener', (tester) async {
    final delayed = Completer<RepairPage>();
    int calls = 0;
    await pumpPage(tester, RepairListPage(loadPage: ({required current, required filter, usePreload = false}) {
      calls++;
      return current == 1 ? Future.value(page(['first', 'second'])) : delayed.future;
    }));
    await tapMore(tester);
    delayed.completeError(const NetworkException('暂时故障', statusCode: 503));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tokenManager.setToken('after-dispose');
    await tester.pump(const Duration(seconds: 4));
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty filtered lists retain pull-to-refresh physics', (tester) async {
    final calls = <String>[];
    await pumpPage(tester, RepairListPage(loadPage: ({required current, required filter, usePreload = false}) async {
      calls.add(filter.name);
      return page([], total: 0, pages: 0);
    }));
    await choose(tester, RepairStatusFilter.waiting);
    await tester.pumpAndSettle();
    expect(tester.widget<ListView>(find.byType(ListView)).physics, isA<AlwaysScrollableScrollPhysics>());
    await tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    await tester.pumpAndSettle();
    expect(calls, ['all', 'waiting', 'waiting']);
    await finishPage(tester);
  });

  testWidgets('returning from detail refreshes first page even if an older refresh is still pending', (tester) async {
    final stale = Completer<RepairPage>();
    int calls = 0;
    await pumpPage(tester, RepairListPage(loadPage: ({required current, required filter, usePreload = false}) {
      calls++;
      if (calls == 2) return stale.future;
      return Future.value(page([if (calls == 1) 'before-detail' else 'after-detail'], total: 1, pages: 1));
    }), routes: {
      RepairDetailPage.routeName: (context) => Scaffold(body: TextButton(
        onPressed: () => Navigator.pop(context), child: const Text('返回列表'))),
    });
    final refreshing = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    await tester.pump();
    await tester.tap(find.text('before-detail'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回列表'));
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(find.text('after-detail'), findsOneWidget);
    stale.complete(page(['stale-refresh'], total: 1, pages: 1));
    await refreshing;
    await tester.pumpAndSettle();
    expect(find.text('stale-refresh'), findsNothing);
    await finishPage(tester);
  });

  testWidgets('successful creation returns to fresh first page with the selected filter', (tester) async {
    final calls = <String>[];
    await pumpPage(tester, RepairListPage(loadPage: ({required current, required filter, usePreload = false}) async {
      calls.add('${filter.name}:$current:$usePreload');
      return page([if (calls.length > 2) 'new-created' else 'existing'], total: 1, pages: 1, status: 5);
    }), routes: {
      RepairFormPage.routeName: (context) => Scaffold(body: TextButton(
        onPressed: () => Navigator.pop(context, true), child: const Text('完成创建'))),
    });
    await choose(tester, RepairStatusFilter.waiting);
    await tester.pumpAndSettle();
    await tester.tap(find.text('新增报修'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成创建'));
    await tester.pumpAndSettle();
    expect(find.text('new-created'), findsOneWidget);
    expect(calls, ['all:1:true', 'waiting:1:false', 'waiting:1:false']);
    await finishPage(tester);
  });
}
