import 'package:flutter_test/flutter_test.dart';

import 'package:haven_hub/core/service_locator.dart';
import 'package:haven_hub/models/building_info.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/models/notice_data.dart';
import 'package:haven_hub/models/user_info.dart';
import 'package:haven_hub/utils/validators.dart';

class _FactoryValue {
  _FactoryValue();
}

class _LazyValue {
  const _LazyValue();
}

void main() {
  group('validators', () {
    test('required and mobile validators reject invalid values', () {
      expect(Validators.required().validate('   '), isNotNull);
      expect(Validators.mobile().validate('13800138000'), isNull);
      expect(Validators.mobile().validate('123'), isNotNull);
    });

    test('validators can be chained and stop at the first failure', () {
      final Validator validator =
          Validators.required().chain(Validators.mobile());

      expect(validator.validate(''), isNotNull);
      expect(validator.validate('13800138000'), isNull);
    });
  });

  group('models', () {
    test('BuildingInfo round trips typed fields', () {
      const BuildingInfo info = BuildingInfo(
        name: 'Community A',
        address: 'Main Street',
        building: '3',
        room: '402',
      );

      expect(BuildingInfo.fromJson(info.toJson()), info);
      expect(info.isComplete, isTrue);
      expect(info.copyWith(room: '501').room, '501');
    });

    test('House normalizes dynamic API values', () {
      final House house = House.fromJson(<String, dynamic>{
        'id': 12,
        'point': ' Community ',
        'building': '3',
        'room': 402,
        'name': 'Owner',
        'gender': '0',
        'status': '2',
      });

      expect(house.id, '12');
      expect(house.fullName, 'Community 3 402');
      expect(house.gender, 0);
      expect(house.isApproved, isTrue);
      expect(house.isPending, isFalse);
    });

    test('House reads idcard photos from alternate field names', () {
      // 详情接口的键名没有正式约定。读不到时编辑页会把已上传的照片显示成
      // 空白占位，提交时又被「请上传身份证正反面照片」拦下。
      expect(
        House.fromJson(<String, dynamic>{
          'idcardFront': ' https://example.com/front.png ',
          'idcardBack': 'https://example.com/back.png',
        }).idcardFrontUrl,
        'https://example.com/front.png',
      );

      expect(
        House.fromJson(<String, dynamic>{
          'idcard_front_url': 'https://example.com/front.png',
          'idcard_back_url': 'https://example.com/back.png',
        }).idcardBackUrl,
        'https://example.com/back.png',
      );
    });

    test('House prefers the canonical idcard keys when both are present', () {
      final House house = House.fromJson(<String, dynamic>{
        'idcardFrontUrl': 'https://example.com/canonical.png',
        'idcardFront': 'https://example.com/alias.png',
      });

      expect(house.idcardFrontUrl, 'https://example.com/canonical.png');
    });

    test('House leaves idcard photos empty when no candidate key matches', () {
      final House house = House.fromJson(<String, dynamic>{
        'id': 1,
        'idcardFront': '   ',
      });

      expect(house.idcardFrontUrl, isEmpty);
      expect(house.idcardBackUrl, isEmpty);
    });

    test('notice and user models parse API payloads', () {
      final NoticeData notice = NoticeData.fromJson(<String, dynamic>{
        'id': 7,
        'title': 'Notice',
        'content': 'Content',
        'createdAt': '2024-01-02T03:04:05.000Z',
        'creatorName': 'Admin',
      });
      final UserInfo user = UserInfo.fromJson(<String, dynamic>{
        'id': 8,
        'avatar': ' https://example.com/avatar.png ',
        'nickName': ' Alice ',
      });

      expect(notice.id, '7');
      expect(notice.date, '2024-01-02 03:04:05');
      expect(user.id, '8');
      expect(user.avatarUrl, 'https://example.com/avatar.png');
      expect(user.nickName, 'Alice');
    });
  });

  group('ServiceLocator', () {
    tearDown(sl.reset);

    test('factory creates a fresh instance for every lookup', () {
      sl.registerFactory<_FactoryValue>(_FactoryValue.new);

      expect(
          identical(sl.get<_FactoryValue>(), sl.get<_FactoryValue>()), isFalse);
    });

    test('lazy singleton is created once and can be replaced', () {
      sl.registerLazySingleton<_LazyValue>(() => const _LazyValue());

      final _LazyValue first = sl.get<_LazyValue>();
      final _LazyValue second = sl.get<_LazyValue>();
      expect(identical(first, second), isTrue);

      const _LazyValue replacement = _LazyValue();
      sl.replace<_LazyValue>(replacement);
      expect(identical(sl.get<_LazyValue>(), replacement), isTrue);
    });
  });
}
