import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/pages/login/index.dart';
import 'package:haven_hub/pages/tabs_page/index.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/widget_harness.dart';

void main() {
  testWidgets('login keyboard does not overflow the retained tabs route',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 3.5;
    tester.view.physicalSize = const Size(1320, 2856);
    tester.view.padding = const FakeViewPadding(top: 137, bottom: 98);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewInsets);
    await pumpPage(
      tester,
      TabsPage(
        announcementLoader: () async => const [],
        workerRoleLoader: () async => false,
      ),
      routes: <String, WidgetBuilder>{
        LoginPage.routeName: (_) => const LoginPage(),
      },
    );
    await tester.tap(find.descendant(
      of: find.byType(BottomNavigationBar),
      matching: find.text('我的'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('点击登录'));
    await tester.pumpAndSettle();
    final Finder button = find.widgetWithText(ElevatedButton, '登录');
    final Size originalButtonSize = tester.getSize(button);
    final Size originalTitleSize = tester.getSize(find.text('登录').at(1));
    await tester.tap(find.byType(TextField).first);
    tester.view.viewInsets = const FakeViewPadding(bottom: 1099);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // Hidden routes are still laid out. The OHOS release overflow strategy
    // can change the whole viewport even when an overflowing Flex is offstage.
    final Iterable<RenderFlex> flexes = tester.renderObjectList<RenderFlex>(
      find.byWidgetPredicate(
        (Widget widget) => widget is Flex,
        skipOffstage: false,
      ),
    );
    expect(flexes.where((RenderFlex flex) => flex.hasOverflow), isEmpty);
    expect(tester.getSize(button), originalButtonSize);
    expect(tester.getSize(find.text('登录').at(1)), originalTitleSize);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    expect(button.hitTestable(), findsOneWidget);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(button), originalButtonSize);
    await finishPage(tester);
  });

  for (final double keyboardHeight in <double>[300, 380]) {
    testWidgets('login remains reachable with keyboard height $keyboardHeight',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 780);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      await pumpPage(tester, const LoginPage());
      final Finder button = find.widgetWithText(ElevatedButton, '登录');
      expect(button.hitTestable(), findsOneWidget);
      await tester.tap(find.byType(TextField).first);
      tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getRect(button).bottom,
          lessThanOrEqualTo(780 - keyboardHeight));
      await tester.ensureVisible(find.byType(TextField).last);
      await tester.tap(find.byType(TextField).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      expect(button.hitTestable(), findsOneWidget);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(button.hitTestable(), findsOneWidget);
      await finishPage(tester);
    });
  }

  testWidgets('local login fills the returned code after requesting it',
      (WidgetTester tester) async {
    await pumpPage(tester, LoginPage(
      sendCodeLoader: (String mobile) async {
        expect(mobile, '13900009992');
        return <String, dynamic>{'code': '123456', 'development': true};
      },
    ));
    await tester.enterText(find.byType(TextField).first, '13900009992');
    await tester.tap(find.text('获取验证码'));
    await tester.pumpAndSettle();
    final TextField codeField =
        tester.widget<TextField>(find.byType(TextField).last);
    expect(codeField.controller!.text, '123456');
    await finishPage(tester);
  });
}
