import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/models/visitor.dart';
import 'package:haven_hub/pages/visitor/visitor_pages.dart';
import 'package:haven_hub/theme/app_theme.dart';

import '../tool/visitor_share_smoke.dart' show createSmokeImage;

void main() {
  testWidgets(
      'share control remains reachable on phone and desktop with large text',
      (WidgetTester tester) async {
    final bool capture = Platform.environment['HAVEN_VISUAL_QA'] == '1';
    if (capture) {
      final File font = File('C:/Windows/Fonts/msyh.ttc');
      if (font.existsSync()) {
        final FontLoader loader = FontLoader('HavenQA')
          ..addFont(Future<ByteData>.value(
              ByteData.sublistView(font.readAsBytesSync())));
        await loader.load();
        final FontLoader imageFont = FontLoader('Roboto')
          ..addFont(Future<ByteData>.value(
              ByteData.sublistView(font.readAsBytesSync())));
        await imageFont.load();
      }
      final FontLoader icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
    final Uint8List bytes = (await tester.runAsync(createSmokeImage))!;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    for (final Size size in <Size>[
      const Size(360, 800),
      const Size(1024, 768)
    ]) {
      tester.view.physicalSize = size;
      for (final double scale in <double>[1, 2]) {
        final GlobalKey boundary = GlobalKey();
        final ThemeData theme = buildAppTheme();
        await tester.pumpWidget(RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: capture
                ? theme.copyWith(
                    textTheme: theme.textTheme.apply(fontFamily: 'HavenQA'))
                : theme,
            locale: const Locale('zh'),
            supportedLocales: const <Locale>[Locale('zh')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            onGenerateRoute: (_) => MaterialPageRoute<bool>(
              settings: const RouteSettings(arguments: 'layout-test'),
              builder: (_) => VisitorDetailPage(
                loader: (_) async => const VisitorRecord(
                    status: 1,
                    houseInfo: '本地测试数据 · 无通行权限',
                    url: 'https://example.invalid/test.png'),
                shareSupported: true,
                previewBuilder: (_) => Image.memory(bytes),
                imageLoader: (_) async => bytes,
                sharer: (_, {Rect? anchor}) async {},
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final Finder button = find.widgetWithText(FilledButton, '分享通行码');
        expect(button.hitTestable(), findsOneWidget);
        expect(tester.getRect(button).bottom, lessThanOrEqualTo(size.height));
        if (capture) {
          await tester.runAsync(() async {
            final RenderRepaintBoundary render = boundary.currentContext!
                .findRenderObject()! as RenderRepaintBoundary;
            final ui.Image image = await render.toImage();
            final ByteData? png =
                await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory('build/verification').create(recursive: true);
            await File(
                    'build/verification/share-${size.width.toInt()}-${scale.toInt()}x.png')
                .writeAsBytes(png!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
