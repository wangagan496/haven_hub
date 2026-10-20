import 'dart:async';
import 'package:flutter/material.dart';
import '../../api/worker.dart';
import '../../models/repair.dart';
import '../../utils/app_exception.dart';
import '../../utils/date_utils.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';
import '../../widgets/repair_slot_picker.dart';
import 'worker_pages.dart';

String workforceOrderText(Map<String, dynamic> row) {
  final start = row['start'] as String? ?? '';
  final end = row['end'] as String? ?? '';
  final time = start.length >= 16 && end.length >= 16
      ? '${start.substring(5, 10)} ${start.substring(11, 16)}–${end.substring(11, 16)}' : '待定';
  return '${row['repairItemName']} · $time';
}

class WorkerPoolPage extends StatefulWidget {
  const WorkerPoolPage({super.key, this.loader = getWorkerRepairPoolApi, this.claim = claimWorkerRepairApi});
  final Future<List<RepairRecord>> Function() loader;
  final Future<RepairRecord> Function(RepairRecord, {String? slot}) claim;
  @override
  State<WorkerPoolPage> createState() => _WorkerPoolPageState();
}

class _WorkerPoolPageState extends State<WorkerPoolPage> {
  final int _session = tokenManager.sessionId;
  bool _isLoading = false;
  String? _error;
  List<RepairRecord> _rows = <RepairRecord>[];
  bool get _active => mounted && tokenManager.sessionId == _session;
  @override
  void initState() { super.initState(); unawaited(_load()); }
  Future<void> _load() async {
    if (_isLoading || !_active) return;
    setState(() { _isLoading = true; _error = null; });
    try {
      final rows = await widget.loader();
      if (!_active) return;
      setState(() => _rows = rows);
    } on Object catch (error) {
      if (_active) setState(() => _error = describeError(error, fallback: '可接单列表加载失败'));
    } finally { if (_active) setState(() => _isLoading = false); }
  }
  Future<void> _claim(RepairRecord record) async {
    if (_isLoading || !_active) return;
    setState(() => _isLoading = true);
    try {
      String? slot;
      if (record.slot.isEmpty) {
        final selected = await pickRepairSlot(context, excludeId: record.id, title: '接单并提议首次上门时间');
        if (!_active || selected == null) return;
        slot = selected.slot;
      }
      final accepted = await widget.claim(record, slot: slot);
      if (!_active) return;
      await PromptAction.showSuccess('接单成功');
      if (!mounted || !_active) return;
      await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => WorkerDetailPage(id: accepted.id)));
      if (!_active) return;
    } on Object catch (error) {
      if (!_active) return;
      await PromptAction.showError(describeError(error, fallback: '接单失败，请重试'));
      if (!_active) return;
    } finally {
      if (_active) { setState(() => _isLoading = false); unawaited(_load()); }
    }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('可接单'), actions: <Widget>[
      IconButton(tooltip: '刷新', onPressed: _isLoading ? null : _load, icon: const Icon(Icons.refresh)),
    ]),
    body: Column(children: <Widget>[
      if (_isLoading) const LinearProgressIndicator(),
      if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
      Expanded(child: RefreshIndicator(onRefresh: _load, child: ListView(
        physics: const AlwaysScrollableScrollPhysics(), children: <Widget>[
          const Padding(padding: EdgeInsets.all(16), child: Text('接单后可查看住户联系方式、完整地址和照片。')),
          if (!_isLoading && _rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('暂时没有适合你的工单，可检查“我的技能”或稍后刷新。')),
          for (final record in _rows) Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(record.repairItemName, style: Theme.of(context).textTheme.titleMedium),
              Text('上门时间：${record.agreedTime.isEmpty ? '待定' : formatVisitTime(record.agreedTime)}'),
              Text(record.houseInfo), Text(record.description),
              FilledButton(onPressed: _isLoading ? null : () => _claim(record), child: Text(record.slot.isEmpty ? '选择时间并接单' : '接单')),
            ]))),
        ]))),
    ]));
}

