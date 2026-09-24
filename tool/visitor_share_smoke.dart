// Local device fixture only. No login, backend request or real access credential.
// Run with: tool/flutter_ohos.ps1 run -t tool/visitor_share_smoke.dart
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/models/visitor.dart';
import 'package:haven_hub/pages/visitor/visitor_pages.dart';
import 'package:haven_hub/theme/app_theme.dart';

Future<Uint8List> createSmokeImage() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder)
    ..drawColor(Colors.white, BlendMode.src);
  final Paint paint = Paint()..color = Colors.teal;
  canvas.drawRect(const Rect.fromLTWH(28, 28, 264, 264), paint);
  final TextPainter text = TextPainter(
    text: const TextSpan(
      text: 'TEST IMAGE\n\nNOT A PASS',
      style: TextStyle(color: Colors.white, fontSize: 27, fontFamily: 'Roboto'),
    ),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
  )
    ..layout(maxWidth: 264)
    ..paint(canvas, const Offset(28, 95));
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(320, 320);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  text.dispose();
  return data!.buffer.asUint8List();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final Uint8List bytes = await createSmokeImage();
  runApp(MaterialApp(
    navigatorKey: GlobalVariable.navigatorKey,
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    locale: const Locale('zh'),
    supportedLocales: const <Locale>[Locale('zh')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    onGenerateRoute: (RouteSettings settings) => MaterialPageRoute<bool>(
      settings: const RouteSettings(arguments: 'local-smoke-only'),
      builder: (_) => VisitorDetailPage(
        loader: (_) async => const VisitorRecord(
          id: 'local-smoke-only',
          houseInfo: '本地测试数据 · 无通行权限',
          status: 1,
          url: 'https://example.invalid/local-test.png',
          validTime: 30,
        ),
        imageLoader: (_) async => bytes,
        previewBuilder: (_) => Image.memory(bytes, fit: BoxFit.contain),
      ),
    ),
  ));
}
