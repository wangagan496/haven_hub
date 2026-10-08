// Device-only fixture: real repair form and SharedPreferences, no backend calls.
// Uses reserved draft owners; never loads, writes or clears login credentials.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/models/house.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/pages/repair/repair_pages.dart';
import 'package:haven_hub/theme/app_theme.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/date_utils.dart';
import 'package:haven_hub/utils/repair_draft_store.dart';
import 'package:haven_hub/utils/toast.dart';
import 'package:haven_hub/utils/token_manager.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RepairLifecycleSmoke());
}

class RepairLifecycleSmoke extends StatefulWidget {
  const RepairLifecycleSmoke({super.key});

  @override
  State<RepairLifecycleSmoke> createState() => _RepairLifecycleSmokeState();
}

class _RepairLifecycleSmokeState extends State<RepairLifecycleSmoke> {
  String _account = 'A';
  bool _busy = false;
  int _submissions = 0;
  String _summary = '点击读取草稿查看真实本地存储。';
  String get _owner => 'repair-lifecycle-smoke:$_account';

  void _switchAccount(String account) {
    if (_account == account) return;
    // Only advance in-memory session identity; persisted credentials are untouched.
    tokenManager.invalidateLocalSession();
    setState(() => _account = account);
  }

  Future<void> _readDrafts() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final List<String> lines = <String>[];
      for (final String account in <String>['A', 'B']) {
        final RepairDraft? draft =
            await repairDraftStore.load('repair-lifecycle-smoke:$account');
        lines.add(draft == null
            ? '$account: 无草稿'
            : '$account: ${draft.record.description}; 未确认=${draft.resultUnconfirmed}');
      }
      if (mounted) setState(() => _summary = lines.join('\n'));
    } on Object catch (error) {
      if (!mounted) return;
      await PromptAction.showError(describeError(error, fallback: '读取失败'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _seedDraft() async {
    if (_busy) return;
    final String owner = _owner;
    final String account = _account;
    setState(() => _busy = true);
    try {
      final bool saved = await repairDraftStore.save(
        owner,
        RepairDraft(
          record: RepairRecord(
            houseId: 'smoke-house',
            repairItemId: 'smoke-item',
            mobile: '13800138000',
            appointment: formatDate(DateTime.now().add(const Duration(days: 1))),
            description: 'draft-$account',
          ),
        ),
      );
      if (!mounted) return;
      await PromptAction.showToast(saved ? '$account 测试草稿已写入' : '测试草稿写入失败');
    } on Object catch (error) {
      if (!mounted) return;
      await PromptAction.showError(describeError(error, fallback: '写入失败'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openForm() async {
    await GlobalVariable.navigatorKey.currentState!.push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => RepairFormPage(
          draftUserKey: () => _owner,
          houseLoader: () async => const <House>[
            House(id: 'smoke-house', point: '本地测试', building: '1栋', room: '101'),
          ],
          itemLoader: () async =>
              const <RepairItem>[RepairItem(id: 'smoke-item', name: '水管维修')],
          submitter: (_) async {
            setState(() => _submissions++);
            await Future<void>.delayed(const Duration(seconds: 20));
            throw const NetworkException('本地模拟超时', isTimeout: true);
          },
        ),
      ),
    );
    if (mounted) await _readDrafts();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: GlobalVariable.navigatorKey,
        theme: buildAppTheme(),
        locale: const Locale('zh'),
        supportedLocales: const <Locale>[Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => Column(
          children: <Widget>[
            Material(
              child: SafeArea(
                bottom: false,
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: <Widget>[
                    Text('测试账号 $_account · 发送 $_submissions 次'),
                    TextButton(onPressed: () => _switchAccount('A'), child: const Text('切到 A')),
                    TextButton(onPressed: () => _switchAccount('B'), child: const Text('切到 B')),
                  ],
                ),
              ),
            ),
            Expanded(child: child!),
          ],
        ),
        home: Scaffold(
          appBar: AppBar(title: const Text('报修设备验证')),
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: ListView(
              children: <Widget>[
                const Text('真实表单和本地存储；账号、房屋、提交响应为测试数据。提交等待 20 秒后超时，不调用服务端。'),
                const SizedBox(height: 16),
                FilledButton(onPressed: _busy ? null : _seedDraft, child: const Text('写入当前测试账号的初始草稿')),
                FilledButton(onPressed: _busy ? null : _openForm, child: const Text('打开正式报修表单')),
                OutlinedButton(onPressed: _busy ? null : _readDrafts, child: const Text('读取 A / B 草稿')),
                const SizedBox(height: 16),
                Text(_summary),
              ],
            ),
          ),
        ),
      );
}
