import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/models/visitor.dart';
import 'package:haven_hub/pages/visitor/visitor_pages.dart';
import 'package:haven_hub/platform/visitor_pass_share.dart';
import 'package:haven_hub/utils/app_exception.dart';

import 'helpers/widget_harness.dart';

final Uint8List passImage = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII=');
const VisitorRecord visitor = VisitorRecord(
    id: 'test', status: 1, url: 'https://example.invalid/test-pass.png');

void main() {
  testWidgets(
      'backgrounding or covering a page during download suppresses native share',
      (WidgetTester tester) async {
    for (final String mode in <String>[
      'background',
      'background-and-return',
      'covered'
    ]) {
      final Completer<Uint8List> download = Completer<Uint8List>();
      int shares = 0;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpPage(
          tester,
          VisitorDetailPage(
            loader: (_) async => visitor,
            shareSupported: true,
            previewBuilder: (_) => Image.memory(passImage),
            imageLoader: (_) => download.future,
            sharer: (_, {Rect? anchor}) async {
              shares++;
            },
          ),
          arguments: 'test',
          routes: <String, WidgetBuilder>{
            '/cover': (_) => const Scaffold(body: Text('覆盖页面')),
          });
      await tester.tap(find.text('分享通行码'));
      await tester.pump();
      if (mode == 'covered') {
        unawaited(GlobalVariable.navigatorKey.currentState!
            .pushNamed<void>('/cover'));
        await tester.pumpAndSettle();
      } else {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        if (mode == 'background-and-return') {
          tester.binding
              .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        }
      }
      download.complete(passImage);
      await tester.pump();
      expect(shares, 0, reason: mode);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await finishPage(tester);
    }
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('haven_hub/visitor_pass_share');
  test('channel includes the physical-pixel anchor for native popup placement',
      () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      received = call;
      return null;
    });
    await shareVisitorPassImage(passImage,
        anchor: const Rect.fromLTWH(32, 800, 640, 80));
    final Map<dynamic, dynamic> args =
        received!.arguments as Map<dynamic, dynamic>;
    expect(args['anchorX'], 32);
    expect(args['anchorY'], 800);
    expect(args['anchorWidth'], 640);
    expect(args['anchorHeight'], 80);
    await expectLater(shareVisitorPassImage(passImage, anchor: Rect.zero),
        throwsFormatException);
  });

  testWidgets(
      'page measures the actual button and converts its bounds to pixels',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(1600, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    Rect? received;
    await pumpPage(
        tester,
        VisitorDetailPage(
          loader: (_) async => visitor,
          shareSupported: true,
          previewBuilder: (_) => Image.memory(passImage),
          imageLoader: (_) async => passImage,
          sharer: (_, {Rect? anchor}) async {
            received = anchor;
          },
        ),
        arguments: 'test');
    final Finder button = find.widgetWithText(FilledButton, '分享通行码');
    final Rect bounds = tester.getRect(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
        received,
        Rect.fromLTWH(bounds.left * 2, bounds.top * 2, bounds.width * 2,
            bounds.height * 2));
    await finishPage(tester);
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('channel sends only image bytes and does not claim delivery', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      received = call;
      return null;
    });
    await shareVisitorPassImage(passImage);
    expect(received!.method, 'shareImage');
    expect(
        (received!.arguments as Map<dynamic, dynamic>).keys, <String>['bytes']);
    expect((received!.arguments as Map<dynamic, dynamic>)['bytes'], passImage);
  });

  test('missing plugin and native failures become user-safe errors', () async {
    await expectLater(
        shareVisitorPassImage(passImage), throwsA(isA<BusinessException>()));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
          code: 'share_failed', message: 'private native details');
    });
    await expectLater(
        shareVisitorPassImage(passImage),
        throwsA(isA<BusinessException>().having(
            (BusinessException e) => e.message, 'message', '打开系统分享失败，请重试')));
  });

  test('rejects empty, oversized and non-image bytes', () {
    for (final Uint8List bytes in <Uint8List>[
      Uint8List(0),
      Uint8List(maxVisitorPassBytes + 1),
      Uint8List.fromList(utf8.encode('<html>not an image</html>'))
    ]) {
      expect(() => validateVisitorPassImage(bytes), throwsFormatException);
    }
    expect(() => validateVisitorPassImage(passImage), returnsNormally);
    expect(
        const VisitorRecord(status: 3, url: 'https://example.invalid/pass.png')
            .canShare,
        isFalse);
    expect(
        const VisitorRecord(status: 2, url: 'https://example.invalid/pass.png')
            .canShare,
        isFalse);
  });

  testWidgets(
      'one download and share at a time; dismissal allows another attempt without success toast',
      (WidgetTester tester) async {
    int downloads = 0;
    int shares = 0;
    final Completer<void> dismissed = Completer<void>();
    await pumpPage(
        tester,
        VisitorDetailPage(
          loader: (_) async => visitor,
          shareSupported: true,
          previewBuilder: (_) => Image.memory(passImage),
          imageLoader: (_) async {
            downloads++;
            return passImage;
          },
          sharer: (_, {Rect? anchor}) {
            shares++;
            return dismissed.future;
          },
        ),
        arguments: 'test');
    final VoidCallback share = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '分享通行码'))
        .onPressed!;
    share();
    share();
    await tester.pump();
    expect(downloads, 1);
    expect(shares, 1);
    expect(find.text('正在分享…'), findsOneWidget);
    dismissed.complete();
    await tester.pumpAndSettle();
    expect(find.text('分享成功'), findsNothing);
    expect(find.text('发送成功'), findsNothing);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '分享通行码'))
            .onPressed,
        isNotNull);
    await finishPage(tester);
  });

  testWidgets('download failure can retry without opening native share',
      (WidgetTester tester) async {
    int downloads = 0;
    int shares = 0;
    await pumpPage(
        tester,
        VisitorDetailPage(
          loader: (_) async => visitor,
          shareSupported: true,
          previewBuilder: (_) => Image.memory(passImage),
          imageLoader: (_) async {
            downloads++;
            if (downloads == 1) throw const NetworkException('测试下载失败');
            return passImage;
          },
          sharer: (_, {Rect? anchor}) async {
            shares++;
          },
        ),
        arguments: 'test');
    await tester.tap(find.text('分享通行码'));
    await tester.pumpAndSettle();
    expect(shares, 0);
    await tester.tap(find.text('分享通行码'));
    await tester.pumpAndSettle();
    expect(shares, 1);
    expect(downloads, 2);
    await finishPage(tester);
  });

  testWidgets('leaving during download never opens share over the next page',
      (WidgetTester tester) async {
    final Completer<Uint8List> image = Completer<Uint8List>();
    int shares = 0;
    await pumpPage(tester, const Scaffold(body: Text('其他页面')),
        routes: <String, WidgetBuilder>{
          VisitorDetailPage.routeName: (_) => VisitorDetailPage(
                loader: (_) async => visitor,
                shareSupported: true,
                previewBuilder: (_) => Image.memory(passImage),
                imageLoader: (_) => image.future,
                sharer: (_, {Rect? anchor}) async {
                  shares++;
                },
              ),
        });
    unawaited(GlobalVariable.navigatorKey.currentState!
        .pushNamed<void>(VisitorDetailPage.routeName, arguments: 'test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分享通行码'));
    await tester.pump();
    GlobalVariable.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    image.complete(passImage);
    await tester.pumpAndSettle();
    expect(shares, 0);
    expect(tester.takeException(), isNull);
    await finishPage(tester);
  });

  testWidgets('expired record and unsupported platform disable sharing',
      (WidgetTester tester) async {
    for (final bool supported in <bool>[true, false]) {
      await pumpPage(
          tester,
          VisitorDetailPage(
            loader: (_) async => supported
                ? const VisitorRecord(
                    status: 3, url: 'https://example.invalid/expired.png')
                : visitor,
            shareSupported: supported,
            previewBuilder: (_) => Image.memory(passImage),
          ),
          arguments: 'test');
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '分享通行码'))
              .onPressed,
          isNull);
      await finishPage(tester);
    }
  });
}
