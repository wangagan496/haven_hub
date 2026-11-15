import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/house.dart';
import 'package:haven_hub/api/user.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/models/user_info.dart';
import 'package:haven_hub/models/visitor.dart';
import 'package:haven_hub/pages/visitor/visitor_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/submission_id.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/utils/visitor_submission_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/widget_harness.dart';

const _record = VisitorRecord(
    houseId: 'house-test',
    houseInfo: '测试小区 1栋 101',
    name: '访客甲',
    mobile: '13800138000',
    visitDate: '2030-10-28');
const _unknown = VisitorSubmissionResult(VisitorSubmissionState.unknown);
const _closed = VisitorSubmissionResult(VisitorSubmissionState.closed);
const _created = VisitorSubmissionResult(VisitorSubmissionState.created,
    createdId: 'visitor-original');

class _UnavailableStore extends VisitorSubmissionStore {
  @override
  Future<bool> save(String owner, VisitorRecord record) async => false;
}

class _RemoveOnceFailsStore extends VisitorSubmissionStore {
  bool fail = true;
  @override
  Future<bool> remove(String owner, String submissionId) =>
      fail ? Future.value(false) : super.remove(owner, submissionId);
}

VisitorFormPage _form(
  VisitorSubmissionStore store, {
  required Future<void> Function(VisitorRecord) send,
  Future<VisitorSubmissionResult> Function(String)? lookup,
  Future<VisitorSubmissionResult> Function(String)? close,
  UserInfoLoader? identity,
  HouseListLoader? houses,
}) =>
    VisitorFormPage(
      submissionStore: store,
      userInfoLoader: identity ??
          () async =>
              const UserInfo(id: 'owner-a', avatarUrl: '', nickName: '测试账号'),
      houseLoader: houses ??
          () async => const <House>[
                House(
                    id: 'house-test',
                    point: '测试小区',
                    building: '1栋',
                    room: '101')
              ],
      submitter: send,
      submissionLoader: lookup ?? (_) async => _unknown,
      submissionCloser: close ?? (_) async => _closed,
    );

Future<VisitorRecord> _seed(VisitorSubmissionStore store,
    {String owner = 'owner-a'}) async {
  final pending = VisitorSubmissionStore.prepare(_record);
  await store.save(owner, pending);
  return pending;
}

Future<void> _open(WidgetTester tester, VisitorFormPage form) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await pumpPage(
      tester,
      Builder(
          builder: (context) => Scaffold(
                  body: TextButton(
                onPressed: () =>
                    Navigator.pushNamed(context, VisitorFormPage.routeName),
                child: const Text('打开邀请'),
              ))),
      routes: <String, WidgetBuilder>{VisitorFormPage.routeName: (_) => form});
  await tester.tap(find.text('打开邀请'));
  await tester.pumpAndSettle();
}

