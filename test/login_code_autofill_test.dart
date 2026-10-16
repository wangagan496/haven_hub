import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/pages/login/index.dart';

import 'helpers/widget_harness.dart';

void main() {
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
