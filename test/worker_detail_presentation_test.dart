import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/worker.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/worker/worker_pages.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/widgets/cached_image.dart';
import 'package:haven_hub/widgets/image_preview.dart';
import 'package:haven_hub/widgets/repair_photos.dart';
import 'package:haven_hub/widgets/repair_progress.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/widget_harness.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();
  });

  test('worker API rejects empty and whitespace completion results', () async {
    for (final result in ['', '   \n  ']) {
      await expectLater(
        processWorkerRepairApi(const RepairRecord(status: 2),
            complete: true, result: result),
        throwsA(isA<FormatException>()),
      );
    }
  });

  for (final width in <double>[360, 800, 1800]) {
    testWidgets('eight photos keep square frames and wrap at width $width',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.ohos;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: RepairPhotos(
                      urls: List.generate(
                          8, (i) => 'https://example.invalid/$i.png'))))));
      await tester.pump(const Duration(milliseconds: 100));
      final rects = List.generate(
          8, (i) => tester.getRect(find.byKey(ValueKey('repair-photo-$i'))));
      for (final rect in rects) {
        expect(rect.width, greaterThanOrEqualTo(100));
        expect(rect.height, rect.width);
      }
      final firstRow = rects.where((r) => r.top == rects.first.top).length;
      expect(firstRow, inInclusiveRange(2, 4));
      expect(rects.last.top, greaterThan(rects.first.top));
      expect(find.text('现场照片（8张）'), findsOneWidget);
      for (final image
          in tester.widgetList<CachedImage>(find.byType(CachedImage))) {
        expect(image.fit, BoxFit.cover);
      }
      await tester.tap(find.byKey(const ValueKey('repair-photo-0')));
      await tester.pump(const Duration(milliseconds: 400));
      final previewImage = find.descendant(
          of: find.byType(ImagePreview), matching: find.byType(CachedImage));
      expect(tester.widget<CachedImage>(previewImage).fit, BoxFit.contain);
      await tester.tap(find.byTooltip('关闭预览'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      await finishPage(tester);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  for (final width in <double>[320, 1800]) {
    testWidgets('progress remains compact across statuses at width $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final status in [1, 5, 2, 3, 4, -1]) {
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(
                    child: RepairProgress(
                        record: RepairRecord(
                            status: status, workflowVersion: 1))))));
        expect(tester.getSize(find.byType(Card)).width, lessThanOrEqualTo(760));
        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.radio_button_checked), findsNothing);
        expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
        expect(find.byIcon(Icons.check_circle), findsNothing);
        expect(
            find.text(
                RepairRecord(status: status, workflowVersion: 1).statusText),
            findsOneWidget);
      }
      await finishPage(tester);
    });
  }

  testWidgets(
      'blank result is blocked; valid result submits once and returns to workbench',
      (tester) async {
    int calls = 0;
    final response = Completer<RepairRecord>();
    await pumpPage(tester, const Scaffold(body: Text('测试工作台')),
        routes: <String, WidgetBuilder>{
      '/worker-test': (_) => WorkerDetailPage(
          id: 'repair',
          recordLoader: (_) async => const RepairRecord(
              id: 'repair', status: 2, repairItemName: '水电维修'),
          processor: (record, {required complete, String result = ''}) {
            calls++;
            expect(complete, isTrue);
            expect(result, '已更换水管，试水正常');
            return response.future;
          },
        ),
    });
    unawaited(GlobalVariable.navigatorKey.currentState!.pushNamed<void>('/worker-test'));
    await tester.pumpAndSettle();
    expect(find.text('修了什么（必填）'), findsOneWidget);
    await tester.tap(find.text('提交完工'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('请填写处理结果后再完成维修'), findsWidgets);
    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.tap(find.text('提交完工'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.enterText(find.byType(TextField).first, ' 已更换水管，试水正常 ');
    await tester.tap(find.text('提交完工'));
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    response.complete(const RepairRecord(
        id: 'repair', status: 6, completionNote: '已更换水管，试水正常'));
    await tester.pumpAndSettle();
    expect(find.text('测试工作台'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    await finishPage(tester);
  });

  testWidgets('acceptance does not require a completion result',
      (tester) async {
    int calls = 0;
    await pumpPage(
        tester,
        WorkerDetailPage(
          id: 'repair',
          recordLoader: (_) async =>
              const RepairRecord(id: 'repair', status: 5),
          processor: (record, {required complete, String result = ''}) async {
            calls++;
            expect(complete, isFalse);
            return const RepairRecord(id: 'repair', status: 2);
          },
        ));
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('接单'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('修了什么（必填）'), findsOneWidget);
    await finishPage(tester);
  });
}
