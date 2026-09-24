import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/theme/app_theme.dart';

Future<void> pumpPage(
  WidgetTester tester,
  Widget page, {
  Object? arguments,
  Map<String, WidgetBuilder> routes = const <String, WidgetBuilder>{},
}) async {
  await tester.pumpWidget(MaterialApp(
    navigatorKey: GlobalVariable.navigatorKey,
    theme: buildAppTheme(),
    locale: const Locale('zh'),
    supportedLocales: const <Locale>[Locale('zh')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    onGenerateRoute: (RouteSettings settings) => MaterialPageRoute<bool>(
      settings: RouteSettings(
          name: settings.name, arguments: settings.arguments ?? arguments),
      builder: routes[settings.name] ?? (_) => page,
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> finishPage(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}
