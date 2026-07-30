import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:haven_hub/pages/House/HouseList.dart';
import 'package:haven_hub/pages/House/components/HouseItem.dart';
import 'package:haven_hub/pages/home/components/home_nav.dart';
import 'package:haven_hub/pages/mine/index.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    Get.reset();
  });

  testWidgets('房屋列表渲染接口字段和审核状态', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HouseList(
          houseListLoader: () async {
            return <Map<String, dynamic>>[
              <String, dynamic>{
                'point': '万达广场(成都锦城店)',
                'building': '1栋',
                'room': '204',
                'name': '张三',
                'status': 1,
              },
              <String, dynamic>{
                'point': '仙基公寓',
                'building': '3号楼',
                'room': '303',
                'name': '李四',
                'status': 2,
              },
              <String, dynamic>{
                'point': '瑞光明小区',
                'building': '2单元',
                'room': '501',
                'name': '王五',
                'status': 3,
              },
            ];
          },
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('万达广场(成都锦城店)'), findsOneWidget);
    expect(find.text('1栋204'), findsOneWidget);
    expect(find.text('张三'), findsOneWidget);
    expect(find.text('审核中'), findsOneWidget);
    expect(find.text('审核成功'), findsOneWidget);

    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('审核失败'), findsOneWidget);
  });

  testWidgets('接口失败后显示错误并可以重新加载', (
    WidgetTester tester,
  ) async {
    int loadCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: HouseList(
          houseListLoader: () async {
            loadCount++;
            if (loadCount == 1) {
              throw const FormatException('房屋列表数据格式不正确');
            }
            return <Map<String, dynamic>>[
              <String, dynamic>{
                'point': '仙基公寓',
                'building': '1栋',
                'room': '2003室',
                'name': '张继科',
                'status': 2,
              },
            ];
          },
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    expect(find.text('房屋列表数据格式不正确'), findsWidgets);
    expect(find.text('重新加载'), findsOneWidget);

    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();

    expect(loadCount, 2);
    expect(find.text('仙基公寓'), findsOneWidget);
    expect(find.text('审核成功'), findsOneWidget);
  });

  testWidgets('首页我的房屋入口跳转到房屋列表路由', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(body: HomeNav()),
        routes: <String, WidgetBuilder>{
          HouseList.routeName: (_) => const Scaffold(
                body: Text('房屋列表路由'),
              ),
        },
      ),
    );

    await tester.tap(find.text('我的房屋'));
    await tester.pumpAndSettle();

    expect(find.text('房屋列表路由'), findsOneWidget);
  });

  testWidgets('我的页面房屋入口跳转到房屋列表路由', (
    WidgetTester tester,
  ) async {
    Get.testMode = true;

    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(body: MinePage()),
        routes: <String, WidgetBuilder>{
          HouseList.routeName: (_) => const Scaffold(
                body: Text('房屋列表路由'),
              ),
        },
      ),
    );

    await tester.tap(find.text('我的房屋'));
    await tester.pumpAndSettle();

    expect(find.text('房屋列表路由'), findsOneWidget);
  });

  test('房屋状态枚举文案符合接口约定', () {
    expect(getStatusText(1), '审核中');
    expect(getStatusText(2), '审核成功');
    expect(getStatusText(3), '审核失败');
    expect(getStatusText(99), '未知状态');
  });
}
