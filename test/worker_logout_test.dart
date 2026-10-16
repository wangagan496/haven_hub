import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/login/index.dart';
import 'package:haven_hub/pages/worker/worker_pages.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/utils/token_storage.dart';
import 'package:haven_hub/utils/worker_repair_read_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/widget_harness.dart';

/// 磁盘清理会失败的凭证存储，复现设备上 SharedPreferences 删除失败。
class _FailingClearStorage implements TokenStorage {
  @override
  String token = 'worker-token';

  @override
  String refreshToken = 'worker-refresh';

  int invalidateCalls = 0;

  @override
  Future<void> load() async {}

  @override
  Future<bool> write(String token, String refreshToken) async => true;

  @override
  Future<bool> clear() async {
    token = '';
    refreshToken = '';
    return false;
  }

  @override
  void invalidate() {
    invalidateCalls++;
    token = '';
    refreshToken = '';
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('failed disk clear still ends the in-memory worker session',
      (tester) async {
    final _FailingClearStorage storage = _FailingClearStorage();
    final TokenManager tokens = TokenManager(storage: storage);
    final int sessionBefore = tokens.sessionId;

    await pumpPage(
      tester,
      WorkerPage(
        recordsLoader: () async => const <RepairRecord>[],
        readStore: WorkerRepairReadStore(),
        tokens: tokens,
      ),
      routes: <String, WidgetBuilder>{
        LoginPage.routeName: (_) => const Scaffold(body: Text('login-route')),
      },
    );

    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();

    expect(tokens.getToken(), isEmpty);
    expect(tokens.sessionId, greaterThan(sessionBefore));
    // deleteToken 自身作废一次，失败兜底再作废一次。
    expect(storage.invalidateCalls, 2);
    expect(find.text('本地登录信息清除失败，请重试'), findsOneWidget);
    // 清理未落盘，不能假装已退出跳到登录页。
    expect(find.text('login-route'), findsNothing);
    await finishPage(tester);
  });
}
