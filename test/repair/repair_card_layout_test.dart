import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import '../helpers/widget_harness.dart';

void main() {
  testWidgets(
      'repair card grows for long content on a narrow screen with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const title = '厨房与卫生间多处水管接头漏水检查维修服务';
    const time = '等待物业联系住户协商合适的上门时间';
    await pumpPage(
        tester,
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: RepairListPage(
              loadRepairs: () async => const <RepairRecord>[
                    RepairRecord(
                        id: 'long',
                        repairItemName: title,
                        appointment: time,
                        mobile: '13800138000',
                        status: 6),
                  ]),
        ));
    expect(find.text(title), findsOneWidget);
    expect(find.text(time), findsOneWidget);
    expect(find.text('13800138000'), findsOneWidget);
    final card = tester.getRect(find.byType(Card));
    final phone = tester.getRect(find.text('13800138000'));
    expect(card.contains(phone.bottomRight), isTrue);
    expect(card.height, greaterThan(140));
    expect(tester.takeException(), isNull);
    await finishPage(tester);
  });

  testWidgets(
      'repair cards navigate with the matching id and disable missing ids',
      (tester) async {
    String? openedId;
    await pumpPage(
        tester,
        RepairListPage(
            loadRepairs: () async => const <RepairRecord>[
                  RepairRecord(
                      repairItemName: '无编号工单',
                      appointment: '待定',
                      mobile: '13800138000'),
                  RepairRecord(
                      id: 'repair-2',
                      repairItemName: '可打开工单',
                      appointment: '待定',
                      mobile: '13800138000'),
                ]),
        routes: <String, WidgetBuilder>{
          RepairDetailPage.routeName: (context) {
            openedId = ModalRoute.of(context)!.settings.arguments as String;
            return const Scaffold(body: Text('工单详情测试'));
          }
        });
    await tester.tap(find.text('无编号工单'));
    await tester.pumpAndSettle();
    expect(openedId, isNull);
    await tester.tap(find.text('可打开工单'));
    await tester.pumpAndSettle();
    expect(openedId, 'repair-2');
    expect(find.text('工单详情测试'), findsOneWidget);
    await finishPage(tester);
  });
}
