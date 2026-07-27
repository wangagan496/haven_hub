import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:haven_hub/main.dart';
import 'package:haven_hub/pages/home/components/home_list.dart';
import 'package:haven_hub/pages/home/components/home_nav.dart';
import 'package:haven_hub/pages/home/components/home_nav_item.dart';
import 'package:haven_hub/pages/home/components/notify_item.dart';

Future<List<Map<String, dynamic>>> _offlineAnnouncementLoader() {
  return Future<List<Map<String, dynamic>>>.error(
    Exception('测试环境不发起真实网络请求'),
  );
}

Future<List<Map<String, dynamic>>> _successfulAnnouncementLoader() async {
  return <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'notice-1',
      'title': '接口返回的社区公告',
      'content': '这是从父组件传递到 HomeList 的公告内容。',
      'createdAt': '2026-07-27T12:00:00.000Z',
    },
  ];
}

Future<Map<String, dynamic>> _successfulAnnouncementDetailLoader(
  String id,
) async {
  return <String, dynamic>{
    'id': id,
    'title': '社区公告详情',
    'content': '<p>这是根据公告 ID 获取的详情内容。</p>'
        '<p><strong>温馨提示</strong></p>',
    'createdAt': '2026-07-27T13:30:00.000Z',
    'creatorName': '社区管理员',
  };
}

void main() {
  test('公告时间兼容无毫秒的 ISO 格式', () {
    final NoticeData notice = NoticeData.fromJson(
      <String, dynamic>{
        'createdAt': '2026-07-27T12:00:00Z',
      },
    );

    expect(notice.date, '2026-07-27 12:00:00');
  });

  testWidgets('首页显示快捷导航和社区公告列表', (WidgetTester tester) async {
    await tester.pumpWidget(
      const HavenHubApp(announcementLoader: _offlineAnnouncementLoader),
    );

    expect(find.byType(HomeNav), findsOneWidget);
    expect(find.byType(HomeNavItem), findsNWidgets(3));
    expect(find.text('我的房屋'), findsOneWidget);
    expect(find.text('我的报修'), findsOneWidget);
    expect(find.text('访客登记'), findsOneWidget);

    expect(find.text('社区'), findsOneWidget);
    expect(find.text('公告'), findsOneWidget);
    expect(find.byType(HomeList), findsOneWidget);
    expect(find.byType(NotifyItem), findsNWidgets(3));

    final ListView noticeList = tester.widget<ListView>(find.byType(ListView));
    expect(noticeList.shrinkWrap, isTrue);
    expect(noticeList.physics, isA<NeverScrollableScrollPhysics>());

    await tester.tap(find.byType(NotifyItem).first);
    await tester.pumpAndSettle();
    expect(find.text('享+社区'), findsOneWidget);
    expect(find.text('公告详情'), findsNothing);
  });

  testWidgets('IndexedStack 根据底部导航索引切换页面', (WidgetTester tester) async {
    await tester.pumpWidget(
      const HavenHubApp(announcementLoader: _offlineAnnouncementLoader),
    );

    expect(find.byType(BottomNavigationBar), findsOneWidget);
    expect(find.byType(IndexedStack), findsOneWidget);
    expect(find.text('享+社区'), findsOneWidget);
    expect(find.text('用户名'), findsNothing);

    await tester.tap(find.text('我的'));
    await tester.pump();

    expect(find.text('享+社区'), findsNothing);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('去完善信息'), findsOneWidget);
    expect(find.text('我的房屋'), findsOneWidget);
    expect(find.text('我的报修'), findsOneWidget);
    expect(find.text('访客记录'), findsOneWidget);

    final BottomNavigationBar navigationBar =
        tester.widget<BottomNavigationBar>(find.byType(BottomNavigationBar));
    expect(navigationBar.currentIndex, 1);
  });

  testWidgets('接口数据通过 HomeList 传递给 NotifyItem 渲染', (WidgetTester tester) async {
    const MethodChannel toastChannel =
        MethodChannel('PonnamKarthik/fluttertoast');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            toastChannel, (MethodCall call) async => true);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(toastChannel, null);
    });

    await tester.pumpWidget(
      const HavenHubApp(announcementLoader: _successfulAnnouncementLoader),
    );
    await tester.pump();

    expect(find.byType(HomeList), findsOneWidget);
    expect(find.byType(NotifyItem), findsOneWidget);
    expect(find.text('接口返回的社区公告'), findsOneWidget);
    expect(find.text('这是从父组件传递到 HomeList 的公告内容。'), findsOneWidget);
    expect(find.text('2026-07-27 12:00:00'), findsOneWidget);
  });

  testWidgets('点击公告携带 id 跳转并获取详情', (WidgetTester tester) async {
    const MethodChannel toastChannel =
        MethodChannel('PonnamKarthik/fluttertoast');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      toastChannel,
      (MethodCall call) async => true,
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(toastChannel, null);
    });

    String? requestedId;
    Future<Map<String, dynamic>> detailLoader(String id) {
      requestedId = id;
      return _successfulAnnouncementDetailLoader(id);
    }

    await tester.pumpWidget(
      HavenHubApp(
        announcementLoader: _successfulAnnouncementLoader,
        announcementDetailLoader: detailLoader,
      ),
    );
    await tester.pump();

    await tester.tap(find.byType(NotifyItem));
    await tester.pumpAndSettle();

    expect(requestedId, 'notice-1');
    expect(find.text('公告详情'), findsOneWidget);
    expect(find.text('社区公告详情'), findsOneWidget);
    expect(find.byType(Html), findsOneWidget);
    expect(find.text('这是根据公告 ID 获取的详情内容。'), findsOneWidget);
    expect(find.text('温馨提示'), findsOneWidget);
    expect(find.text('社区管理员'), findsOneWidget);
    expect(find.text('2026-07-27 13:30:00'), findsOneWidget);
  });
}
