import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/models/user_info.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/platform/avatar_picker.dart';
import 'package:haven_hub/utils/repair_draft_store.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:haven_hub/widgets/repair_photos.dart';
import 'package:haven_hub/widgets/repair_progress.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/widget_harness.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.init();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  testWidgets(
      'eight photos keep the add button visible and disabled; seven enables it',
      (tester) async {
    await pumpPage(
        tester,
        Scaffold(
            body: RepairPhotos(
                urls: const [],
                editable: true,
                selectedCount: 8,
                onAdd: () {})));
    final button = find.byKey(const ValueKey('add-repair-photo'));
    expect(button, findsOneWidget);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    expect(find.text('现场照片（8/8）'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpPage(
        tester,
        Scaffold(
            body: RepairPhotos(
                urls: const [],
                editable: true,
                selectedCount: 7,
                onAdd: () {})));
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    await finishPage(tester);
  });
  testWidgets(
      'status summary omits the progress strip and preserves actual event times',
      (tester) async {
    await pumpPage(
        tester,
        const Scaffold(
            body: SingleChildScrollView(
                child: RepairProgress(
                    record: RepairRecord(
          status: 5,
          workflowVersion: 1,
          workerName: '张师傅',
          workerMobile: '13800138000',
          timeline: [
            RepairEvent(
                action: 'assigned', label: '物业派单', at: '2026-10-13T09:00:00Z')
          ],
        )))));
    expect(find.text('住户申请'), findsNothing);
    expect(find.text('物业派单'), findsNothing);
    expect(find.text('待接单'), findsOneWidget);
    expect(find.text('处理中'), findsNothing);
    expect(find.text('已完成'), findsNothing);
    expect(find.text('维修人员：张师傅'), findsOneWidget);
    expect(find.text('师傅接单'), findsNothing);
    expect(find.text('共1条记录'), findsOneWidget);
    await tester.tap(find.text('处理记录'));
    await tester.pumpAndSettle();
    expect(find.text('物业派单'), findsOneWidget);
    final time = DateTime.parse('2026-10-13T09:00:00Z').toLocal();
    final hours = time.hour.toString().padLeft(2, '0');
    expect(find.text('2026-10-13 $hours:00'), findsOneWidget);
    await finishPage(tester);
  });
  test('uploaded photos survive draft serialization', () async {
    final store = RepairDraftStore();
    const record = RepairRecord(attachment: ['https://example.test/photo.png']);
    expect(await store.save('resident', const RepairDraft(record: record)),
        isTrue);
    expect(
        (await store.load('resident'))!.record.attachment, record.attachment);
    expect(await store.load('other-resident'), isNull);
  });
  testWidgets(
      'failed uploads block submission until removed and can be retried',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    bool fail = true;
    final file = PickedAvatar(
        bytes: Uint8List.fromList([1, 2, 3]), fileName: 'test.png');
    await pumpPage(
        tester,
        RepairFormPage(
          draftUserKey: () => 'resident',
          userInfoLoader: () async => const UserInfo.empty(),
          houseLoader: () async =>
              const [House(id: 'h', point: '小区', building: '1栋', room: '101')],
          itemLoader: () async => const [RepairItem(id: 'i', name: '水管维修')],
          photoPicker: (remaining) async => [file],
          photoUploader: ({required fileBytes, required fileName}) async {
            if (fail) throw const FormatException('上传失败');
            return 'https://example.test/photo.png';
          },
        ));
    await tester.ensureVisible(find.byKey(const ValueKey('add-repair-photo')));
    await tester.tap(find.byKey(const ValueKey('add-repair-photo')));
    await tester.pumpAndSettle();
    expect(find.text('1张照片上传失败，离开页面前请重试或移除'), findsOneWidget);
    await tester.ensureVisible(find.text('提交报修'));
    await tester.tap(find.text('提交报修'));
    await tester.pumpAndSettle();
    expect(find.text('请重试或移除上传失败的照片'), findsWidgets);
    fail = false;
    await tester.ensureVisible(find.text('重试上传'));
    await tester.tap(find.text('重试上传'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('1张照片上传失败，离开页面前请重试或移除'), findsNothing);
    expect(find.text('现场照片（1/8）'), findsOneWidget);
    await tester.tap(find.byTooltip('删除第1张照片'));
    await tester.pump();
    await finishPage(tester);
    debugDefaultTargetPlatformOverride = null;
  });
}
