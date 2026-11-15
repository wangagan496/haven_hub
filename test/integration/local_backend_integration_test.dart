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
import 'package:haven_hub/models/repair_page.dart';
import 'package:haven_hub/models/visitor.dart';
import 'package:haven_hub/platform/visitor_pass_share.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/client_identity.dart';
import 'package:haven_hub/utils/house_submission_store.dart';
import 'package:haven_hub/utils/logger.dart';
import 'package:haven_hub/utils/repair_draft_store.dart';
import 'package:haven_hub/utils/request_dio.dart';
import 'package:haven_hub/utils/submission_id.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/utils/visitor_submission_store.dart';
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
    await tokenManager.loadTokens();
    final String mobile =
        '139${DateTime.now().microsecondsSinceEpoch.toString().substring(8).padLeft(8, '0')}';
    final code = await sendCodeApi(mobile);
    expect(code['development'], isTrue);
    final login = await loginApi(mobile, code['code'] as String);
    await tokenManager.setToken(login['token'] as String,
        refreshToken: login['refreshToken'] as String);
    final user = await getUserInfoApi();
    expect(user.id, isNotEmpty);
    final obsolete = RequestDio(identity: const ClientIdentity(version: '0.0.0', platform: 'ohos'));
    final tokenBeforeUpgrade = tokenManager.getToken();
    await expectLater(obsolete.put('userInfo', data: <String, dynamic>{'nickName': '不应保存'}),
        throwsA(isA<NetworkException>().having((e) => e.statusCode, 'upgrade status', 426)
            .having((e) => e.message, 'upgrade message', contains('升级'))));
    expect(tokenManager.getToken(), tokenBeforeUpgrade);
    expect((await getUserInfoApi()).nickName, user.nickName);
    expect(await getAnnouncementListApi(), isNotEmpty);
    // Valid 1x1 RGBA PNG; all chunk CRCs were checked independently.
    final Uint8List png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACXBIWXMAAAPoAAAD6AG1e1JrAAAADUlEQVQImWP4////fwAJ+wP9CNHoHgAAAABJRU5ErkJggg==');
    final url = await uploadPhotoAPI(fileBytes: png, fileName: 'example.png');
    final house = House(
        point: '联调小区',
        building: '1栋',
        room: '101',
        name: '张三',
        mobile: mobile,
        idcardFrontUrl: url,
        idcardBackUrl: url);
    final houseSubmission =
        HouseSubmissionStore.prepare(house, draftId: newSubmissionId());
    await submitHouseAPI(houseSubmission.house);
    await submitHouseAPI(houseSubmission.house);
    final saved = (await getHouseListApi()).single;
    final houseReceipt = await getHouseSubmissionApi(houseSubmission.id);
    expect(houseReceipt.state, HouseSubmissionState.created);
    expect(houseReceipt.createdId, saved.id);
    expect(saved.id, isNotEmpty);
    expect(saved.status, 1);
    expect(saved.revision, 1);
    await submitHouseAPI(saved.copyWith(room: '102'));
    expect((await getHouseDetailApi(saved.id)).room, '102');
    expect((await getHouseListApi()).single.room, '102');
    await expectLater(
        submitHouseAPI(saved.copyWith(room: '999')),
        throwsA(isA<NetworkException>()
            .having((e) => e.statusCode, 'status', 409)));
    final latestHouse = await getHouseEditDetailApi(saved.id);
    expect(latestHouse.room, '102');
    expect(latestHouse.revision, 2);
    await submitHouseAPI(latestHouse.copyWith(name: '李四'));
    expect((await getHouseEditDetailApi(saved.id)).revision, 3);
    final submission = RepairDraft.prepareSubmission(RepairRecord(
        houseId: saved.id,
        repairItemId: '1001',
        mobile: mobile,
        appointment: '2026-10-20',
        description: '本地自动联调'));
    final createdId = await submitRepairApi(submission);
    expect(createdId, isNotEmpty);
    expect(await getRepairSubmissionApi(submission.submissionId), createdId);
    expect(await submitRepairApi(submission), createdId);
    final repair = (await getPreloadedRepairListApi()).single;
    expect(repair.status, 1);
    expect(repair.confirmationAction?.reasonCode, 'not_in_progress');
    expect(repair.canConfirm, isFalse);
    final pendingPage = await getRepairPageApi(pageSize: 1, filter: RepairStatusFilter.pending);
    expect(pendingPage.rows.single.id, repair.id);
    expect(pendingPage.total, 1);
    expect(pendingPage.hasMore, isFalse);
    expect((await getRepairPageApi(filter: RepairStatusFilter.completed)).rows, isEmpty);
    await preloadRepairList();
    final warmed = await getPreloadedRepairPageApi(current: 1, filter: RepairStatusFilter.all, usePreload: true);
    expect(warmed.rows.single.id, repair.id);
    await preloadRepairList(); // 下方取消操作必须让旧的待派单预加载失效。
    expect((await getRepairDetailApi(repair.id)).confirmationAction?.reasonCode,
        'not_in_progress');
    await expectLater(cancelRepairApi(repair.id, revision: repair.revision + 1),
        throwsA(isA<NetworkException>().having((e) => e.statusCode, 'status', 409)));
    final cancellingRepair = await getRepairDetailApi(repair.id);
    expect(cancellingRepair.status, repair.status);
    expect(cancellingRepair.revision, repair.revision);
    await cancelRepairApi(repair.id, revision: cancellingRepair.revision);
    final cancelled = (await getPreloadedRepairListApi()).single;
    expect(cancelled.status, 0);
    expect(cancelled.confirmationAction?.reasonCode, 'cancelled');
    expect(cancelled.canConfirm, isFalse);
    final afterCancel = await getPreloadedRepairPageApi(current: 1, filter: RepairStatusFilter.all, usePreload: true);
    expect(afterCancel.rows.single.status, 0);
    expect((await getRepairPageApi(filter: RepairStatusFilter.pending)).total, 0);
    final visitorSubmission = VisitorSubmissionStore.prepare(VisitorRecord(
        houseId: saved.id,
        name: '李四',
        mobile: mobile,
        visitDate: '2026-10-20'));
    await submitVisitorApi(visitorSubmission);
    final receipt =
        await getVisitorSubmissionApi(visitorSubmission.submissionId);
    expect(receipt.state, VisitorSubmissionState.created);
    await submitVisitorApi(visitorSubmission);
    final visitor = (await getVisitorListApi()).single;
    expect(visitor.id, receipt.createdId);
    final stoppedCreated =
        await closeVisitorSubmissionApi(visitorSubmission.submissionId);
    expect(stoppedCreated.state, VisitorSubmissionState.created);
    expect(stoppedCreated.createdId, visitor.id);
    final stopped = VisitorSubmissionStore.prepare(visitorSubmission);
    expect((await getVisitorSubmissionApi(stopped.submissionId)).state,
        VisitorSubmissionState.unknown);
    expect((await closeVisitorSubmissionApi(stopped.submissionId)).state,
        VisitorSubmissionState.closed);
    await expectLater(
        submitVisitorApi(stopped),
        throwsA(isA<NetworkException>()
            .having((e) => e.statusCode, 'status', 409)));
    expect((await getVisitorListApi()).single.id, visitor.id);
    expect(visitor.canShare, isTrue);
    final image = await loadVisitorPassImage(visitor.url);
    expect(image.length, greaterThan(100));
    final avatarUrl =
        await uploadPhotoAPI(fileBytes: png, fileName: 'avatar.png');
    final profile =
        await updateUserInfoApi(nickName: '联调用户', avatar: avatarUrl);
    expect(profile['id'], user.id);
    await expectLater(
        deleteHouseApi(saved.id, revision: saved.revision),
        throwsA(isA<NetworkException>()
            .having((e) => e.statusCode, 'status', 409)));
    final deletingHouse = await getHouseEditDetailApi(saved.id);
    expect(deletingHouse.name, '李四');
    expect(deletingHouse.revision, 3);
    await deleteHouseApi(saved.id, revision: deletingHouse.revision);
    expect(await getHouseListApi(), isEmpty);
    expect((await getHouseSubmissionApi(houseSubmission.id)).state,
        HouseSubmissionState.deleted);
    expect((await closeHouseSubmissionApi(houseSubmission.id)).state,
        HouseSubmissionState.deleted);
    await expectLater(
        submitHouseAPI(houseSubmission.house),
        throwsA(isA<NetworkException>()
            .having((e) => e.statusCode, 'status', 409)));
    expect(await getHouseListApi(), isEmpty);
    await tokenManager.deleteToken();
  }, skip: !enabled);
}
