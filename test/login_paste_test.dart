import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/pages/login/index.dart';

import 'helpers/widget_harness.dart';

void main() {
  testWidgets('phone uses the long press paste menu without an extra dialog',
      (WidgetTester tester) async {
    // The test clipboard validates the Flutter flow, not device permissions.
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      return switch (call.method) {
        'Clipboard.hasStrings' => <String, bool>{'value': true},
        'Clipboard.getData' => <String, String>{'text': '+8613900009992'},
        _ => null,
      };
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await pumpPage(tester, const LoginPage());
    expect(find.byTooltip('粘贴手机号'), findsNothing);
    final Finder phone = find.byType(TextField).first;
    await tester.longPress(phone);
    await tester.pumpAndSettle();
    await tester.tap(find.text('粘贴'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(phone).controller!.text, '+8613900009992');
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      isEmpty,
    );
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
    await finishPage(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.ohos));
}
