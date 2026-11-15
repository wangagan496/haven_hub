import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/models/user_info.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/repair_draft_store.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/widget_harness.dart';
import 'repair_slots_fixture.dart';
import 'repair_test_helpers.dart' show fillRepair;

const _record = RepairRecord(
    houseId: 'house-test',
    repairItemId: 'item-test',
    mobile: '13800138000',
    description: '上次提交内容');

class _UnavailableStore extends RepairDraftStore {
  @override
  Future<bool> save(String userKey, RepairDraft draft,
          {String? expectedSubmissionId}) async =>
      false;
}

RepairFormPage _form(
  RepairDraftStore store, {
  required Future<dynamic> Function(RepairRecord) submitter,
  Future<String?> Function(String)? lookup,
  Future<String?> Function(String)? closer,
  String Function()? owner,
}) =>
    RepairFormPage(
      houseLoader: () async => const <House>[
        House(id: 'house-test', point: '测试小区', building: '1栋', room: '101')
      ],
      itemLoader: () async =>
          const <RepairItem>[RepairItem(id: 'item-test', name: '水管维修')],
      userInfoLoader: () async => const UserInfo.empty(),
      slotsLoader: loadSlotsFixture,
      draftStore: store,
      draftUserKey: owner ?? () => 'a',
      submitter: submitter,
      submissionLoader: lookup ?? (_) async => null,
      submissionCloser: closer ?? (_) async => null,
    );

