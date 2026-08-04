import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/controller/build_controller.dart';
import 'package:haven_hub/pages/House/HouseForm.dart';

void main() {
  group('createHouseFormData', () {
    test('collects community, building, and room from BuildController', () {
      final BuildController controller = BuildController()
        ..updateBuildingInfo(<String, dynamic>{
          'name': '幸福小区',
          'address': '测试路1号',
        })
        ..updateBuild('幸福小区2栋')
        ..updateRoom('301');

      final Map<String, dynamic> formData = createHouseFormData(controller);

      expect(formData['point'], '幸福小区');
      expect(formData['building'], '幸福小区2栋');
      expect(formData['room'], '301');
      expect(formData['name'], '');
      expect(formData['gender'], 1);
      expect(formData['mobile'], '');
      expect(formData['idcardFrontUrl'], '');
      expect(formData['idcardBackUrl'], '');
    });
  });

  group('validateHouseFormData', () {
    late Map<String, dynamic> formData;

    setUp(() {
      formData = <String, dynamic>{
        'point': '幸福小区',
        'building': '幸福小区2栋',
        'room': '301',
        'name': '张三',
        'gender': 1,
        'mobile': '13800138000',
        'idcardFrontUrl': 'front.jpg',
        'idcardBackUrl': 'back.jpg',
      };
    });

    test('requires community, building, and room', () {
      for (final String field in <String>['point', 'building', 'room']) {
        final String originalValue = formData[field] as String;
        formData[field] = ' ';
        expect(validateHouseFormData(formData), '小区、楼栋、房间不能为空');
        formData[field] = originalValue;
      }
    });

    test('requires owner name', () {
      formData['name'] = '';

      expect(validateHouseFormData(formData), '业主姓名不能为空');
    });

    test('requires a 2-15 character Chinese owner name', () {
      for (final String invalidName in <String>[
        '张',
        '张三1',
        '一二三四五六七八九十一二三四五六',
      ]) {
        formData['name'] = invalidName;
        expect(validateHouseFormData(formData), '业主姓名须为2-15位中文');
      }
    });

    test('requires mobile number', () {
      formData['mobile'] = '';

      expect(validateHouseFormData(formData), '手机号不能为空');
    });

    test('requires valid mainland China mobile number', () {
      formData['mobile'] = '12800138000';

      expect(validateHouseFormData(formData), '手机号格式不正确');
    });

    test('requires both identity card photos', () {
      for (final String field in <String>['idcardFrontUrl', 'idcardBackUrl']) {
        final String originalValue = formData[field] as String;
        formData[field] = '';
        expect(validateHouseFormData(formData), '请上传身份证正反面照片');
        formData[field] = originalValue;
      }
    });

    test('accepts complete valid data', () {
      expect(validateHouseFormData(formData), isNull);
    });
  });
}
