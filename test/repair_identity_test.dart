import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' show Get, Inst;
import 'package:haven_hub/controller/user_info_controller.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/models/user_info.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/repair_draft_store.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/widget_harness.dart';
import 'repair_flow_test.dart' show fillRepair;

const _userA = UserInfo(id: 'user-a', avatarUrl: '', nickName: 'A');
const _userB = UserInfo(id: 'user-b', avatarUrl: '', nickName: 'B');
const _houses = <House>[
  House(id: 'house-test', point: '测试小区', building: '1栋', room: '101'),
];
const _items = <RepairItem>[RepairItem(id: 'item-test', name: '水管维修')];
const _unsaved = '账号信息尚未就绪，草稿暂未保存；请保留当前页面，待账号信息加载后再提交';

RepairFormPage _form(RepairDraftStore store,
        {Future<List<House>> Function()? houseLoader,
        Future<UserInfo> Function()? userInfoLoader,
        Future<void> Function(RepairRecord)? submitter}) =>
    RepairFormPage(
      draftStore: store,
      userInfoLoader: userInfoLoader ?? () async => const UserInfo.empty(),
      houseLoader: houseLoader ?? () async => _houses,
      itemLoader: () async => _items,
      submitter: submitter ?? (_) async {},
    );

class _DelayedDraftStore extends RepairDraftStore {
  final started = Completer<void>();
  final response = Completer<RepairDraft?>();

  @override
  Future<RepairDraft?> load(String userKey) {
    started.complete();
    return response.future;
  }
}

class _InitiallyFailingDraftStore extends RepairDraftStore {
  bool fail = true;

  @override
  Future<RepairDraft?> load(String userKey) {
    if (fail) throw StateError('test read failure');
    return super.load(userKey);
  }
}

