import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/worker.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/worker/worker_pages.dart';
import 'package:haven_hub/pages/worker/worker_pool_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/widget_harness.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();
  });
  testWidgets('pool lists limited location, pending time and server claim conflict', (tester) async {
    const row = RepairRecord(id: 'pool', revision: 3, repairItemName: '水暖维修', houseInfo: '测试小区 1栋',
      description: '漏水', slot: '2030-10-20#10', agreedTime: '2030-10-20T10:00:00+08:00');
    var calls = 0;
    await pumpPage(tester, WorkerPoolPage(loader: () async => <RepairRecord>[row], claim: (record, {slot}) async {
      calls++; throw const BusinessException('已被其他师傅接走');
    }));
    expect(find.text('测试小区 1栋'), findsOneWidget);
    await tester.tap(find.text('接单')); await tester.pumpAndSettle();
    expect(calls, 1); expect(find.text('已被其他师傅接走'), findsOneWidget);
    await finishPage(tester);
  });
  testWidgets('skills deletion previews before saving and cancellation leaves skills unchanged', (tester) async {
    final calls = <bool>[];
    await pumpPage(tester, WorkerSkillsPage(loader: () async => const WorkerSkills(<String>['plumbing','doors'], 2),
      saver: (profile, values, {preview = false}) async {
        calls.add(preview);
        return <String,dynamic>{'returned': <dynamic>[<String,dynamic>{'id':'repair-1','repairItemName':'水暖维修','slot':'2030-10-20#10',
          'start':'2030-10-20T10:00:00+08:00','end':'2030-10-20T11:00:00+08:00'}], 'property': <dynamic>[]};
      }));
    await tester.tap(find.text('水暖')); await tester.tap(find.text('保存技能')); await tester.pump(); await tester.pump(const Duration(milliseconds: 400));
    expect(calls, <bool>[true]); expect(find.text('删除技能的影响'), findsOneWidget);
    expect(find.textContaining('10-20 10:00–11:00'), findsOneWidget);
    expect(find.textContaining('repair-1'), findsNothing);
    expect(find.textContaining('2030-10-20#10'), findsNothing);
    await tester.tap(find.text('取消')); await tester.pumpAndSettle(); expect(calls, <bool>[true]);
    await finishPage(tester);
  });
  testWidgets('skills preview confirmation saves once with original revision', (tester) async {
    final calls = <bool>[];
    await pumpPage(tester, WorkerSkillsPage(loader: () async => const WorkerSkills(<String>['plumbing','doors'], 8),
      saver: (profile, values, {preview = false}) async {
        expect(profile.revision, 8); expect(values, <String>['doors']); calls.add(preview);
        return preview ? <String,dynamic>{'returned': <dynamic>[], 'property': <dynamic>[]}
          : <String,dynamic>{'skills': values, 'workforceRevision': 9};
      }));
    await tester.tap(find.text('水暖')); await tester.tap(find.text('保存技能')); await tester.pump(); await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('确认保存')); await tester.pumpAndSettle(); expect(calls, <bool>[true,false]);
    await finishPage(tester);
  });
  testWidgets('skills preview shows shortage window and pending time without raw ids or slots', (tester) async {
    final returned=<String,dynamic>{'id':'hidden-returned-id','repairItemName':'水暖维修','slot':'2030-10-18#10',
      'start':'2030-10-18T10:00:00+08:00','end':'2030-10-18T11:00:00+08:00'};
    await pumpPage(tester, WorkerSkillsPage(loader: () async => const WorkerSkills(<String>['plumbing'], 2),
      saver: (profile, values, {preview = false}) async => <String,dynamic>{
        'returned':<dynamic>[returned],
        'property':<dynamic>[<String,dynamic>{'id':'hidden-pending-id','repairItemName':'电气维修','start':'','end':''}],
        'shortages':<dynamic>[<String,dynamic>{'message':'2 张单只有 1 位师傅能接，可能有 1 张需要物业安排','orders':<dynamic>[returned]}],
      }));
    await tester.tap(find.text('水暖')); await tester.tap(find.text('保存技能'));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('水暖维修 · 10-18 10:00–11:00'),findsOneWidget);
    expect(find.textContaining('电气维修 · 待定'),findsOneWidget);
    expect(find.textContaining('可能有 1 张需要物业安排'),findsOneWidget);
    expect(find.textContaining('hidden-'),findsNothing);expect(find.textContaining('2030-10-18#10'),findsNothing);
    await tester.tap(find.text('取消'));await tester.pumpAndSettle();await finishPage(tester);
  });
  testWidgets('pool discards response after account switch', (tester) async {
    final response = Completer<List<RepairRecord>>();
    await tester.pumpWidget(MaterialApp(home: WorkerPoolPage(loader: () => response.future)));
    await tester.pump(); tokenManager.invalidateLocalSession();
    response.complete(<RepairRecord>[const RepairRecord(id:'old',repairItemName:'旧账号工单')]);
    await tester.pump(); expect(find.text('旧账号工单'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('empty skills shows registration hint on worker home', (tester) async {
    await pumpPage(tester, WorkerPage(recordsLoader: () async => <RepairRecord>[],
      skillsLoader: () async => const WorkerSkills(<String>[], 0)));
    expect(find.text('请先登记你会的维修技能，登记后才能接新单'), findsOneWidget);
    expect(find.text('可接单'), findsOneWidget); expect(find.text('我的技能'), findsOneWidget);
    await finishPage(tester);
  });
}
