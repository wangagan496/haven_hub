import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:haven_hub/controller/build_controller.dart';
import 'package:haven_hub/pages/house/house_form.dart';

import 'helpers/widget_harness.dart';

void main() {
  setUp(() {
    Get.reset();
    BuildController.instance()
      ..updateBuildingInfo(<String, dynamic>{'name': '测试小区'})
      ..updateBuild('1栋')
      ..updateRoom('101');
  });
  tearDown(Get.reset);

  testWidgets('name and mobile show inline errors after input loses focus',
      (WidgetTester tester) async {
    await pumpPage(tester, const HouseForm());

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
    await pumpPage(tester, const HouseForm());
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
