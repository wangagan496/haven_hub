import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/pages/login/index.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/widget_harness.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.loadTokens();
  });

  testWidgets(
      'login response without refreshToken is rejected without saving credentials',
      (WidgetTester tester) async {
    await pumpPage(
        tester,
        LoginPage(
          loginLoader: (_, __) async =>
              <String, dynamic>{'token': 'access-only'},
        ));
    await tester.enterText(find.byType(TextField).first, '13800138000');
    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.tap(find.widgetWithText(ElevatedButton, '登录'));
    await tester.pumpAndSettle();
    expect(tokenManager.getToken(), isEmpty);
    expect(tokenManager.getRefreshToken(), isEmpty);
    expect(find.text('登录接口未返回 refreshToken'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('real SMS receipt starts cooldown without autofilling a code',
      (WidgetTester tester) async {
    int calls = 0;
    await pumpPage(
        tester,
        LoginPage(
          enableDevelopmentCodeAutofill: false,
          sendCodeLoader: (String mobile) async {
            calls++;
            expect(mobile, '13800138000');
            return <String, dynamic>{'development': false, 'expiresIn': 300};
          },
        ));
    await tester.enterText(find.byType(TextField).first, '+8613800138000');
    await tester.enterText(find.byType(TextField).last, '999999');
    await tester.tap(find.text('获取验证码'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        isEmpty);
    expect(find.text('重新获取(60s)'), findsOneWidget);
    expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, '重新获取(60s)'),
            )
            .onPressed,
        isNull);
    await tester.pump(const Duration(seconds: 61));
    expect(find.text('获取验证码'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('production receipt cannot autofill an unexpected leaked field',
      (WidgetTester tester) async {
    await pumpPage(
        tester,
        LoginPage(
          sendCodeLoader: (_) async => <String, dynamic>{
            'development': false,
            'expiresIn': 300,
            'code': '123456',
          },
        ));
    await tester.enterText(find.byType(TextField).first, '13800138000');
    await tester.tap(find.text('获取验证码'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        isEmpty);
    expect(find.text('重新获取(60s)'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets(
      'failed or incomplete SMS result releases the button without cooldown',
      (WidgetTester tester) async {
    for (final bool fails in <bool>[true, false]) {
      await pumpPage(tester, LoginPage(
        sendCodeLoader: (_) async {
          if (fails) throw const NetworkException('短信暂不可用');
          return <String, dynamic>{'code': '123456'};
        },
      ));
      await tester.enterText(find.byType(TextField).first, '13800138000');
      await tester.tap(find.text('获取验证码'));
      await tester.pumpAndSettle();
      expect(find.text('获取验证码'), findsOneWidget);
      expect(
          tester
              .widget<TextField>(find.byType(TextField).last)
              .controller!
              .text,
          isEmpty);
      await finishPage(tester);
    }
  });

  testWidgets(
      'pending SMS blocks duplicates and late receipt after disposal is ignored',
      (WidgetTester tester) async {
    final Completer<Map<String, dynamic>> pending =
        Completer<Map<String, dynamic>>();
    int calls = 0;
    await pumpPage(tester, LoginPage(sendCodeLoader: (_) {
      calls++;
      return pending.future;
    }));
    await tester.enterText(find.byType(TextField).first, '13800138000');
    await tester.tap(find.text('获取验证码'));
    await tester.pump();
    expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, '发送中...'),
            )
            .onPressed,
        isNull);
    expect(calls, 1);
    await finishPage(tester);
    pending.complete(<String, dynamic>{'development': false, 'expiresIn': 300});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'SMS response for a previous phone does not change the current form',
      (WidgetTester tester) async {
    final Completer<Map<String, dynamic>> pending =
        Completer<Map<String, dynamic>>();
    await pumpPage(tester, LoginPage(sendCodeLoader: (_) => pending.future));
    await tester.enterText(find.byType(TextField).first, '13800138000');
    await tester.tap(find.text('获取验证码'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '13900139000');
    await tester.enterText(find.byType(TextField).last, '999999');
    pending.complete(<String, dynamic>{'development': false, 'expiresIn': 300});
    await tester.pumpAndSettle();
    expect(find.text('获取验证码'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        '999999');
    await finishPage(tester);
  });
}