class WorkerSkillsPage extends StatefulWidget {
  const WorkerSkillsPage({super.key, this.loader = getWorkerSkillsApi, this.saver = saveWorkerSkillsApi});
  final Future<WorkerSkills> Function() loader;
  final Future<Map<String, dynamic>> Function(WorkerSkills, List<String>, {bool preview}) saver;
  @override
  State<WorkerSkillsPage> createState() => _WorkerSkillsPageState();
}

class _WorkerSkillsPageState extends State<WorkerSkillsPage> {
  final int _session = tokenManager.sessionId;
  WorkerSkills? _profile;
  final Set<String> _selected = <String>{};
  bool _isLoading = false;
  String? _error;
  bool get _active => mounted && tokenManager.sessionId == _session;
  @override
  void initState() { super.initState(); unawaited(_load()); }
  Future<void> _load() async {
    if (_isLoading || !_active) return;
    setState(() { _isLoading = true; _error = null; });
    try {
      final profile = await widget.loader();
      if (!_active) return;
      setState(() { _profile = profile; _selected..clear()..addAll(profile.skills); });
    } on Object catch (error) {
      if (_active) setState(() => _error = describeError(error, fallback: '技能加载失败'));
    } finally { if (_active) setState(() => _isLoading = false); }
  }
  Future<void> _save() async {
    final profile = _profile;
    if (_isLoading || !_active || profile == null) return;
    setState(() => _isLoading = true);
    try {
      final skills = _selected.toList();
      if (profile.skills.any((skill) => !_selected.contains(skill))) {
        final impact = await widget.saver(profile, skills, preview: true);
        if (!mounted || !_active) return;
        String summary(String key) {
          final rows = (impact[key] as List<dynamic>).cast<Map<String, dynamic>>();
          return rows.isEmpty ? '无' : rows.map(workforceOrderText).join('\n');
        }
        final shortages = (impact['shortages'] as List<dynamic>? ?? <dynamic>[]).cast<Map<String, dynamic>>();
        final shortageText = shortages.isEmpty ? '无' : shortages.map((item) =>
          '${item['message']}\n${(item['orders'] as List<dynamic>).cast<Map<String, dynamic>>().map(workforceOrderText).join('\n')}').join('\n\n');
        final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
          title: const Text('删除技能的影响'),
          content: SingleChildScrollView(child: Text('会放回可接单列表：\n${summary('returned')}\n\n需要物业处理：\n${summary('property')}\n\n时段缺人提示：\n$shortageText')),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认保存')),
          ]));
        if (!_active || confirmed != true) return;
      }
      final result = await widget.saver(profile, skills, preview: false);
      if (!_active) return;
      setState(() => _profile = WorkerSkills.fromJson(result));
      await PromptAction.showSuccess('技能已保存，立即生效');
      if (!mounted || !_active) return;
      Navigator.pop(context, true);
    } on Object catch (error) {
      if (!_active) return;
      setState(() => _error = describeError(error, fallback: '保存失败，请刷新后重试'));
      await PromptAction.showError(_error!);
    } finally { if (_active) setState(() => _isLoading = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('我的技能')),
    body: ListView(padding: const EdgeInsets.all(16), children: <Widget>[
      const Text('只登记你会的维修技能，保存后立即生效。技能由师傅自行登记，物业未核实，不代表资质认证。'),
      if (_isLoading) const LinearProgressIndicator(),
      if (_error != null) Text(_error!),
      for (final entry in const <String, String>{'plumbing': '水暖', 'electrical': '电气', 'doors': '门窗五金'}.entries)
        CheckboxListTile(title: Text(entry.value), value: _selected.contains(entry.key),
          onChanged: _isLoading || _profile == null ? null : (checked) => setState(() {
            if (checked ?? false) { _selected.add(entry.key); } else { _selected.remove(entry.key); }
          })),
      FilledButton(onPressed: _isLoading || _profile == null ? null : _save, child: const Text('保存技能')),
      TextButton(onPressed: _isLoading ? null : _load, child: const Text('重新加载')),
    ]));
}
