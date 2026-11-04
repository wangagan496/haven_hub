import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/house.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/pages/house/house_detail.dart';
import 'package:haven_hub/pages/house/house_form.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/widget_harness.dart';

const _house = House(
    id: 'house-1',
    point: '测试小区',
    building: '1栋',
    room: '101',
    name: '张三',
    mobile: '13800138000',
    revision: 7);

class _Host extends StatelessWidget {
  const _Host();
  @override
  Widget build(BuildContext context) => Scaffold(
          body: TextButton(
        onPressed: () => Navigator.pushNamed(context, HouseDetail.routeName,
            arguments: 'house-1'),
        child: const Text('打开详情'),
      ));
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _open(WidgetTester tester,
    {required DeleteHouseLoader remove, HouseDetailLoader? load}) async {
  await pumpPage(tester, const _Host(), routes: <String, WidgetBuilder>{
    HouseDetail.routeName: (_) => HouseDetail(
          houseDetailLoader: load ?? (_) async => _house,
          deleteHouseLoader: remove,
        ),
  });
  await tester.tap(find.text('打开详情'));
  await _frames(tester);
}

OutlinedButton _deleteButton(WidgetTester tester) =>
    tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '删除房屋'));

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.text('删除房屋'));
  await _frames(tester);
  await tester.tap(find.widgetWithText(FilledButton, '确认'));
  await _frames(tester);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.loadTokens();
  });

  testWidgets(
      'one confirmation captures viewed revision and blocks duplicate dialogs and refresh',
      (tester) async {
    final pending = Completer<void>();
    final calls = <int>[];
    final ids = <String>[];
    var reads = 0;
    await _open(tester, load: (_) async {
      reads++;
      return _house;
    }, remove: (id, {required revision}) {
      ids.add(id);
      calls.add(revision);
      return pending.future;
    });
    final start = _deleteButton(tester).onPressed!;
    final refreshButton = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '刷新审核结果');
    final refresh = tester.widget<IconButton>(refreshButton).onPressed!;
    start();
    start();
    refresh();
    await _frames(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(reads, 1);
    expect(calls, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await _frames(tester);
    start();
    refresh();
    await tester.pump();
    expect(calls, <int>[7]);
    expect(ids, <String>[_house.id]);
    expect(reads, 1);
    expect(_deleteButton(tester).onPressed, isNull);
    expect(tester.widget<IconButton>(refreshButton).onPressed, isNull);
    pending.complete();
    await _frames(tester);
    expect(find.byType(HouseDetail), findsNothing);
    await finishPage(tester);
  });

  testWidgets('cancelling confirmation sends nothing and restores actions',
      (tester) async {
    var calls = 0;
    await _open(tester, remove: (_, {required revision}) async {
      calls++;
    });
    await tester.tap(find.text('删除房屋'));
    await _frames(tester);
    await tester.tap(find.text('取消'));
    await _frames(tester);
    expect(calls, 0);
    expect(_deleteButton(tester).onPressed, isNotNull);
    await finishPage(tester);
  });

  for (final conflict in <Object>[
    const NetworkException('资料已更新', statusCode: 409),
    const BusinessException('资料已更新', code: 40900),
  ]) {
    testWidgets('conflict $conflict requires refresh and another confirmation',
        (tester) async {
      final calls = <int>[];
      var reads = 0;
      await _open(tester, load: (_) async {
        reads++;
        return reads == 1
            ? _house
            : _house.copyWith(revision: 8, name: '李四', status: 2);
      }, remove: (_, {required revision}) async {
        calls.add(revision);
        if (calls.length == 1) throw conflict;
      });
      await _confirm(tester);
      expect(calls, <int>[7]);
      expect(reads, 1);
      expect(_deleteButton(tester).onPressed, isNull);
      expect(find.text('请先刷新核对房屋资料，再决定是否删除。'), findsOneWidget);
      await tester.tap(find.text('刷新房屋资料'));
      await _frames(tester);
      expect(find.text('李四'), findsOneWidget);
      expect(calls, <int>[7]);
      expect(_deleteButton(tester).onPressed, isNotNull);
      await _confirm(tester);
      expect(calls, <int>[7, 8]);
      expect(find.byType(HouseDetail), findsNothing);
      await finishPage(tester);
    });
  }

  testWidgets(
      'refresh failure preserves detail but never re-enables stale deletion',
      (tester) async {
    var reads = 0;
    var calls = 0;
    await _open(tester, load: (_) async {
      if (++reads == 2) throw const NetworkException('断网');
      return reads == 1 ? _house : _house.copyWith(revision: 8);
    }, remove: (_, {required revision}) async {
      calls++;
      throw const NetworkException('冲突', statusCode: 409);
    });
    await _confirm(tester);
    await tester.tap(find.text('刷新房屋资料'));
    await _frames(tester);
    expect(find.text('张三'), findsOneWidget);
    expect(_deleteButton(tester).onPressed, isNull);
    expect(calls, 1);
    await tester.tap(find.text('刷新房屋资料'));
    await _frames(tester);
    expect(_deleteButton(tester).onPressed, isNotNull);
    expect(calls, 1);
    await finishPage(tester);
  });

  testWidgets(
      'lost deletion response requires read and missing result removes stale actions',
      (tester) async {
    var reads = 0;
    var calls = 0;
    await _open(tester, load: (_) async {
      if (++reads > 1) {
        throw const NetworkException('房屋不存在或无权访问', statusCode: 404);
      }
      return _house;
    }, remove: (_, {required revision}) async {
      calls++;
      throw const NetworkException('响应丢失');
    });
    await _confirm(tester);
    expect(_deleteButton(tester).onPressed, isNull);
    await tester.tap(find.text('刷新房屋资料'));
    await _frames(tester);
    expect(find.text('删除房屋'), findsNothing);
    expect(find.text('张三'), findsNothing);
    expect(calls, 1);
    expect(find.byType(HouseDetail), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets('session change while confirming never sends deletion',
      (tester) async {
    var calls = 0;
    await _open(tester, remove: (_, {required revision}) async {
      calls++;
    });
    await tester.tap(find.text('删除房屋'));
    await _frames(tester);
    tokenManager.invalidateLocalSession();
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await _frames(tester);
    expect(calls, 0);
    expect(find.text('登录账号已变化，请返回房屋列表重新进入'), findsOneWidget);
    expect(find.text('删除房屋'), findsNothing);
    await finishPage(tester);
  });

  testWidgets('late deletion response after session change never navigates',
      (tester) async {
    final pending = Completer<void>();
    await _open(tester, remove: (_, {required revision}) => pending.future);
    await _confirm(tester);
    tokenManager.invalidateLocalSession();
    await tester.pump();
    pending.complete();
    await _frames(tester);
    expect(find.byType(HouseDetail), findsOneWidget);
    expect(find.text('登录账号已变化，请返回房屋列表重新进入'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets(
      'late detail after session change cannot restore previous account data',
      (tester) async {
    final pending = Completer<House>();
    await _open(tester,
        load: (_) => pending.future, remove: (_, {required revision}) async {});
    tokenManager.invalidateLocalSession();
    pending.complete(_house);
    await _frames(tester);
    expect(find.text('张三'), findsNothing);
    expect(find.text('删除房屋'), findsNothing);
    expect(find.text('登录账号已变化，请返回房屋列表重新进入'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets(
      'late failure after detail disposal has no state or navigation effects',
      (tester) async {
    final pending = Completer<void>();
    await _open(tester, remove: (_, {required revision}) => pending.future);
    await _confirm(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    pending.completeError(const NetworkException('迟到错误'));
    await _frames(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'editing return reloads detail and deletion uses its latest revision',
      (tester) async {
    var reads = 0;
    final calls = <int>[];
    await pumpPage(tester, const _Host(), routes: <String, WidgetBuilder>{
      HouseDetail.routeName: (_) => HouseDetail(
            houseDetailLoader: (_) async => ++reads == 1
                ? _house
                : _house.copyWith(revision: 8, name: '李四'),
            deleteHouseLoader: (_, {required revision}) async {
              calls.add(revision);
            },
          ),
      HouseForm.routeName: (context) => Scaffold(
              body: TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('完成编辑'),
          )),
    });
    await tester.tap(find.text('打开详情'));
    await _frames(tester);
    await tester.tap(find.text('修改房屋'));
    await _frames(tester);
    await tester.tap(find.text('完成编辑'));
    await _frames(tester);
    expect(reads, 2);
    expect(find.text('李四'), findsOneWidget);
    await _confirm(tester);
    expect(calls, <int>[8]);
    expect(find.byType(HouseDetail), findsNothing);
    await finishPage(tester);
  });

  testWidgets(
      'refresh in flight blocks deletion until latest detail is visible',
      (tester) async {
    final pending = Completer<House>();
    var reads = 0;
    final calls = <int>[];
    await _open(tester,
        load: (_) => ++reads == 1 ? Future.value(_house) : pending.future,
        remove: (_, {required revision}) async {
          calls.add(revision);
        });
    final staleClick = _deleteButton(tester).onPressed!;
    await tester.tap(find.byTooltip('刷新审核结果'));
    await tester.pump();
    staleClick();
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);
    expect(_deleteButton(tester).onPressed, isNull);
    pending.complete(_house.copyWith(revision: 9, name: '李四'));
    await _frames(tester);
    await _confirm(tester);
    expect(calls, <int>[9]);
    await finishPage(tester);
  });
}