void main() {
  late UserInfoController users;
  late RepairDraftStore store;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();
  });

  Future<void> prepare(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.runAsync(
        () => tokenManager.setToken('account-a', refreshToken: 'refresh-a'));
    users = Get.put(UserInfoController());
    store = RepairDraftStore();
  }

  tearDown(() async {
    await Get.delete<UserInfoController>(force: true);
    tokenManager.invalidateLocalSession();
  });

  testWidgets('cold start fetches identity restores draft and allows submit',
      (tester) async {
    await prepare(tester);
    await store.save('user-a',
        const RepairDraft(record: RepairRecord(description: 'saved A draft')));
    int loads = 0;
    int requests = 0;
    await pumpPage(
        tester,
        _form(store, userInfoLoader: () async {
          loads++;
          return _userA;
        }, submitter: (_) async {
          requests++;
        }));
    expect(loads, 1);
    expect(find.text('saved A draft'), findsOneWidget);
    expect(find.text(_unsaved), findsNothing);
    await fillRepair(tester);
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(await store.load('user-a'), isNull);
    await finishPage(tester);
  });

  testWidgets('identity failure can retry in place and keeps confirmation',
      (tester) async {
    await prepare(tester);
    await store.save(
        'user-a',
        const RepairDraft(
            record: RepairRecord(description: 'old draft'),
            resultUnconfirmed: true));
    int loads = 0;
    int requests = 0;
    await pumpPage(
        tester,
        _form(store, userInfoLoader: () async {
          if (++loads == 1) throw const NetworkException('账号资料加载失败，请检查网络');
          return _userA;
        }, submitter: (_) async {
          requests++;
        }));
    expect(find.text('账号资料加载失败，请检查网络'), findsOneWidget);
    await fillRepair(tester);
    await tester.ensureVisible(find.text('重试加载账号信息'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试加载账号信息'));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(find.text('水管漏水'), findsOneWidget);
    expect((await store.load('user-a'))!.resultUnconfirmed, isTrue);
    await tester.ensureVisible(find.text('提交报修'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(find.text('上次提交结果未确认'), findsOneWidget);
    expect(requests, 0);
    await tester.tap(find.text('先不提交'));
    await tester.pumpAndSettle();
    await finishPage(tester);
  });

  testWidgets('empty profile id remains blocked and submit retries identity',
      (tester) async {
    await prepare(tester);
    int loads = 0;
    int requests = 0;
    await pumpPage(
        tester,
        _form(store, userInfoLoader: () async {
          return ++loads <= 2
              ? const UserInfo(id: ' ', avatarUrl: '', nickName: '')
              : _userA;
        }, submitter: (_) async {
          requests++;
        }));
    expect(find.text('账号信息缺少用户 ID，请重试加载'), findsOneWidget);
    expect(users.currentUser.id, isEmpty);
    await fillRepair(tester);
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(requests, 0);
    expect(await store.load('user-a'), isNull);
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(loads, 3);
    expect(requests, 1);
    await finishPage(tester);
  });

  testWidgets(
      'pending identity is deduplicated and survives same session refresh',
      (tester) async {
    await prepare(tester);
    final response = Completer<UserInfo>();
    int loads = 0;
    final requests = <RepairRecord>[];
    await pumpPage(
        tester,
        _form(store, userInfoLoader: () {
          loads++;
          return response.future;
        }, submitter: (record) async {
          requests.add(record);
        }));
    await fillRepair(tester);
    await tester.tap(find.text('提交报修'));
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(requests, isEmpty);
    await tester.runAsync(() => tokenManager.setRefreshedToken('refreshed-a',
        refreshToken: 'refreshed-ra'));
    response.complete(_userA);
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(requests.single.description, '水管漏水');
    expect(await store.load('user-a'), isNull);
    await finishPage(tester);
  });

  testWidgets('late fetched identity cannot update a replacement account',
      (tester) async {
    await prepare(tester);
    final response = Completer<UserInfo>();
    int loads = 0;
    int requests = 0;
    await pumpPage(
        tester,
        _form(store, userInfoLoader: () {
          loads++;
          return response.future;
        }, submitter: (_) async {
          requests++;
        }));
    await fillRepair(tester);
    await tester.runAsync(() => tokenManager.setToken('account-b'));
    users.updateUser(_userB);
    response.complete(_userA);
    await tester.pumpAndSettle();
    expect(users.currentUser.id, 'user-b');
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(requests, 0);
    expect(await store.load('user-a'), isNull);
    expect(await store.load('user-b'), isNull);
    await finishPage(tester);
  });

  testWidgets('leaving during identity fetch ignores late profile',
      (tester) async {
    await prepare(tester);
    final response = Completer<UserInfo>();
    await pumpPage(tester, _form(store, userInfoLoader: () => response.future));
    await tester.pumpWidget(const SizedBox.shrink());
    response.complete(_userA);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(users.currentUser.id, isEmpty);
    expect(users.listeners, 0);
    expect(await store.load('user-a'), isNull);
  });

  testWidgets('missing token does not fetch identity or submit',
      (tester) async {
    await prepare(tester);
    tokenManager.invalidateLocalSession();
    int loads = 0;
    int requests = 0;
    await pumpPage(
        tester,
        _form(store, userInfoLoader: () async {
          loads++;
          return _userA;
        }, submitter: (_) async {
          requests++;
        }));
    await fillRepair(tester);
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(loads, 0);
    expect(requests, 0);
    await finishPage(tester);
  });

  testWidgets('ready identity avoids redundant fetch', (tester) async {
    await prepare(tester);
    users.updateUser(_userA);
    int loads = 0;
    await pumpPage(
        tester,
        _form(store, userInfoLoader: () async {
          loads++;
          return _userB;
        }));
    expect(loads, 0);
    expect(users.currentUser.id, 'user-a');
    await finishPage(tester);
  });

  testWidgets('profile published elsewhere wins over a late empty response',
      (tester) async {
    await prepare(tester);
    final response = Completer<UserInfo>();
    final delayedDrafts = _DelayedDraftStore();
    int loads = 0;
    final requests = <RepairRecord>[];
    await pumpPage(
        tester,
        _form(delayedDrafts, userInfoLoader: () {
          loads++;
          return response.future;
        }, submitter: (record) async {
          requests.add(record);
        }));
    users.updateUser(_userA);
    await tester.pump();
    expect(delayedDrafts.started.isCompleted, isTrue);
    expect(loads, 1);
    expect(users.currentUser.id, 'user-a');
    await fillRepair(tester);
    await tester.tap(find.text('提交报修'));
    await tester.pump();
    expect(requests, isEmpty);
    delayedDrafts.response.complete(null);
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(requests.single.description, '水管漏水');
    response.complete(const UserInfo.empty());
    await tester.pumpAndSettle();
    expect(users.currentUser.id, 'user-a');
    expect(loads, 1);
    expect(requests, hasLength(1));
    expect(find.text(_unsaved), findsNothing);
    await finishPage(tester);
  });

  testWidgets(
      'late production profile during option loading restores its draft',
      (tester) async {
    await prepare(tester);
    await store.save(
        'user-a',
        const RepairDraft(
          record: RepairRecord(
              houseId: 'house-test',
              repairItemId: 'item-test',
              description: 'saved A draft'),
        ));
    final options = Completer<List<House>>();
    await tester.pumpWidget(
        MaterialApp(home: _form(store, houseLoader: () => options.future)));
    users.updateUser(_userA);
    options.complete(_houses);
    await tester.pumpAndSettle();
    expect(find.text('saved A draft'), findsOneWidget);
    expect(find.text('已恢复当前账号的报修草稿'), findsOneWidget);
    expect(find.text('测试小区 1栋 101'), findsOneWidget);
    expect(find.text('重新加载'), findsNothing);
    await finishPage(tester);
  });

  testWidgets(
      'unknown production identity explains unsaved input and stops submit',
      (tester) async {
    await prepare(tester);
    int calls = 0;
    await pumpPage(
        tester,
        _form(store, submitter: (_) async {
          calls++;
        }));
    expect(find.text(_unsaved), findsOneWidget);
    await fillRepair(tester);
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await finishPage(tester);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getKeys().where((key) => key.startsWith('repairDraft:')),
        isEmpty);
  });

  testWidgets('late identity updates visible dropdowns on an untouched form',
      (tester) async {
    await prepare(tester);
    await store.save(
        'user-a',
        const RepairDraft(
            record: RepairRecord(
                houseId: 'house-test',
                repairItemId: 'item-test',
                mobile: '13800138000',
                description: 'saved A draft')));
    await pumpPage(tester, _form(store));
    users.updateUser(_userA);
    await tester.pumpAndSettle();
    expect(find.text(_unsaved), findsNothing);
    expect(find.text('saved A draft'), findsOneWidget);
    expect(find.text('测试小区 1栋 101'), findsOneWidget);
    expect(find.text('水管维修'), findsOneWidget);
    final fields = tester
        .widgetList<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>))
        .toList();
    expect(fields.first.initialValue, 'house-test');
    expect(fields.last.initialValue, 'item-test');
    await finishPage(tester);
  });

  testWidgets('same session profile arrival allows submission of typed input',
      (tester) async {
    await prepare(tester);
    final requests = <RepairRecord>[];
    await pumpPage(
        tester,
        _form(store, submitter: (record) async {
          requests.add(record);
          throw const NetworkException('timeout', isTimeout: true);
        }));
    await fillRepair(tester);
    users.updateUser(_userA);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('提交报修'));
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(requests.single.description, '水管漏水');
    expect(requests.single.houseId, 'house-test');
    expect((await store.load('user-a'))!.resultUnconfirmed, isTrue);
    await finishPage(tester);
  });

  testWidgets('missing profile controller can later publish the current owner',
      (tester) async {
    await prepare(tester);
    await Get.delete<UserInfoController>(force: true);
    await pumpPage(tester, _form(store));
    expect(find.text(_unsaved), findsOneWidget);
    await tester.enterText(
        find.byType(TextFormField).last, 'typed before profile');
    users = Get.find<UserInfoController>()..updateUser(_userA);
    await tester.pumpAndSettle();
    expect((await store.load('user-a'))!.record.description,
        'typed before profile');
    await finishPage(tester);
  });

  testWidgets('failed draft read preserves disk and retry keeps confirmation',
      (tester) async {
    await prepare(tester);
    await store.save(
        'user-a',
        const RepairDraft(
            record: RepairRecord(description: 'unconfirmed on disk'),
            resultUnconfirmed: true));
    final failing = _InitiallyFailingDraftStore();
    int calls = 0;
    await pumpPage(
        tester,
        _form(failing, submitter: (_) async {
          calls++;
        }));
    await fillRepair(tester);
    users.updateUser(_userA);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('提交报修'));
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect((await store.load('user-a'))!.record.description,
        'unconfirmed on disk');
    expect(find.text('本机草稿读取失败，请保留当前页面，点击提交可重试'), findsOneWidget);
    expect(find.text('本机草稿保存不可用，请保留当前页面的填写内容'), findsNothing);
    failing.fail = false;
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(find.text('上次提交结果未确认'), findsOneWidget);
    expect(find.text('本机草稿读取失败，请保留当前页面，点击提交可重试'), findsNothing);
    expect(find.text('本机草稿保存不可用，请保留当前页面的填写内容'), findsNothing);
    expect(calls, 0);
    await tester.tap(find.text('先不提交'));
    await tester.pumpAndSettle();
    expect((await store.load('user-a'))!.record.description, '水管漏水');
    expect((await store.load('user-a'))!.resultUnconfirmed, isTrue);
    await finishPage(tester);
  });

  testWidgets('late identity keeps typed input and previous unconfirmed result',
      (tester) async {
    await prepare(tester);
    await store.save(
        'user-a',
        const RepairDraft(
          record: RepairRecord(description: 'old unconfirmed draft'),
          resultUnconfirmed: true,
        ));
    int calls = 0;
    await pumpPage(
        tester,
        _form(store, submitter: (_) async {
          calls++;
        }));
    await fillRepair(tester);
    users.updateUser(_userA);
    await tester.pumpAndSettle();
    expect(find.text('水管漏水'), findsOneWidget);
    expect(find.text('old unconfirmed draft'), findsNothing);
    expect(find.text(_unsaved), findsNothing);
    await tester.pump(const Duration(milliseconds: 350));
    expect((await store.load('user-a'))!.record.description, '水管漏水');
    expect((await store.load('user-a'))!.resultUnconfirmed, isTrue);
    await tester.ensureVisible(find.text('提交报修'));
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(find.text('上次提交结果未确认'), findsOneWidget);
    expect(calls, 0);
    await tester.tap(find.text('先不提交'));
    await tester.pumpAndSettle();
    await finishPage(tester);
  });

  testWidgets('new account cannot bind an old form with unknown identity',
      (tester) async {
    await prepare(tester);
    await store.save(
        'user-b',
        const RepairDraft(
            record: RepairRecord(description: 'private B draft')));
    int calls = 0;
    await pumpPage(
        tester,
        _form(store, submitter: (_) async {
          calls++;
        }));
    await fillRepair(tester);
    await tester.runAsync(() => tokenManager.setToken('account-b'));
    users.updateUser(_userB);
    await tester.pumpAndSettle();
    expect(find.text('private B draft'), findsNothing);
    await tester.ensureVisible(find.text('提交报修'));
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await finishPage(tester);
    expect((await store.load('user-b'))!.record.description, 'private B draft');
    expect(await store.load('user-a'), isNull);
  });

  testWidgets('editing during late draft read keeps fields and confirmation',
      (tester) async {
    await prepare(tester);
    final delayed = _DelayedDraftStore();
    await pumpPage(tester, _form(delayed));
    users.updateUser(_userA);
    await tester.pump();
    expect(delayed.started.isCompleted, isTrue);
    await tester.enterText(find.byType(TextFormField).last, 'new typing');
    delayed.response.complete(const RepairDraft(
        record: RepairRecord(description: 'late disk draft'),
        resultUnconfirmed: true));
    await tester.pumpAndSettle();
    expect(find.text('new typing'), findsOneWidget);
    expect(find.text('late disk draft'), findsNothing);
    expect(find.text('提交结果未确认：请先查看“我的报修”。再次提交可能产生重复记录。'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('account replacement discards pending production draft read',
      (tester) async {
    await prepare(tester);
    final delayed = _DelayedDraftStore();
    await pumpPage(tester, _form(delayed));
    users.updateUser(_userA);
    await tester.pump();
    expect(delayed.started.isCompleted, isTrue);
    await tester.runAsync(() => tokenManager.setToken('account-b'));
    users.updateUser(_userB);
    delayed.response.complete(const RepairDraft(
        record: RepairRecord(description: 'private A draft')));
    await tester.pumpAndSettle();
    expect(find.text('private A draft'), findsNothing);
    await finishPage(tester);
    expect(await store.load('user-a'), isNull);
    expect(await store.load('user-b'), isNull);
  });

  testWidgets('leaving during production draft read removes profile listener',
      (tester) async {
    await prepare(tester);
    final delayed = _DelayedDraftStore();
    await pumpPage(tester, _form(delayed));
    users.updateUser(_userA);
    await tester.pump();
    expect(delayed.started.isCompleted, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    delayed.response.complete(
        const RepairDraft(record: RepairRecord(description: 'late draft')));
    users.updateUser(_userA);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(users.listeners, 0);
  });
}
