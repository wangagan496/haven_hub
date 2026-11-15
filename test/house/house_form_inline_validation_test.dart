import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:haven_hub/controller/build_controller.dart';
import 'package:haven_hub/models/user_info.dart';
import 'package:haven_hub/pages/house/house_form.dart';
import 'package:haven_hub/utils/house_submission_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/widget_harness.dart';

Future<UserInfo> _identity() async => const UserInfo(id: 'validation-owner', avatarUrl: '', nickName: '测试');

void main() {
  setUp(() {
    Get.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    BuildController.instance()
      ..selectCommunity(<String, dynamic>{'name': '测试小区'})
      ..selectBuilding('1栋')
      ..selectRoom('101');
  });
  tearDown(Get.reset);

  testWidgets('name and mobile show inline errors after input loses focus',
      (WidgetTester tester) async {
    await pumpPage(tester, HouseForm(userInfoLoader: _identity, submissionStore: HouseSubmissionStore()));
    await tester.pumpAndSettle();

    final Finder fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(2));
    final Finder nameInput =
        find.descendant(of: fields.first, matching: find.byType(TextField));
    expect(tester.widget<TextField>(nameInput).decoration?.hintText, '请输入姓名');
    expect(find.text('姓名格式不正确'), findsNothing);
    expect(find.text('手机号格式不正确'), findsNothing);

    await tester.enterText(fields.first, '张');
    await tester.tap(fields.last);
    await tester.pump();
    expect(find.text('姓名格式不正确'), findsOneWidget);

    await tester.enterText(fields.last, '123');
    await tester.tap(fields.first);
    await tester.pump();
    expect(find.text('手机号格式不正确'), findsOneWidget);

    await tester.enterText(fields.first, 'Alice Smith');
    await tester.tap(fields.last);
    await tester.pump();
    expect(find.text('姓名格式不正确'), findsNothing);

    await tester.enterText(fields.last, '13800138000');
    await tester.tap(fields.first);
    await tester.pump();
    expect(find.text('手机号格式不正确'), findsNothing);

    await finishPage(tester);
  });

  testWidgets('submit marks invalid fields without a format toast',
      (WidgetTester tester) async {
    await pumpPage(tester, HouseForm(userInfoLoader: _identity, submissionStore: HouseSubmissionStore()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '张');
    await tester.enterText(find.byType(TextFormField).last, '123');
    await tester.scrollUntilVisible(
      find.text('提交审核'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('提交审核'));
    await tester.pumpAndSettle();

    expect(find.text('姓名格式不正确'), findsOneWidget);
    expect(find.text('手机号格式不正确'), findsOneWidget);
    await finishPage(tester);
  });
}
