import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/main.dart';
import 'package:haven_hub/pages/home/components/home_nav.dart';
import 'package:haven_hub/pages/home/components/home_nav_item.dart';
import 'package:haven_hub/pages/home/components/notify_item.dart';

Future<List<Map<String, dynamic>>> _offlineAnnouncementLoader() {
  return Future<List<Map<String, dynamic>>>.error(
    Exception('测试环境不发起真实网络请求'),
  );
}

void main() {
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
    expect(find.byType(NotifyItem), findsNWidgets(3));

    final ListView noticeList = tester.widget<ListView>(find.byType(ListView));
    expect(noticeList.shrinkWrap, isTrue);
    expect(noticeList.physics, isA<NeverScrollableScrollPhysics>());
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
}
