import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/main.dart';
import 'package:haven_hub/router/app_routes.dart';
import 'package:haven_hub/utils/toast.dart';
import 'package:haven_hub/widgets/error_boundary.dart';

import 'helpers/widget_harness.dart';

void main() {
  testWidgets('Escape closes the top dialog then goes back, leaving root open',
      (tester) async {
    await tester.pumpWidget(Builder(builder: (context) {
      final root = const HavenHubApp().build(context) as ErrorBoundary;
      final app = root.child as MaterialApp;
      return MaterialApp(
        navigatorKey: GlobalVariable.navigatorKey,
        builder: app.builder,
        home: const Scaffold(body: Text('首页测试')),
      );
    }));
    final navigator = GlobalVariable.navigatorKey.currentState!;
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => const Scaffold(
              body: TextField(autofocus: true),
            ))));
    await tester.pumpAndSettle();
    unawaited(showDialog<void>(
      context: tester.element(find.byType(TextField)),
      builder: (_) => const AlertDialog(title: Text('图片预览测试')),
    ));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('图片预览测试'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('首页测试'), findsOneWidget);
    expect(navigator.canPop(), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('首页测试'), findsOneWidget);

    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => const PopScope(
              canPop: false,
              child: Scaffold(body: Text('禁止返回测试')),
            ))));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('禁止返回测试'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finishPage(tester);
  });

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
