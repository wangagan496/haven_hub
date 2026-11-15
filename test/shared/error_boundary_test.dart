import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/widgets/error_boundary.dart';

class _ThrowingChild extends StatelessWidget {
  const _ThrowingChild({required this.shouldThrow});

  final bool shouldThrow;

  @override
  Widget build(BuildContext context) {
    if (shouldThrow) {
      throw StateError('boom');
    }
    return const Text('已恢复');
  }
}

void main() {
  testWidgets('retry rebuilds the subtree instead of showing the same error',
      (WidgetTester tester) async {
    bool shouldThrow = true;

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          return Column(
            children: <Widget>[
              TextButton(
                onPressed: () => setState(() => shouldThrow = false),
                child: const Text('停止抛错'),
              ),
              ErrorBoundary(
                child: _ThrowingChild(shouldThrow: shouldThrow),
              ),
            ],
          );
        },
      ),
    ));

    // 子组件在构建中抛错，错误边界接管并展示错误界面。
    expect(tester.takeException(), isA<StateError>());
    await tester.pumpAndSettle();
    expect(find.text('页面加载失败'), findsOneWidget);

    // 让子组件下一次构建不再抛错，再点重试。
    await tester.tap(find.text('停止抛错'));
    await tester.pumpAndSettle();
    expect(find.text('页面加载失败'), findsOneWidget,
        reason: '错误界面不参与子组件的重新构建');

    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();

    // 重试必须真的重建子树；只清空错误状态而不重建时，这里仍然停在错误界面。
    expect(find.text('已恢复'), findsOneWidget);
    expect(find.text('页面加载失败'), findsNothing);
  });

  testWidgets('restores the previous ErrorWidget builder on dispose',
      (WidgetTester tester) async {
    final ErrorWidgetBuilder original = ErrorWidget.builder;

    await tester.pumpWidget(const MaterialApp(
      home: ErrorBoundary(child: Text('正常内容')),
    ));
    expect(find.text('正常内容'), findsOneWidget);

    // 卸载后全局构建器要还原，否则这个定制会泄漏到后续所有页面。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(identical(ErrorWidget.builder, original), isTrue);
  });
}