Future<void> _fill(WidgetTester tester) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('测试小区 1栋 101').last);
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextFormField).first, '访客甲');
  await tester.enterText(find.byType(TextFormField).last, '13800138000');
  await tester.tap(find.text('请选择到访日期'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('确定'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.loadTokens();
    await tokenManager.setToken('visitor-account-a');
  });

  test('visitor receipt survives reopening and isolates accounts', () async {
    final store = VisitorSubmissionStore();
    final pending = await _seed(store);
    expect(isSubmissionId(pending.submissionId), isTrue);
    expect((await VisitorSubmissionStore().load('owner-a'))!.toJson(),
        pending.toJson());
    expect(await store.load('owner-b'), isNull);
    expect(VisitorSubmissionStore.prepare(_record).submissionId,
        isNot(pending.submissionId));
  });

  test(
      'pending visitor receipt cannot be overwritten or deleted by a stale page',
      () async {
    final store = VisitorSubmissionStore();
    final pending = await _seed(store);
    final another = VisitorSubmissionStore.prepare(_record);
    expect(await store.save('owner-a', another), isFalse);
    expect(await store.remove('owner-a', another.submissionId), isFalse);
    expect((await store.load('owner-a'))!.submissionId, pending.submissionId);
    final altered = VisitorRecord.fromJson(
        <String, dynamic>{...pending.toJson(), 'name': '变更内容'});
    expect(await store.save('owner-a', altered), isFalse);
    expect(await store.save('owner-a', pending), isTrue);
  });

  test('save and conditional removal remain ordered', () async {
    final store = VisitorSubmissionStore();
    final pending = VisitorSubmissionStore.prepare(_record);
    final save = store.save('owner-a', pending);
    final remove = store.remove('owner-a', pending.submissionId);
    expect(await save, isTrue);
    expect(await remove, isTrue);
    expect(await store.load('owner-a'), isNull);
  });

  test('corrupt visitor receipts fail closed without erasing or replacing data',
      () async {
    final prefs = await SharedPreferences.getInstance();
    const key = 'visitorSubmission:v1:owner-a:new';
    final pending = VisitorSubmissionStore.prepare(_record);
    for (final raw in <String>[
      '{bad',
      '[]',
      '{"version":2,"request":{}}',
      jsonEncode(<String, dynamic>{
        'version': 1,
        'request': <String, dynamic>{
          ...pending.toJson(),
          'visitDate': '2030-02-30'
        }
      }),
      jsonEncode(<String, dynamic>{
        'version': 1,
        'request': <String, dynamic>{...pending.toJson(), 'gender': '1'}
      }),
    ]) {
      await prefs.setString(key, raw);
      final store = VisitorSubmissionStore();
      await expectLater(store.load('owner-a'), throwsFormatException);
      await expectLater(store.save('owner-a', pending), throwsFormatException);
      expect(prefs.getString(key), raw);
    }
  });

  testWidgets('visitor receipt must be persisted before a request can be sent',
      (tester) async {
    var sent = 0;
    await _open(
        tester,
        _form(_UnavailableStore(), send: (_) async {
          sent++;
        }));
    await _fill(tester);
    await tester.tap(find.text('创建邀请'));
    await tester.pumpAndSettle();
    expect(sent, 0);
    expect(find.text('提交回执未能保存，本次尚未发送，请重新加载'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(find.text('访客甲'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('definite create rejection clears receipt and duplicate name can be corrected',
      (tester) async {
    final store = VisitorSubmissionStore();
    var sends = 0;
    await _open(tester, _form(store, send: (_) async {
      sends++;
      if (sends == 1) throw const BusinessException('姓名已被登记', code: 40002);
      throw const NetworkException('服务暂不可用', statusCode: 503);
    }));
    await _fill(tester);
    await tester.tap(find.text('创建邀请'));
    await tester.pumpAndSettle();
    expect(await store.load('owner-a'), isNull);
    expect(find.text('姓名已被登记'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).first, '李访客');
    await tester.tap(find.text('创建邀请'));
    await tester.pumpAndSettle();
    expect(sends, 2);
    expect((await store.load('owner-a'))!.name, '李访客');
    await finishPage(tester);
  });

  testWidgets(
      'lost response restores a saved receipt and lookup finds the original invitation',
      (tester) async {
    final store = VisitorSubmissionStore();
    VisitorRecord? sent;
    VisitorRecord? persistedAtSend;
    var sends = 0;
    await _open(
        tester,
        _form(store,
            send: (record) async {
              sends++;
              sent = record;
              persistedAtSend = await store.load('owner-a');
              throw const NetworkException('响应丢失', isTimeout: true);
            },
            lookup: (_) async => _created));
    await _fill(tester);
    await tester.tap(find.text('创建邀请'));
    await tester.pumpAndSettle();
    expect(sends, 1);
    expect(persistedAtSend!.toJson(), sent!.toJson());
    expect(find.text('创建邀请'), findsNothing);
    expect(find.text('访客甲'), findsOneWidget);
    await tester.tap(find.text('查看提交结果'));
    await tester.pumpAndSettle();
    expect(find.text('打开邀请'), findsOneWidget);
    expect(await store.load('owner-a'), isNull);
    expect(sends, 1);
    await finishPage(tester);
  });

  testWidgets(
      'unknown results preserve receipt and explicit retry uses the exact original content',
      (tester) async {
    final store = VisitorSubmissionStore();
    final pending = await _seed(store);
    final sends = <VisitorRecord>[];
    await _open(
        tester,
        _form(store, send: (record) async {
          sends.add(record);
          throw const NetworkException('仍未确认');
        }));
    await tester.tap(find.text('查看提交结果'));
    await tester.pumpAndSettle();
    expect(find.textContaining('原请求可能仍在处理'), findsOneWidget);
    expect((await store.load('owner-a'))!.submissionId, pending.submissionId);
    await tester.tap(find.text('按原内容重试'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('先不操作'));
    await tester.pumpAndSettle();
    expect(sends, isEmpty);
    await tester.tap(find.text('按原内容重试'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('确认重试'));
    await tester.pumpAndSettle();
    expect(sends.single.toJson(), pending.toJson());
    expect((await store.load('owner-a'))!.toJson(), pending.toJson());
    await finishPage(tester);
  });

  testWidgets(
      'confirmed stop clears only that receipt and permits editing again',
      (tester) async {
    final store = VisitorSubmissionStore();
    final pending = await _seed(store);
    var sends = 0;
    String? stopped;
    await _open(
        tester,
        _form(store, send: (_) async {
          sends++;
        }, close: (id) async {
          stopped = id;
          return _closed;
        }));
    await tester.tap(find.text('停止本次提交'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('确认停止'));
    await tester.pumpAndSettle();
    expect(stopped, pending.submissionId);
    expect(await store.load('owner-a'), isNull);
    expect(find.text('创建邀请'), findsOneWidget);
    expect(find.text('访客甲'), findsOneWidget);
    expect(sends, 0);
    await tester.tap(find.text('2030-10-28'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await finishPage(tester);
  });

  testWidgets(
      'stop finding an already-created invitation returns to the list instead of allowing a new create',
      (tester) async {
    final store = VisitorSubmissionStore();
    await _seed(store);
    var sends = 0;
    await _open(
        tester,
        _form(store,
            send: (_) async {
              sends++;
            },
            close: (_) async => _created));
    await tester.tap(find.text('停止本次提交'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('确认停止'));
    await tester.pumpAndSettle();
    expect(find.text('打开邀请'), findsOneWidget);
    expect(await store.load('owner-a'), isNull);
    expect(sends, 0);
    await finishPage(tester);
  });

  testWidgets(
      'receipt recovery works even if the original house can no longer load',
      (tester) async {
    final store = VisitorSubmissionStore();
    await _seed(store);
    await _open(
        tester,
        _form(store,
            send: (_) async {},
            lookup: (_) async => _created,
            houses: () async => throw const NetworkException('房屋已删除')));
    expect(find.text('查看提交结果'), findsOneWidget);
    await tester.tap(find.text('查看提交结果'));
    await tester.pumpAndSettle();
    expect(find.text('打开邀请'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets(
      'failed cleanup preserves a confirmed receipt and does not offer another submission',
      (tester) async {
    final store = _RemoveOnceFailsStore();
    await _seed(store);
    await _open(tester,
        _form(store, send: (_) async {}, lookup: (_) async => _created));
    await tester.tap(find.text('查看提交结果'));
    await tester.pumpAndSettle();
    expect(await store.load('owner-a'), isNotNull);
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '按原内容重试'))
            .onPressed,
        isNull);
    store.fail = false;
    await tester.tap(find.text('查看提交结果'));
    await tester.pumpAndSettle();
    expect(await store.load('owner-a'), isNull);
    expect(find.text('打开邀请'), findsOneWidget);
    await finishPage(tester);
  });

  for (final bool switchAccount in <bool>[true, false]) {
    testWidgets(
        'late recovery after ${switchAccount ? 'account switch' : 'disposal'} cannot remove receipts or navigate',
        (tester) async {
      final store = VisitorSubmissionStore();
      await _seed(store);
      await _seed(store, owner: 'owner-b');
      final result = Completer<VisitorSubmissionResult>();
      await _open(tester,
          _form(store, send: (_) async {}, lookup: (_) => result.future));
      await tester.tap(find.text('查看提交结果'));
      await tester.pump();
      if (switchAccount) {
        await tokenManager.setToken('visitor-account-b');
      } else {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      result.complete(_created);
      await tester.pumpAndSettle();
      expect(await store.load('owner-a'), isNotNull);
      expect(await store.load('owner-b'), isNotNull);
      expect(find.text('访客邀请已创建'), findsNothing);
      expect(tester.takeException(), isNull);
      await finishPage(tester);
    });
  }

  testWidgets('missing identity blocks local receipt access and creation',
      (tester) async {
    var sends = 0;
    await _open(
        tester,
        _form(VisitorSubmissionStore(),
            send: (_) async {
              sends++;
            },
            identity: () async => const UserInfo.empty()));
    expect(find.text('创建邀请'), findsNothing);
    expect(find.text('账号信息缺少用户 ID，请重新加载'), findsWidgets);
    expect(sends, 0);
    await finishPage(tester);
  });
}
