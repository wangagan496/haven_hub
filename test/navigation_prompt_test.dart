import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/main.dart';
import 'package:haven_hub/router/app_routes.dart';
import 'package:haven_hub/utils/toast.dart';
import 'package:haven_hub/widgets/error_boundary.dart';

import 'helpers/widget_harness.dart';

void main() {
  testWidgets(
      'production route accepts the bool result requested by repair and visitor',
      (WidgetTester tester) async {
    await pumpPage(tester, Builder(builder: (BuildContext context) {
      final ErrorBoundary root =
          const HavenHubApp().build(context) as ErrorBoundary;
      final MaterialApp app = root.child as MaterialApp;
      for (final String name in <String>[
        AppRoutes.repairDetail,
        AppRoutes.repairForm,
        AppRoutes.visitorForm
      ]) {
        final Route<dynamic>? route = app
            .onGenerateRoute!(RouteSettings(name: name, arguments: 'test-id'));
        expect(route, isA<Route<bool>>());
      }
      return const SizedBox.shrink();
    }));
    await finishPage(tester);
  });

  testWidgets(
      'back-to-back prompts before a frame replace the previous entry safely',
      (WidgetTester tester) async {
    await pumpPage(tester, const Scaffold());
    await PromptAction.showError('第一条测试提示');
    await PromptAction.showError('第二条测试提示');
    await tester.pump();
    expect(find.text('第一条测试提示'), findsNothing);
    expect(find.text('第二条测试提示'), findsOneWidget);
    await finishPage(tester);
  });
}
