import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/home.dart';
import 'package:haven_hub/api/house.dart';
import 'package:haven_hub/api/repair.dart';
import 'package:haven_hub/api/user.dart';
import 'package:haven_hub/api/visitor.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/models/visitor.dart';
import 'package:haven_hub/platform/visitor_pass_share.dart';
import 'package:haven_hub/utils/logger.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 显式开启且只允许回环地址，防止普通测试连接日常开发数据库或外部服务器。
const bool enabled = bool.fromEnvironment('RUN_LOCAL_BACKEND_TEST');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real Dart API -> local HTTP server -> persistent SQLite round trip',
      () async {
    final Uri base = Uri.parse(GlobalVariable.baseUrl);
    expect(base.host, anyOf('127.0.0.1', 'localhost'));
    HttpOverrides.global = null; // Flutter测试默认拦截网络；此用例明确联调本机。
    Logger.enabled = false;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();
    final String mobile =
        '139${DateTime.now().microsecondsSinceEpoch.toString().substring(8).padLeft(8, '0')}';
    final code = await sendCodeApi(mobile);
    expect(code['development'], isTrue);
    final login = await loginApi(mobile, code['code'] as String);
    await tokenManager.setToken(login['token'] as String,
        refreshToken: login['refreshToken'] as String);
    final user = await getUserInfoApi();
    expect(user.id, isNotEmpty);
    expect(await getAnnouncementListApi(), isNotEmpty);
    final Uint8List png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9X8AAAAASUVORK5CYII=');
    final url = await uploadPhotoAPI(fileBytes: png, fileName: 'example.png');
    final house = House(
        point: '联调小区',
        building: '1栋',
        room: '101',
        name: '张三',
        mobile: mobile,
        idcardFrontUrl: url,
        idcardBackUrl: url);
    await submitHouseAPI(house);
    final saved = (await getHouseListApi()).single;
    expect(saved.id, isNotEmpty);
    expect(saved.status, 1);
    await submitHouseAPI(saved.copyWith(room: '102'));
    expect((await getHouseDetailApi(saved.id)).room, '102');
    expect((await getHouseListApi()).single.room, '102');
    await submitRepairApi(RepairRecord(
        houseId: saved.id,
        repairItemId: '1001',
        mobile: mobile,
        appointment: '2026-10-20',
        description: '本地自动联调'));
    final repair = (await getPreloadedRepairListApi()).single;
    expect(repair.status, 1);
    await cancelRepairApi(repair.id);
    expect((await getPreloadedRepairListApi()).single.status, 0);
    await submitVisitorApi(VisitorRecord(
        houseId: saved.id,
        name: '李四',
        mobile: mobile,
        visitDate: '2026-10-20'));
    final visitor = (await getVisitorListApi()).single;
    expect(visitor.canShare, isTrue);
    final image = await loadVisitorPassImage(visitor.url);
    expect(image.length, greaterThan(100));
    final profile = await updateUserInfoApi(nickName: '联调用户', avatar: url);
    expect(profile['id'], user.id);
    await deleteHouseApi(saved.id);
    expect(await getHouseListApi(), isEmpty);
    await tokenManager.deleteToken();
  }, skip: !enabled);
}
