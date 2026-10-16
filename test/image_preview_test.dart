import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/widgets/image_preview.dart';

void main() {
  testWidgets('photo preview zooms, pans, resets and closes',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (BuildContext context) {
        return TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const ImagePreview(
              child: SizedBox(width: 200, height: 400),
            ),
          ),
          child: const Text('查看照片'),
        );
      }),
    ));
    await tester.tap(find.text('查看照片'));
    await tester.pumpAndSettle();
    final InteractiveViewer viewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final TransformationController controller = viewer.transformationController!;
    expect(controller.value.getMaxScaleOnAxis(), 1);

    await tester.tap(find.byTooltip('放大'));
    await tester.pump();
    expect(controller.value.getMaxScaleOnAxis(), 1.5);
    final double previousX = controller.value.storage[12];
    await tester.drag(find.byType(InteractiveViewer), const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(controller.value.storage[12], greaterThan(previousX));

    await tester.tap(find.byTooltip('适应屏幕'));
    await tester.pump();
    expect(controller.value, Matrix4.identity());
    await tester.tap(find.byTooltip('缩小'));
    await tester.pump();
    expect(controller.value.getMaxScaleOnAxis(), 1);
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    expect(find.byType(ImagePreview), findsNothing);
    expect(find.text('查看照片'), findsOneWidget);
  });
}
