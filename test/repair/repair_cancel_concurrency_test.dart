import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/repair.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/widget_harness.dart';

RepairRecord record({int revision = 7, int status = 1}) => RepairRecord(
      id: 'cancel-race',
      revision: revision,
      status: status,
      repairItemName: '撤销测试工单',
      description: '保留已查看的版本',
    );

Finder get cancelButton => find.widgetWithText(FilledButton, '取消报修');

Future<void> confirmCancellation(WidgetTester tester) async {
  await tester.tap(cancelButton);
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, '确认取消'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void resume(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.loadTokens();
    await tokenManager.setToken('repair-cancel-owner');
  });

  testWidgets('direct cancellation sends the viewed revision once and blocks reads',
      (tester) async {
    final response = Completer<void>();
    final sent = <int>[];
    var reads = 0;
    await pumpPage(tester, RepairDetailPage(
      loadRepairDetail: (_) async {
        reads++;
        return record();
      },
      cancelRepair: (id, {required revision}) {
        sent.add(revision);
        return response.future;
      },
    ), arguments: 'cancel-race');
    final oldTap = tester.widget<FilledButton>(cancelButton).onPressed!;
    await confirmCancellation(tester);
    oldTap();
    resume(tester);
    await tester.pump();
    expect(sent, <int>[7]);
    expect(reads, 1);
    final refresh = find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == '刷新进度');
    expect(tester.widget<IconButton>(refresh).onPressed, isNull);
    response.completeError(const NetworkException('结果未收到'));
    await tester.pumpAndSettle();
    expect(find.text('刷新工单状态'), findsOneWidget);
    await finishPage(tester);
  });

  for (final status in <int>[1, 2]) {
    testWidgets('refresh during cancellation confirmation rejects stale status $status',
        (tester) async {
      var reads = 0, writes = 0;
      await pumpPage(tester, RepairDetailPage(
        loadRepairDetail: (_) async => ++reads == 1
            ? record()
            : record(revision: 8, status: status),
        cancelRepair: (_, {required revision}) async { writes++; },
      ), arguments: 'cancel-race');
      await tester.tap(cancelButton);
      await tester.pumpAndSettle();
      resume(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确认取消'));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(writes, 0);
      expect(find.text('工单状态已更新，请重新核对后再确认'), findsOneWidget);
      if (status == 2) expect(find.text('申请撤销'), findsOneWidget);
      await finishPage(tester);
    });
  }

  testWidgets('confirmation cannot submit while a refresh is still pending',
      (tester) async {
    final response = Completer<RepairRecord>();
    var reads = 0, writes = 0;
    await pumpPage(tester, RepairDetailPage(
      loadRepairDetail: (_) => ++reads == 1
          ? Future.value(record()) : response.future,
      cancelRepair: (_, {required revision}) async { writes++; },
    ), arguments: 'cancel-race');
    await tester.tap(cancelButton);
    await tester.pumpAndSettle();
    resume(tester);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '确认取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(writes, 0);
    response.complete(record(revision: 8));
    await tester.pumpAndSettle();
    expect(writes, 0);
    await finishPage(tester);
  });

  testWidgets('account switch hides old detail and cancels modal submission',
      (tester) async {
    var writes = 0;
    await pumpPage(tester, RepairDetailPage(
      loadRepairDetail: (_) async => record(),
      cancelRepair: (_, {required revision}) async { writes++; },
    ), arguments: 'cancel-race');
    await tester.tap(cancelButton);
    await tester.pumpAndSettle();
    await tokenManager.setToken('another-resident');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '确认取消'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(find.text('撤销测试工单'), findsNothing);
    expect(find.text('登录账号已变化，请返回报修列表重新进入'), findsOneWidget);
    expect(find.text('报修已取消'), findsNothing);
    await finishPage(tester);
  });

  for (final fail in <bool>[false, true]) {
    testWidgets('late cancellation response after account switch is ignored fail=$fail',
        (tester) async {
      final response = Completer<void>();
      await pumpPage(tester, const Scaffold(body: Text('原列表')),
          routes: <String, WidgetBuilder>{
        RepairDetailPage.routeName: (_) => RepairDetailPage(
          loadRepairDetail: (_) async => record(),
          cancelRepair: (_, {required revision}) => response.future,
        ),
      });
      unawaited(GlobalVariable.navigatorKey.currentState!.pushNamed<void>(
          RepairDetailPage.routeName, arguments: 'cancel-race'));
      await tester.pumpAndSettle();
      await confirmCancellation(tester);
      await tokenManager.setToken('another-resident');
      if (fail) {
        response.completeError(const NetworkException('旧账号取消错误'));
      } else {
        response.complete();
      }
      await tester.pumpAndSettle();
      expect(find.text('报修详情'), findsOneWidget);
      expect(find.text('原列表'), findsNothing);
      expect(find.text('旧账号取消错误'), findsNothing);
      expect(find.text('报修已取消'), findsNothing);
      expect(tester.takeException(), isNull);
      await finishPage(tester);
    });
  }

  for (final failure in <NetworkException>[
    const NetworkException('工单已更新', statusCode: 409),
    const NetworkException('取消响应超时', isTimeout: true),
  ]) {
    testWidgets('cancellation recovery needs a successful refresh ${failure.message}',
        (tester) async {
      var reads = 0;
      final sent = <int>[];
      await pumpPage(tester, RepairDetailPage(
        loadRepairDetail: (_) async {
          reads++;
          if (reads == 2) throw const NetworkException('刷新失败');
          return record(revision: reads == 1 ? 7 : 9);
        },
        cancelRepair: (_, {required revision}) async {
          sent.add(revision);
          throw failure;
        },
      ), arguments: 'cancel-race');
      final staleTap = tester.widget<FilledButton>(cancelButton).onPressed!;
      await confirmCancellation(tester);
      await tester.pumpAndSettle();
      resume(tester);
      staleTap();
      await tester.pumpAndSettle();
      expect(sent, <int>[7]);
      expect(reads, 1);
      expect(cancelButton, findsNothing);
      await tester.tap(find.text('刷新工单状态'));
      await tester.pumpAndSettle();
      staleTap();
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(sent, <int>[7]);
      expect(cancelButton, findsNothing);
      await tester.tap(find.text('刷新工单状态'));
      await tester.pumpAndSettle();
      expect(reads, 3);
      expect(sent, <int>[7]);
      await confirmCancellation(tester);
      await tester.pumpAndSettle();
      expect(sent, <int>[7, 9]);
      await finishPage(tester);
    });
  }

  testWidgets('lost response followed by cancelled detail removes actions without success claim',
      (tester) async {
    var reads = 0, writes = 0;
    await pumpPage(tester, RepairDetailPage(
      loadRepairDetail: (_) async => ++reads == 1
          ? record() : record(revision: 8, status: 0),
      cancelRepair: (_, {required revision}) async {
        writes++;
        throw const NetworkException('结果未收到');
      },
    ), arguments: 'cancel-race');
    await confirmCancellation(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新工单状态'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.text('已取消'), findsOneWidget);
    expect(cancelButton, findsNothing);
    expect(find.text('报修已取消'), findsNothing);
    await finishPage(tester);
  });

  testWidgets('missing repair on recovery clears stale detail and cancellation action',
      (tester) async {
    var reads = 0, writes = 0;
    await pumpPage(tester, RepairDetailPage(
      loadRepairDetail: (_) async {
        if (++reads > 1) throw const NetworkException('工单不存在', statusCode: 404);
        return record();
      },
      cancelRepair: (_, {required revision}) async {
        writes++;
        throw const NetworkException('结果未收到');
      },
    ), arguments: 'cancel-race');
    await confirmCancellation(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新工单状态'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.text('撤销测试工单'), findsNothing);
    expect(cancelButton, findsNothing);
    expect(find.text('报修已取消'), findsNothing);
    await finishPage(tester);
  });

  testWidgets('late cancellation success after leaving cannot pop the next page',
      (tester) async {
    final response = Completer<void>();
    await pumpPage(tester, const Scaffold(body: Text('原列表')),
        routes: <String, WidgetBuilder>{
      RepairDetailPage.routeName: (_) => RepairDetailPage(
        loadRepairDetail: (_) async => record(),
        cancelRepair: (_, {required revision}) => response.future,
      ),
    });
    unawaited(GlobalVariable.navigatorKey.currentState!.pushNamed<void>(
        RepairDetailPage.routeName, arguments: 'cancel-race'));
    await tester.pumpAndSettle();
    await confirmCancellation(tester);
    GlobalVariable.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    response.complete();
    await tester.pumpAndSettle();
    expect(find.text('原列表'), findsOneWidget);
    expect(find.text('报修已取消'), findsNothing);
    expect(tester.takeException(), isNull);
    await finishPage(tester);
  });

  for (final switchAccount in <bool>[false, true]) {
    testWidgets('revocation modal rejects changed state or account switch=$switchAccount',
        (tester) async {
      var reads = 0, writes = 0;
      await pumpPage(tester, RepairDetailPage(
        loadRepairDetail: (_) async => record(status: 2, revision: 6 + ++reads),
        submitAction: (current, action) async {
          writes++;
          return current;
        },
      ), arguments: 'cancel-race');
      final open = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, '申请撤销')).onPressed!;
      open();
      open();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(find.byType(TextField), '问题已自行解决');
      await tester.tap(find.byType(CheckboxListTile));
      if (switchAccount) {
        await tokenManager.setToken('another-resident');
      } else {
        resume(tester);
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('提交撤销申请'));
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(reads, switchAccount ? 1 : 2);
      expect(find.text(switchAccount
          ? '登录账号已变化，请返回报修列表重新进入'
          : '工单状态已更新，请重新核对后再确认'), findsOneWidget);
      await finishPage(tester);
    });
  }

  testWidgets('accepted repair uses revisioned revocation and requires refresh after failure',
      (tester) async {
    var directWrites = 0, actions = 0;
    int? sentRevision;
    RepairAction? sentAction;
    await pumpPage(tester, RepairDetailPage(
      loadRepairDetail: (_) async => record(status: 2),
      cancelRepair: (_, {required revision}) async { directWrites++; },
      submitAction: (current, action) async {
        actions++;
        sentRevision = current.revision;
        sentAction = action;
        throw const NetworkException('撤销申请响应超时', isTimeout: true);
      },
    ), arguments: 'cancel-race');
    await tester.tap(find.widgetWithText(FilledButton, '申请撤销'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '问题已自行解决');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交撤销申请'));
    await tester.pumpAndSettle();
    expect(directWrites, 0);
    expect(actions, 1);
    expect(sentRevision, 7);
    expect(sentAction, isA<RevokeAction>());
    expect((sentAction as RevokeAction).notified, isTrue);
    expect(find.text('刷新工单状态'), findsOneWidget);
    expect(find.text('撤销申请已提交'), findsNothing);
    await finishPage(tester);
  });
}
