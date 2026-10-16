import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/l10n/app_localizations.dart';
import 'package:haven_hub/pages/login/index.dart';
import 'package:haven_hub/pages/tabs_page/index.dart';
import 'package:haven_hub/utils/emitter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/widget_harness.dart';


const Key _workerKey = ValueKey('fake-worker-page');

Future<void> _pumpTabs(WidgetTester tester, WorkerRoleLoader loader) async {
  final Widget tabs = TabsPage(
    announcementLoader: () async => const [],
    workerRoleLoader: loader,
    workerPageBuilder: (_) => const Scaffold(key: _workerKey),
  );
  await tester.pumpWidget(MaterialApp(
    navigatorKey: GlobalVariable.navigatorKey,
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: tabs,
    routes: <String, WidgetBuilder>{
      LoginPage.routeName: (_) => const Scaffold(body: Text('login-route')),
    },
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('role lookup failure falls back to resident tabs',
      (tester) async {
    await _pumpTabs(tester, () async => throw Exception('offline'));
    expect(find.byKey(_workerKey), findsNothing);
    expect(find.byType(BottomNavigationBar), findsOneWidget);
    expect(find.text('登录状态初始化失败，请重试'), findsNothing);
    expect(find.text('身份信息获取失败，已按住户界面进入'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('logout leaves workbench and next login re-resolves role',
      (tester) async {
    bool isWorker = true;
    await _pumpTabs(tester, () async => isWorker);
    expect(find.byKey(_workerKey), findsOneWidget);

    // 凭证失效：工作台必须收到登出并跳到登录页。
    eventBus.fire(const LogoutEvent());
    await tester.pumpAndSettle();
    expect(find.text('login-route'), findsOneWidget);

    // 住户在同一个 TabsPage 实例上登录，返回后不能看到上一位师傅的工作台。
    isWorker = false;
    eventBus.fire(const LoginSuccessEvent());
    await tester.pumpAndSettle();
    // 模拟登录页 maybePop 回到栈底的同一个 TabsPage。
    GlobalVariable.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(_workerKey), findsNothing);
    expect(find.byType(BottomNavigationBar), findsOneWidget);

    // 反过来，师傅登录后同一实例切换到工作台。
    isWorker = true;
    eventBus.fire(const LoginSuccessEvent());
    await tester.pumpAndSettle();
    expect(find.byKey(_workerKey), findsOneWidget);
    await finishPage(tester);
  });
}
