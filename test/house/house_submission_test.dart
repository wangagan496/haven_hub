import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:haven_hub/api/user.dart';
import 'package:haven_hub/controller/build_controller.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/models/user_info.dart';
import 'package:haven_hub/pages/house/house_form.dart';
import 'package:haven_hub/pages/house/house_list.dart';
import 'package:haven_hub/router/app_routes.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/house_submission_store.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/widget_harness.dart';

const _house = House(
    point: '甲小区',
    building: '1栋',
    room: '301',
    floor: '3',
    name: '张三',
    mobile: '13800138000',
    idcardFrontUrl: 'https://example.test/front.png',
    idcardBackUrl: 'https://example.test/back.png');
const _unknown = HouseSubmissionResult(HouseSubmissionState.unknown);
const _closed = HouseSubmissionResult(HouseSubmissionState.closed);
const _created = HouseSubmissionResult(HouseSubmissionState.created,
    createdId: 'original-house');
const _deleted = HouseSubmissionResult(HouseSubmissionState.deleted,
    createdId: 'original-house');

class _SaveFails extends HouseSubmissionStore {
  @override
  Future<bool> save(String owner, HouseSubmission submission) async => false;
}

class _RemoveFails extends HouseSubmissionStore {
  bool fail = true;
  @override
  Future<bool> remove(String owner, String id) =>
      fail ? Future.value(false) : super.remove(owner, id);
}

String _draft([House house = _house]) {
  final controller = BuildController.instance();
  final id = controller.startDraft();
  controller
    ..selectCommunity(<String, dynamic>{'name': house.point}, draftId: id)
    ..selectBuilding(house.building, draftId: id)
    ..selectRoom(house.room, floor: house.floor, draftId: id)
    ..saveForm(id, house);
  return id;
}

Future<HouseSubmission> _seed(HouseSubmissionStore store,
    {String owner = 'owner-a', String? draftId}) async {
  final pending =
      HouseSubmissionStore.prepare(_house, draftId: draftId ?? _draft());
  await store.save(owner, pending);
  return pending;
}

HouseForm _form(
  HouseSubmissionStore store,
  String draft, {
  required Future<void> Function(House) send,
  Future<HouseSubmissionResult> Function(String)? lookup,
  Future<HouseSubmissionResult> Function(String)? close,
  UserInfoLoader? identity,
}) =>
    HouseForm(
      draftId: draft,
      submissionStore: store,
      userInfoLoader: identity ??
          () async =>
              const UserInfo(id: 'owner-a', avatarUrl: '', nickName: '测试'),
      submitHouseLoader: send,
      submissionLoader: lookup ?? (_) async => _unknown,
      submissionCloser: close ?? (_) async => _closed,
    );

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _open(WidgetTester tester, HouseForm form) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await pumpPage(
      tester,
      Builder(
          builder: (context) => Scaffold(
                  body: TextButton(
                onPressed: () => Navigator.pushNamed(context, houseForm),
                child: const Text('打开房屋表单'),
              ))),
      routes: <String, WidgetBuilder>{
        houseForm: (_) => form,
        houseList: (_) => const Scaffold(body: Text('房屋列表已刷新')),
      });
  await tester.tap(find.text('打开房屋表单'));
  await _frames(tester);
}

