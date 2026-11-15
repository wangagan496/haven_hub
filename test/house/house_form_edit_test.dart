import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:haven_hub/controller/build_controller.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/pages/house/house_form.dart';
import 'package:haven_hub/router/app_routes.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/widgets/image_preview.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/widget_harness.dart';

const House _detail = House(
  id: 'house-1',
  point: '测试小区',
  building: '1栋',
  room: '101',
  floor: '63',
  name: '张三',
  mobile: '13800138000',
  idcardFrontUrl: 'https://example.com/front.png',
  idcardBackUrl: 'https://example.com/back.png',
  status: 2,
  revision: 7,
);

/// 表单要挂在别的路由上，才能正常 pop 回去。
class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.pushNamed(
              context,
              HouseForm.routeName,
              arguments: const HouseFormArguments(
                mode: HouseFormMode.edit,
                houseId: 'house-1',
              ),
            ),
            child: const Text('打开表单'),
          ),
        ),
      );
}

/// 推进动画与异步回调若干帧。
///
/// 这里不能用 [WidgetTester.pumpAndSettle]：表单里的证件照是网络图片，加载
/// 期间会一直转菊花，那是个无限动画，pumpAndSettle 会一直等到超时。
Future<void> _settleFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  setUp(() async {
    Get.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.loadTokens();
    BuildController.instance()
      ..selectCommunity(<String, dynamic>{
        'name': '测试小区',
        'address': '测试地址',
      })
      ..selectBuilding('1栋')
      ..selectRoom('101');
  });

  testWidgets('editing an existing house keeps the building selection',
      (WidgetTester tester) async {
    // 放大视口，让整个表单一次渲染完。ListView 是懒加载的，默认尺寸下
    // 底部的「提交审核」根本不会被构建出来。
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    House? submitted;
    await pumpPage(
      tester,
      const _Host(),
      routes: <String, WidgetBuilder>{
        HouseForm.routeName: (_) => HouseForm(
              houseDetailLoader: (String id) async => _detail,
              submitHouseLoader: (House house) async {
                submitted = house;
              },
            ),
      },
    );

    await tester.tap(find.text('打开表单'));
    await _settleFrames(tester);

    await tester.enterText(find.byType(TextField).first, 'John Smith');
    await tester.tap(find.bySemanticsLabel('点击查看大图').first);
    await _settleFrames(tester);
    expect(find.byType(ImagePreview), findsOneWidget);
    await tester.tap(find.byTooltip('关闭预览'));
    await _settleFrames(tester);

    await tester.tap(find.text('提交审核'));
    await _settleFrames(tester);

    expect(submitted, isNotNull);
    expect(submitted!.id, 'house-1', reason: '编辑模式应带上原有 id');
    expect(submitted!.name, 'John Smith', reason: '英文姓名必须通过整表提交校验');
    expect(submitted!.floor, '63', reason: '编辑业主信息应保留已登记的楼层');
    expect(submitted!.revision, 7, reason: '编辑必须携带读取资料时的版本');

    // 用户可能是从「添加房屋」流程点进来的，这份选楼上下文之后还要用，
    // 编辑完不能顺手清掉。
    final BuildController controller = BuildController.instance();
    expect(controller.buildingInfo.name, '测试小区');
    expect(controller.build, '1栋');
    expect(controller.room, '101');
    expect(controller.buildingInfo.isComplete, isTrue);

    await finishPage(tester);
  });

  testWidgets('duplicate English name returned by server marks the name field',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var submitCalls = 0;
    await pumpPage(tester, const _Host(), routes: <String, WidgetBuilder>{
      HouseForm.routeName: (_) => HouseForm(
            houseDetailLoader: (String id) async => _detail,
            submitHouseLoader: (House house) async {
              submitCalls++;
              throw const BusinessException('该英文姓名已被登记，请更换姓名', code: 40002);
            },
          ),
    });

    await tester.tap(find.text('打开表单'));
    await _settleFrames(tester);
    await tester.enterText(find.byType(TextFormField).first, 'John Smith');
    await tester.tap(find.text('提交审核'));
    await _settleFrames(tester);

    expect(submitCalls, 1);
    final Finder nameField = find.byType(TextFormField).first;
    expect(tester.state<FormFieldState<String>>(nameField).errorText,
        '该英文姓名已被登记，请更换姓名');
    expect(find.text('该英文姓名已被登记，请更换姓名'), findsOneWidget);

    await tester.enterText(nameField, 'Jane Smith');
    await tester.pump();
    expect(tester.state<FormFieldState<String>>(nameField).errorText, isNull);
    await finishPage(tester);
  });

  for (final Object conflict in <Object>[
    const NetworkException('房屋已更新', statusCode: 409),
    const BusinessException('房屋已更新', code: 40900),
  ]) {
    testWidgets(
        'edit conflict preserves input and reloads only with consent: ${conflict.runtimeType}',
        (WidgetTester tester) async {
      var reads = 0;
      final submitted = <House>[];
      await _openEdit(
          tester,
          HouseForm(
            houseDetailLoader: (_) async => ++reads == 1
                ? _detail
                : _detail.copyWith(
                    name: '王五', mobile: '13800138002', revision: 8, status: 1),
            submitHouseLoader: (house) async {
              submitted.add(house);
              if (submitted.length == 1) throw conflict;
            },
          ));
      await tester.enterText(find.byType(TextFormField).first, '李四');
      await tester.enterText(find.byType(TextFormField).at(1), '13800138001');
      await tester.tap(find.text('提交审核'));
      await _settleFrames(tester);
      expect(submitted.single.revision, 7);
      expect(_fieldText(tester, 0), '李四');
      expect(_fieldText(tester, 1), '13800138001');
      expect(find.bySemanticsLabel('点击查看大图'), findsNWidgets(2));
      expect(_submitButton(tester).onPressed, isNull);
      expect(reads, 1, reason: '冲突不能自动重读或自动套用新版本');
      await tester.tap(find.text('重新加载最新资料'));
      await _settleFrames(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('保留当前填写'));
      await _settleFrames(tester);
      expect(reads, 1);
      expect(_fieldText(tester, 0), '李四');
      expect(_submitButton(tester).onPressed, isNull);
      await _confirmReload(tester);
      expect(reads, 2);
      expect(submitted, hasLength(1), reason: '加载成功也不能自动重放旧提交');
      expect(_fieldText(tester, 0), '王五');
      expect(_fieldText(tester, 1), '13800138002');
      expect(find.text('审核状态：待审核'), findsOneWidget);
      expect(_submitButton(tester).onPressed, isNotNull);
      await tester.enterText(find.byType(TextFormField).first, '赵六');
      await tester.tap(find.text('提交审核'));
      await _settleFrames(tester);
      expect(submitted, hasLength(2));
      expect(submitted.last.revision, 8);
      expect(submitted.last.name, '赵六');
      expect(submitted.last.idcardFrontUrl, _detail.idcardFrontUrl);
      expect(find.text('打开表单'), findsOneWidget);
      await finishPage(tester);
    });
  }

  testWidgets(
      'failed conflict reload keeps local input and remains blocked until a successful reload',
      (tester) async {
    var reads = 0;
    var writes = 0;
    await _openEdit(
        tester,
        HouseForm(
          houseDetailLoader: (_) async {
            reads++;
            if (reads == 2) throw const NetworkException('暂时无法读取');
            return reads == 1
                ? _detail
                : House.fromJson(<String, dynamic>{
                    ..._detail.toJson(),
                    'name': '王五',
                    'revision': 9,
                    'status': 3,
                    'reviewReason': '照片不清晰',
                  });
          },
          submitHouseLoader: (_) async {
            writes++;
            throw const NetworkException('资料已更新', statusCode: 409);
          },
        ));
    await tester.enterText(find.byType(TextFormField).first, '李四');
    await tester.tap(find.text('提交审核'));
    await _settleFrames(tester);
    await _confirmReload(tester);
    expect(_fieldText(tester, 0), '李四');
    expect(find.text('暂时无法读取'), findsWidgets);
    expect(_submitButton(tester).onPressed, isNull);
    expect(writes, 1);
    await _confirmReload(tester);
    expect(_fieldText(tester, 0), '王五');
    expect(find.text('打回原因：照片不清晰'), findsOneWidget);
    expect(_submitButton(tester).onPressed, isNotNull);
    expect(writes, 1);
    await finishPage(tester);
  });

  testWidgets(
      'pending conflict reload blocks editing, photos, duplicate reloads and submission',
      (tester) async {
    var reads = 0;
    var writes = 0;
    final pending = Completer<House>();
    await _openEdit(
        tester,
        HouseForm(
          houseDetailLoader: (_) =>
              ++reads == 1 ? Future.value(_detail) : pending.future,
          submitHouseLoader: (_) async {
            writes++;
            throw const NetworkException('资料已更新', statusCode: 409);
          },
        ));
    await tester.tap(find.text('提交审核'));
    await _settleFrames(tester);
    await _confirmReload(tester);
    expect(reads, 2);
    expect(
        tester.widget<TextFormField>(find.byType(TextFormField).first).enabled,
        isFalse);
    expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.delete).first)
            .onPressed,
        isNull);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '重新加载最新资料'))
            .onPressed,
        isNull);
    expect(_submitButton(tester).onPressed, isNull);
    pending.complete(_detail.copyWith(name: '王五', revision: 8));
    await _settleFrames(tester);
    expect(_fieldText(tester, 0), '王五');
    expect(writes, 1);
    expect(tester.takeException(), isNull);
    await finishPage(tester);
  });

  for (final bool switchAccount in <bool>[false, true]) {
    testWidgets(
        'late reload is ignored after ${switchAccount ? 'account change' : 'disposal'}',
        (tester) async {
      var reads = 0;
      final pending = Completer<House>();
      await _openEdit(
          tester,
          HouseForm(
            houseDetailLoader: (_) =>
                ++reads == 1 ? Future.value(_detail) : pending.future,
            submitHouseLoader: (_) async =>
                throw const NetworkException('资料已更新', statusCode: 409),
          ));
      await tester.tap(find.text('提交审核'));
      await _settleFrames(tester);
      await _confirmReload(tester);
      if (switchAccount) {
        await tokenManager.setToken('house-other-account');
      } else {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      pending.complete(_detail.copyWith(name: '迟到资料', revision: 8));
      await _settleFrames(tester);
      expect(find.text('迟到资料'), findsNothing);
      expect(tester.takeException(), isNull);
      await finishPage(tester);
    });
  }

  testWidgets('photo selection prevents a concurrent conflict reload',
      (tester) async {
    final picking = Completer<XFile?>();
    var reads = 0;
    await _openEdit(
        tester,
        HouseForm(
          houseDetailLoader: (_) async {
            reads++;
            return _detail;
          },
          photoPicker: (_) => picking.future,
          submitHouseLoader: (_) async =>
              throw const NetworkException('资料已更新', statusCode: 409),
        ));
    await tester.tap(find.text('提交审核'));
    await _settleFrames(tester);
    await tester.tap(find.byTooltip('删除照片').first);
    await tester.pump();
    await tester.tap(find.text('上传人像面照片'));
    await _settleFrames(tester);
    await tester.tap(find.text('相册'));
    await _settleFrames(tester);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '重新加载最新资料'))
            .onPressed,
        isNull);
    expect(reads, 1);
    picking.complete(null);
    await _settleFrames(tester);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '重新加载最新资料'))
            .onPressed,
        isNotNull);
    await finishPage(tester);
  });
}

Future<void> _openEdit(WidgetTester tester, HouseForm form) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await pumpPage(tester, const _Host(),
      routes: <String, WidgetBuilder>{HouseForm.routeName: (_) => form});
  await tester.tap(find.text('打开表单'));
  await _settleFrames(tester);
}

String _fieldText(WidgetTester tester, int index) => tester
    .widget<TextFormField>(find.byType(TextFormField).at(index))
    .controller!
    .text;

ElevatedButton _submitButton(WidgetTester tester) =>
    tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '提交审核'));

Future<void> _confirmReload(WidgetTester tester) async {
  await tester.tap(find.text('重新加载最新资料'));
  await _settleFrames(tester);
  await tester.tap(find.text('替换为最新资料'));
  await _settleFrames(tester);
}