Future<RepairRecord> _seed(RepairDraftStore store) async {
  final RepairRecord pending = RepairDraft.prepareSubmission(_record);
  await store.save(
      'a',
      RepairDraft(
          record: _record,
          waitingSchedule: true,
          resultUnconfirmed: true,
          submission: pending));
  return pending;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.loadTokens();
  });
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('submission snapshot survives a new store, edits and account isolation',
      () async {
    final store = RepairDraftStore();
    final pending = await _seed(store);
    await store.save(
        'a',
        RepairDraft(
            record: const RepairRecord(description: '新输入'),
            submission: pending));
    final recovered = await RepairDraftStore().load('a');
    expect(recovered!.record.description, '新输入');
    expect(recovered.submission!.toJson(), pending.toJson());
    expect(recovered.resultUnconfirmed, isTrue);
    expect(await store.load('b'), isNull);
    expect(RepairDraft.prepareSubmission(_record).submissionId,
        isNot(pending.submissionId));
  });

  test(
      'corrupt persisted draft is not treated as empty and is never overwritten',
      () async {
    final preferences = await SharedPreferences.getInstance();
    const key = 'repairDraft:v1:a:new';
    for (final raw in <String>['{broken', '[]', '{"record":null}']) {
      await preferences.setString(key, raw);
      await expectLater(RepairDraftStore().load('a'), throwsFormatException);
      expect(preferences.getString(key), raw);
    }
  });

  testWidgets('receipt must be persisted before a network create is sent',
      (tester) async {
    int requests = 0;
    await pumpPage(
        tester,
        _form(_UnavailableStore(), submitter: (_) async {
          requests++;
        }));
    await fillRepair(tester);
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.text('水管漏水'), findsOneWidget);
    expect(find.text('提交回执未能保存，本次尚未发送，请重试'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets(
      'corrupted draft shows a discard entry and cancel keeps the raw record',
      (tester) async {
    const String key = 'repairDraft:v1:a:new';
    SharedPreferences.setMockInitialValues(
        <String, Object>{key: '{invalid json'});
    await pumpPage(tester, _form(RepairDraftStore(), submitter: (_) async {}));
    expect(find.text('本机报修草稿已损坏，可能包含未确认的提交回执；请先处理这条记录。'), findsOneWidget);
    await tester.tap(find.text('丢弃损坏草稿'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, '丢弃损坏草稿'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await SharedPreferences.getInstance()).getString(key),
        '{invalid json');
    await finishPage(tester);
  });

  testWidgets('confirming corrupted draft discard enables a fresh submission',
      (tester) async {
    const String key = 'repairDraft:v1:a:new';
    SharedPreferences.setMockInitialValues(
        <String, Object>{key: '{invalid json'});
    int requests = 0;
    await pumpPage(
        tester,
        _form(RepairDraftStore(), submitter: (_) async {
          requests++;
        }));
    await tester.tap(find.text('丢弃损坏草稿'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认丢弃'));
    await tester.pumpAndSettle();
    expect(find.text('本机报修草稿已损坏，可能包含未确认的提交回执；请先处理这条记录。'), findsNothing);
    expect((await SharedPreferences.getInstance()).getString(key), isNull);
    await fillRepair(tester);
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(requests, 1);
    await finishPage(tester);
  });

  testWidgets(
      'another form receipt is preserved and the current form offers result lookup',
      (tester) async {
    final first = RepairDraftStore();
    final second = RepairDraftStore();
    int requests = 0;
    await pumpPage(
        tester,
        _form(second, submitter: (_) async {
          requests++;
        }));
    await fillRepair(tester);
    final sent = await _seed(first);
    await tester.enterText(find.byType(TextFormField).last, '第二份表单修改');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('已有一条待确认的报修，请先处理提交回执；当前表单没有覆盖它。'), findsOneWidget);
    expect(find.text('查看提交结果'), findsOneWidget);
    expect(requests, 0);
    expect(
        (await first.load('a'))!.submission!.submissionId, sent.submissionId);
    await finishPage(tester);
  });

  testWidgets(
      'lost response retains receipt and lookup opens original order without resubmission',
      (tester) async {
    final store = RepairDraftStore();
    int requests = 0;
    String sentId = '';
    await pumpPage(
        tester,
        _form(store, submitter: (record) async {
          requests++;
          sentId = record.submissionId;
          expect((await store.load('a'))!.submission!.submissionId, sentId);
          throw const NetworkException('响应丢失', isTimeout: true);
        }, lookup: (id) async {
          expect(id, sentId);
          return 'original-order';
        }),
        routes: {
          RepairDetailPage.routeName: (context) => Scaffold(
              body: Text('详情:${ModalRoute.of(context)!.settings.arguments}')),
        });
    await fillRepair(tester);
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(sentId, isNotEmpty);
    await tester.ensureVisible(find.text('查看提交结果'));
    await tester.tap(find.text('查看提交结果'));
    await tester.pumpAndSettle();
    expect(find.text('详情:original-order'), findsOneWidget);
    expect(requests, 1);
    expect(await store.load('a'), isNull);
    await finishPage(tester);
  });

  testWidgets(
      'explicit retry uses original snapshot and key even after input changes',
      (tester) async {
    final store = RepairDraftStore();
    final pending = await _seed(store);
    final requests = <RepairRecord>[];
    await pumpPage(
        tester,
        _form(store, submitter: (record) async {
          requests.add(record);
          throw const NetworkException('仍未收到响应', isTimeout: true);
        }));
    await tester.enterText(find.byType(TextFormField).last, '后来修改的内容');
    await tester.ensureVisible(find.text('提交报修'));
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    await tester.tap(find.text('确认重试'));
    await tester.pumpAndSettle();
    expect(requests.single.toJson(), pending.toJson());
    expect((await store.load('a'))!.submission!.toJson(), pending.toJson());
    expect(find.text('后来修改的内容'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets(
      'unknown lookup does not claim failure and cancellation sends no create',
      (tester) async {
    final store = RepairDraftStore();
    final pending = await _seed(store);
    int requests = 0;
    await pumpPage(
        tester,
        _form(store, submitter: (_) async {
          requests++;
        }));
    await tester.tap(find.text('查看提交结果'));
    await tester.pumpAndSettle();
    expect(find.textContaining('原请求可能仍在处理'), findsOneWidget);
    expect(requests, 0);
    await tester.ensureVisible(find.text('提交报修'));
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('先不提交'));
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect((await store.load('a'))!.submission!.submissionId,
        pending.submissionId);
    await finishPage(tester);
  });

  testWidgets(
      'account switch ignores late receipt result and preserves both owners drafts',
      (tester) async {
    final store = RepairDraftStore();
    await _seed(store);
    await store.save(
        'b', const RepairDraft(record: RepairRecord(description: 'B的草稿')));
    String owner = 'a';
    final result = Completer<String?>();
    await pumpPage(
        tester,
        _form(store,
            owner: () => owner,
            submitter: (_) async => fail('must not send'),
            lookup: (_) => result.future));
    await tester.tap(find.text('查看提交结果'));
    await tester.pump();
    owner = 'b';
    result.complete('original-order');
    await tester.pumpAndSettle();
    expect(find.text('新增报修'), findsOneWidget);
    expect((await store.load('a'))!.submission, isNotNull);
    expect((await store.load('b'))!.record.description, 'B的草稿');
    await finishPage(tester);
  });

  testWidgets(
      'confirmed stop clears only the receipt after server fencing and keeps entered content',
      (tester) async {
    final store = RepairDraftStore();
    final pending = await _seed(store);
    String closed = '';
    await pumpPage(
        tester,
        _form(store,
            submitter: (_) async => fail('must not create'),
            closer: (id) async {
              closed = id;
              return null;
            }));
    await tester.tap(find.text('停止本次提交'));
    await tester.pumpAndSettle();
    expect(closed, isEmpty);
    await tester.tap(find.text('确认停止'));
    await tester.pumpAndSettle();
    expect(closed, pending.submissionId);
    final draft = (await store.load('a'))!;
    expect(draft.submission, isNull);
    expect(draft.resultUnconfirmed, isFalse);
    expect(draft.record.description, '上次提交内容');
    expect(find.text('查看提交结果'), findsNothing);
    await finishPage(tester);
  });
}