void main() {
  setUp(() async {
    Get.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.loadTokens();
    await tokenManager.setToken('house-account-a');
  });
  tearDown(Get.reset);

  test('definite rejection includes business and explicit 4xx but excludes uncertain network outcomes', () {
    expect(isDefiniteRequestRejection(const BusinessException('姓名已登记', code: 40002)), isTrue);
    for (final status in [400, 401, 403, 404, 409, 422, 429]) {
      expect(isDefiniteRequestRejection(NetworkException('明确拒绝', statusCode: status)), isTrue);
    }
    for (final status in <int?>[null, 408, 500, 503]) {
      expect(isDefiniteRequestRejection(NetworkException('结果未知', statusCode: status)), isFalse);
    }
    expect(isDefiniteRequestRejection(const NetworkException('超时', statusCode: 400, isTimeout: true)), isFalse);
    expect(isDefiniteRequestRejection(const SessionChangedException()), isFalse);
  });

  testWidgets('restarted house list exposes pending receipt without selecting a room again', (tester) async {
    final pending = await _seed(HouseSubmissionStore());
    Get.reset();
    HouseFormArguments? opened;
    String? lookedUp;
    await pumpPage(tester, HouseList(
      houseListLoader: () async => <House>[],
      userInfoLoader: () async => const UserInfo(id: 'owner-a', avatarUrl: '', nickName: '测试'),
      submissionStore: HouseSubmissionStore(),
    ), routes: <String, WidgetBuilder>{
      houseForm: (context) {
        opened = ModalRoute.of(context)!.settings.arguments! as HouseFormArguments;
        return _form(HouseSubmissionStore(), pending.draftId,
          send: (_) async => fail('result lookup must not resubmit'),
          lookup: (id) async { lookedUp = id; return _unknown; });
      },
    });
    expect(find.text('有一份待确认的房屋提交'), findsOneWidget);
    await tester.tap(find.text('查看结果'));
    await tester.pumpAndSettle();
    expect(opened!.draftId, pending.draftId);
    expect(opened!.isCreate, isTrue);
    expect(find.text('查看提交结果'), findsOneWidget);
    await tester.tap(find.text('查看提交结果'));
    await tester.pumpAndSettle();
    expect(lookedUp, pending.id);
    await finishPage(tester);
  });

  testWidgets('house list hides the previous account receipt after switching sessions', (tester) async {
    await _seed(HouseSubmissionStore());
    await pumpPage(tester, HouseList(
      houseListLoader: () async => <House>[],
      userInfoLoader: () async => const UserInfo(id: 'owner-a', avatarUrl: '', nickName: ''),
      submissionStore: HouseSubmissionStore(),
    ));
    expect(find.text('有一份待确认的房屋提交'), findsOneWidget);
    await tokenManager.setToken('house-account-b');
    await tester.pumpAndSettle();
    expect(find.text('有一份待确认的房屋提交'), findsNothing);
    expect(find.text('查看结果'), findsNothing);
    await finishPage(tester);
  });

  test(
      'house receipt survives restart and account isolation with non-reusable draft IDs',
      () async {
    final store = HouseSubmissionStore();
    final saved = await _seed(store);
    Get.reset();
    final nextDraft = _draft();
    expect(nextDraft, isNot(saved.draftId));
    expect((await HouseSubmissionStore().load('owner-a'))!.toJson(),
        saved.toJson());
    expect(await store.load('owner-b'), isNull);
  });

  test('pending house receipt cannot be overwritten or removed by another form',
      () async {
    final store = HouseSubmissionStore();
    final saved = await _seed(store);
    final other = HouseSubmissionStore.prepare(_house.copyWith(room: '999'),
        draftId: _draft());
    expect(await store.save('owner-a', other), isFalse);
    expect(await store.remove('owner-a', other.id), isFalse);
    expect(await store.save('owner-a', saved), isTrue);
    expect((await store.load('owner-a'))!.id, saved.id);
    final remove = store.remove('owner-a', saved.id);
    final save = store.save('owner-a', other);
    expect(await remove, isTrue);
    expect(await save, isTrue);
    expect((await store.load('owner-a'))!.id, other.id);
  });

  test('corrupt or incomplete persisted house request blocks replacement',
      () async {
    final store = HouseSubmissionStore();
    final saved = HouseSubmissionStore.prepare(_house, draftId: _draft());
    final prefs = await SharedPreferences.getInstance();
    const key = 'houseSubmission:v1:owner-a:new';
    for (final raw in <String>[
      '{bad',
      '[]',
      jsonEncode(<String, dynamic>{...saved.toJson(), 'version': 2}),
      jsonEncode(<String, dynamic>{
        ...saved.toJson(),
        'request': <String, dynamic>{
          ...saved.house.toJson(),
          'idcardFrontUrl': 1
        }
      }),
      jsonEncode(<String, dynamic>{
        ...saved.toJson(),
        'request': <String, dynamic>{
          ...saved.house.toJson(),
          'id': 'edited-house'
        }
      }),
    ]) {
      await prefs.setString(key, raw);
      await expectLater(store.load('owner-a'), throwsFormatException);
      await expectLater(store.save('owner-a', saved), throwsFormatException);
      expect(prefs.getString(key), raw);
    }
  });

  testWidgets('failed persistence sends nothing and reload retains owner input',
      (tester) async {
    var sends = 0;
    final draft = _draft();
    await _open(
        tester,
        _form(_SaveFails(), draft, send: (_) async {
          sends++;
        }));
    await tester.enterText(find.byType(TextFormField).first, '李四');
    await tester.tap(find.text('提交审核'));
    await _frames(tester);
    expect(sends, 0);
    expect(find.text('提交回执未能保存，本次尚未发送，请重新加载'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await _frames(tester);
    expect(find.text('李四'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('definite create rejection clears its receipt and maps duplicate name to editable field',
      (tester) async {
    final store = HouseSubmissionStore();
    final draft = _draft();
    var sends = 0;
    await _open(tester, _form(store, draft, send: (_) async {
      sends++;
      if (sends == 1) throw const BusinessException('英文姓名已被登记', code: 40002);
      throw const NetworkException('服务暂不可用', statusCode: 503);
    }));

    await tester.tap(find.text('提交审核'));
    await _frames(tester);
    expect(await store.load('owner-a'), isNull);
    expect(find.text('英文姓名已被登记'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, '李四');
    await tester.tap(find.text('提交审核'));
    await _frames(tester);
    expect(sends, 2);
    expect((await store.load('owner-a'))!.house.name, '李四');
    await finishPage(tester);
  });

  testWidgets(
      'response loss persists before send and recovery clears only the original draft',
      (tester) async {
    final store = HouseSubmissionStore();
    final draft = _draft();
    final another = _draft(_house.copyWith(point: '乙小区', room: '999'));
    House? sent;
    HouseSubmission? savedAtSend;
    await _open(
        tester,
        _form(store, draft,
            send: (house) async {
              sent = house;
              savedAtSend = await store.load('owner-a');
              throw const NetworkException('响应丢失');
            },
            lookup: (_) async => _created));
    await tester.tap(find.text('提交审核'));
    await _frames(tester);
    expect(savedAtSend!.house.toJson(), sent!.toJson());
    expect(find.text('提交审核'), findsNothing);
    await tester.tap(find.text('查看提交结果'));
    await _frames(tester);
    expect(await store.load('owner-a'), isNull);
    expect(BuildController.instance().draftFor(draft), isNull);
    expect(BuildController.instance().houseFor(another).room, '999');
    expect(find.text('房屋列表已刷新'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets(
      'unknown result and cancelled retry never send; confirmed retry preserves original photo URLs',
      (tester) async {
    final store = HouseSubmissionStore();
    final saved = await _seed(store);
    final sends = <House>[];
    await _open(
        tester,
        _form(store, saved.draftId, send: (house) async {
          sends.add(house);
          throw const NetworkException('仍未确认');
        }));
    await tester.tap(find.text('查看提交结果'));
    await _frames(tester);
    expect(find.textContaining('原请求可能仍在处理'), findsOneWidget);
    await tester.tap(find.text('按原内容重试'));
    await _frames(tester);
    await tester.tap(find.text('先不操作'));
    await _frames(tester);
    expect(sends, isEmpty);
    BuildController.instance()
        .saveForm(saved.draftId, _house.copyWith(name: '李四'));
    await tester.tap(find.text('按原内容重试'));
    await _frames(tester);
    await tester.tap(find.text('确认重试'));
    await _frames(tester);
    expect(sends.single.toJson(), saved.house.toJson());
    expect((await store.load('owner-a'))!.id, saved.id);
    await finishPage(tester);
  });

  testWidgets(
      'confirmed stop clears receipt and allows editing without discarding either draft',
      (tester) async {
    final store = HouseSubmissionStore();
    final saved = await _seed(store);
    final other = _draft(_house.copyWith(room: '999'));
    String? stopped;
    await _open(
        tester,
        _form(store, saved.draftId, send: (_) async {}, close: (id) async {
          stopped = id;
          return _closed;
        }));
    await tester.tap(find.text('停止本次提交'));
    await _frames(tester);
    await tester.tap(find.text('确认停止'));
    await _frames(tester);
    expect(stopped, saved.id);
    expect(await store.load('owner-a'), isNull);
    expect(find.text('提交审核'), findsOneWidget);
    expect(BuildController.instance().draftFor(saved.draftId), isNotNull);
    expect(BuildController.instance().draftFor(other), isNotNull);
    await tester.enterText(find.byType(TextFormField).first, '李四');
    expect(BuildController.instance().houseFor(saved.draftId).name, '李四');
    await finishPage(tester);
  });

  for (final result in <HouseSubmissionResult>[_created, _deleted]) {
    testWidgets(
        'reopening recovers ${result.state.name} without deleting a new or edited draft',
        (tester) async {
      final store = HouseSubmissionStore();
      final saved = await _seed(store);
      if (result.state == HouseSubmissionState.created) {
        BuildController.instance()
            .saveForm(saved.draftId, _house.copyWith(name: '新业主'));
      } else {
        Get.reset();
      }
      final current = _draft(_house.copyWith(point: '新小区', room: '999'));
      var sends = 0;
      await _open(
          tester,
          _form(store, current,
              send: (_) async {
                sends++;
              },
              close: (_) async => result));
      await tester.tap(find.text('停止本次提交'));
      await _frames(tester);
      await tester.tap(find.text('确认停止'));
      await _frames(tester);
      expect(await store.load('owner-a'), isNull);
      expect(BuildController.instance().houseFor(current).point, '新小区');
      if (result.state == HouseSubmissionState.created) {
        expect(BuildController.instance().houseFor(saved.draftId).name, '新业主');
      }
      expect(sends, 0);
      expect(find.text('房屋列表已刷新'), findsOneWidget);
      await finishPage(tester);
    });
  }

  testWidgets(
      'failed cleanup disables resubmission until receipt cleanup succeeds',
      (tester) async {
    final store = _RemoveFails();
    final saved = await _seed(store);
    await _open(
        tester,
        _form(store, saved.draftId,
            send: (_) async {}, lookup: (_) async => _created));
    await tester.tap(find.text('查看提交结果'));
    await _frames(tester);
    expect(await store.load('owner-a'), isNotNull);
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '按原内容重试'))
            .onPressed,
        isNull);
    store.fail = false;
    await tester.tap(find.text('查看提交结果'));
    await _frames(tester);
    expect(await store.load('owner-a'), isNull);
    expect(find.text('房屋列表已刷新'), findsOneWidget);
    await finishPage(tester);
  });

  for (final switchAccount in <bool>[true, false]) {
    testWidgets(
        'late recovery after ${switchAccount ? 'account switch' : 'disposal'} keeps receipts and does not navigate',
        (tester) async {
      final store = HouseSubmissionStore();
      final saved = await _seed(store);
      await _seed(store, owner: 'owner-b');
      final completion = Completer<HouseSubmissionResult>();
      await _open(
          tester,
          _form(store, saved.draftId,
              send: (_) async {}, lookup: (_) => completion.future));
      await tester.tap(find.text('查看提交结果'));
      await tester.pump();
      if (switchAccount) {
        await tokenManager.setToken('house-account-b');
      } else {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      completion.complete(_created);
      await _frames(tester);
      expect(await store.load('owner-a'), isNotNull);
      expect(await store.load('owner-b'), isNotNull);
      expect(find.text('房屋列表已刷新'), findsNothing);
      expect(tester.takeException(), isNull);
      await finishPage(tester);
    });
  }

  testWidgets('missing confirmed identity blocks receipt loading and creation',
      (tester) async {
    var sends = 0;
    await _open(
        tester,
        _form(HouseSubmissionStore(), _draft(),
            send: (_) async {
              sends++;
            },
            identity: () async => const UserInfo.empty()));
    expect(find.text('账号信息缺少用户 ID，请重新加载'), findsOneWidget);
    expect(find.text('提交审核'), findsNothing);
    expect(sends, 0);
    await finishPage(tester);
  });
}
