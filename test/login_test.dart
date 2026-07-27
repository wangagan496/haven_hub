import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/pages/login/index.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel toastChannel =
      MethodChannel('PonnamKarthik/fluttertoast');

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      toastChannel,
      (MethodCall call) async => true,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(toastChannel, null);
  });

  testWidgets('手机号格式错误时不发送验证码', (WidgetTester tester) async {
    bool didSend = false;

    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(
          sendCodeLoader: (String mobile) async {
            didSend = true;
            return <String, dynamic>{};
          },
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).first, '123');
    await tester.tap(find.text('获取验证码'));
    await tester.pump();

    expect(didSend, isFalse);
  });

  testWidgets('发送验证码后倒计时并阻止重复发送', (
    WidgetTester tester,
  ) async {
    int sendCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(
          sendCodeLoader: (String mobile) async {
            sendCount++;
            return <String, dynamic>{'code': '123456'};
          },
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).first, '13800138000');
    await tester.tap(find.text('获取验证码'));
    await tester.pump();

    expect(find.text('重新获取(60s)'), findsOneWidget);

    await tester.tap(find.text('重新获取(60s)'));
    await tester.pump();
    expect(sendCount, 1);

    await tester.pump(const Duration(seconds: 2));
    final TextField codeField = tester.widget<TextField>(
      find.byType(TextField).at(1),
    );
    expect(codeField.controller?.text, '123456');
    expect(find.text('重新获取(58s)'), findsOneWidget);
  });

  testWidgets('登录成功保存双 token 并进入原目标页', (
    WidgetTester tester,
  ) async {
    String? requestedMobile;
    String? requestedCode;

    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(
          toName: '/profile',
          sendCodeLoader: (String mobile) async {
            return <String, dynamic>{'code': '123456'};
          },
          loginLoader: (String mobile, String code) async {
            requestedMobile = mobile;
            requestedCode = code;
            return <String, dynamic>{
              'token': 'access-token',
              'refreshToken': 'refresh-token',
            };
          },
        ),
        routes: <String, WidgetBuilder>{
          '/profile': (BuildContext context) {
            return const Scaffold(body: Text('个人信息目标页'));
          },
        },
      ),
    );

    await tester.enterText(find.byType(TextField).first, '13800138000');
    await tester.enterText(find.byType(TextField).at(1), '123456');
    await tester.tap(find.widgetWithText(ElevatedButton, '登录'));
    await tester.pumpAndSettle();

    expect(requestedMobile, '13800138000');
    expect(requestedCode, '123456');
    expect(tokenManager.getToken(), 'access-token');
    expect(tokenManager.getRefreshToken(), 'refresh-token');
    expect(find.text('个人信息目标页'), findsOneWidget);
  });
}
