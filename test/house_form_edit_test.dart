import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:haven_hub/controller/build_controller.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/pages/house/house_form.dart';
import 'package:haven_hub/router/app_routes.dart';

import 'helpers/widget_harness.dart';

const House _detail = House(
  id: 'house-1',
  point: '测试小区',
  building: '1栋',
  room: '101',
  name: '张三',
  mobile: '13800138000',
  idcardFrontUrl: 'https://example.com/front.png',
  idcardBackUrl: 'https://example.com/back.png',
  status: 2,
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
  setUp(() {
    Get.reset();
    BuildController.instance()
      ..updateBuildingInfo(<String, dynamic>{
        'name': '测试小区',
        'address': '测试地址',
      })
      ..updateBuild('1栋')
      ..updateRoom('101');
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

    await tester.tap(find.text('提交审核'));
    await _settleFrames(tester);

    expect(submitted, isNotNull);
    expect(submitted!.id, 'house-1', reason: '编辑模式应带上原有 id');

    // 用户可能是从「添加房屋」流程点进来的，这份选楼上下文之后还要用，
    // 编辑完不能顺手清掉。
    final BuildController controller = BuildController.instance();
    expect(controller.buildingInfo.name, '测试小区');
    expect(controller.build, '1栋');
    expect(controller.room, '101');
    expect(controller.buildingInfo.isComplete, isTrue);

    await finishPage(tester);
  });
}
