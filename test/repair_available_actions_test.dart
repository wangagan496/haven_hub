import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/token_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/widget_harness.dart';

Map<String, dynamic> _confirm(bool enabled, [String reason = '']) =>
    <String, dynamic>{
      'code': 'confirm',
      'enabled': enabled,
      'reasonCode': reason
    };

RepairRecord _record(Object? actions, {int revision = 1, int status = 6}) =>
    RepairRecord.fromJson(<String, dynamic>{
      'id': 'availability',
      'status': status,
      'revision': revision,
      'workflowVersion': 1,
      'resultReady': true,
      'availableActions': actions,
      'repairItemName': '测试维修',
      'description': '确认操作验收',
    });

Finder get _confirmButton => find.widgetWithText(FilledButton, '确认修好');

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tokenManager.loadTokens();
    await tokenManager.setToken('availability-test');
  });

  test(
      'server confirmation decision overrides legacy flags and legacy responses still work',
      () {
    expect(_record(<Object>[_confirm(false, 'revoke_pending')]).canConfirm,
        isFalse);
    final enabled = RepairRecord.fromJson(<String, dynamic>{
      'status': 2,
      'resultReady': false,
      'availableActions': <Object>[_confirm(true)]
    });
    expect(enabled.canConfirm, isTrue);
    expect(RepairRecord.fromJson(<String, dynamic>{'status': 6}).canConfirm,
        isTrue);
    expect(
        _record(<Object>[_confirm(true)])
            .toJson()
            .containsKey('availableActions'),
        isFalse);
  });

  test(
      'unknown, malformed, duplicated or contradictory action metadata fails closed',
      () {
    for (final actions in <Object?>[
      null,
      'invalid',
      <Object>[],
      <Object>[false],
      <Object>[
        <String, dynamic>{
          'code': 'future_action',
          'enabled': true,
          'reasonCode': ''
        }
      ],
      <Object>[
        <String, dynamic>{
          'code': 'confirm',
          'enabled': 'true',
          'reasonCode': ''
        }
      ],
      <Object>[
        <String, dynamic>{'code': 'confirm', 'enabled': true}
      ],
      <Object>[_confirm(true, 'unknown_reason')],
      <Object>[_confirm(true), _confirm(false, 'revoke_pending')],
    ]) {
      expect(_record(actions).canConfirm, isFalse, reason: '$actions');
    }
  });

  testWidgets('blocked confirmation explains why and cannot submit',
      (tester) async {
    var calls = 0;
    await pumpPage(
        tester,
        RepairDetailPage(
          loadRepairDetail: (_) async =>
              _record(<Object>[_confirm(false, 'result_not_ready')], status: 2),
          submitAction: (record, action) async {
            calls++;
            return record;
          },
        ),
        arguments: 'availability');
    expect(tester.widget<FilledButton>(_confirmButton).onPressed, isNull);
    expect(find.text('请等待师傅保存维修结果和费用后再确认'), findsOneWidget);
    expect(calls, 0);
    await finishPage(tester);
  });

  testWidgets('unknown reason never becomes executable or raw technical text',
      (tester) async {
    await pumpPage(
        tester,
        RepairDetailPage(
          loadRepairDetail: (_) async =>
              _record(<Object>[_confirm(false, 'future_reason')]),
        ),
        arguments: 'availability');
    expect(tester.widget<FilledButton>(_confirmButton).onPressed, isNull);
    expect(find.text('暂时无法确认修好，请刷新工单后重试'), findsOneWidget);
    expect(find.text('future_reason'), findsNothing);
    await finishPage(tester);
  });

  testWidgets(
      'version conflict refreshes decision without replaying confirmation',
      (tester) async {
    var reads = 0, writes = 0;
    await pumpPage(
        tester,
        RepairDetailPage(
          loadRepairDetail: (_) async => ++reads == 1
              ? _record(<Object>[_confirm(true)])
              : _record(<Object>[_confirm(false, 'revoke_pending')],
                  revision: 2),
          submitAction: (record, action) async {
            writes++;
            throw const NetworkException('记录已更新', statusCode: 409);
          },
        ),
        arguments: 'availability');
    await tester.tap(_confirmButton);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: _confirmButton));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(reads, 2);
    expect(tester.widget<FilledButton>(_confirmButton).onPressed, isNull);
    expect(find.text('请先处理撤销申请'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets(
      'account change while confirmation is open never submits the old record',
      (tester) async {
    var writes = 0;
    await pumpPage(
        tester,
        RepairDetailPage(
          loadRepairDetail: (_) async => _record(<Object>[_confirm(true)]),
          submitAction: (record, action) async {
            writes++;
            return record;
          },
        ),
        arguments: 'availability');
    await tester.tap(_confirmButton);
    await tester.pumpAndSettle();
    await tokenManager.deleteToken();
    await tokenManager.setToken('another-account');
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: _confirmButton));
    await tester.pumpAndSettle();
    expect(writes, 0);
    await finishPage(tester);
  });

  testWidgets(
      'refresh during an open confirmation requires the resident to review again',
      (tester) async {
    var reads = 0, writes = 0;
    await pumpPage(
        tester,
        RepairDetailPage(
          loadRepairDetail: (_) async =>
              _record(<Object>[_confirm(true)], revision: ++reads),
          submitAction: (record, action) async {
            writes++;
            return record;
          },
        ),
        arguments: 'availability');
    await tester.tap(_confirmButton);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(reads, 2);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: _confirmButton));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(find.text('工单状态已更新，请重新核对后再确认'), findsOneWidget);
    await finishPage(tester);
  });

  testWidgets(
      'rapid confirmation taps open one dialog and submit the reviewed revision once',
      (tester) async {
    var writes = 0;
    int? submittedRevision;
    await pumpPage(
        tester,
        RepairDetailPage(
          loadRepairDetail: (_) async =>
              _record(<Object>[_confirm(true)], revision: 7),
          submitAction: (record, action) async {
            writes++;
            submittedRevision = record.revision;
            return _record(<Object>[_confirm(false, 'already_completed')],
                revision: 8, status: 3);
          },
        ),
        arguments: 'availability');
    final onPressed = tester.widget<FilledButton>(_confirmButton).onPressed!;
    onPressed();
    onPressed();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: _confirmButton));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(submittedRevision, 7);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('已完成'), findsWidgets);
    expect(_confirmButton, findsNothing);
    await finishPage(tester);
  });

  testWidgets(
      'resume during confirmation submission cannot restore an old enabled action',
      (tester) async {
    var reads = 0;
    final submitted = Completer<RepairRecord>();
    final staleRefresh = Completer<RepairRecord>();
    await pumpPage(
        tester,
        RepairDetailPage(
          loadRepairDetail: (_) async => ++reads == 1
              ? _record(<Object>[_confirm(true)], revision: 7)
              : staleRefresh.future,
          submitAction: (record, action) => submitted.future,
        ),
        arguments: 'availability');
    await tester.tap(_confirmButton);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: _confirmButton));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    submitted.complete(_record(<Object>[_confirm(false, 'already_completed')],
        revision: 8, status: 3));
    await tester.pump();
    staleRefresh.complete(_record(<Object>[_confirm(true)], revision: 7));
    await tester.pumpAndSettle();
    expect(_confirmButton, findsNothing);
    expect(find.text('已完成'), findsWidgets);
    expect(reads, 1);
    await finishPage(tester);
  });
}
