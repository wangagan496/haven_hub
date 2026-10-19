import 'dart:async';
import 'package:flutter/material.dart';
import '../api/repair.dart';
import '../models/repair.dart';
import '../utils/app_exception.dart';
import '../utils/date_utils.dart';
import '../utils/token_manager.dart';

Future<RepairSlot?> pickRepairSlot(BuildContext context, {String? initialSlot, String? excludeId,
  String title = '选择上门时段', RepairSlotsLoader loader = getRepairSlotsApi}) =>
    showModalBottomSheet<RepairSlot>(context: context, isScrollControlled: true,
      builder: (_) => RepairSlotPicker(initialSlot: initialSlot, excludeId: excludeId, title: title, loader: loader));

class RepairSlotPicker extends StatefulWidget {
  const RepairSlotPicker({this.initialSlot, this.excludeId, this.title = '选择上门时段',
    this.loader = getRepairSlotsApi, super.key});
  final String? initialSlot;
  final String? excludeId;
  final String title;
  final RepairSlotsLoader loader;
  @override
  State<RepairSlotPicker> createState() => _RepairSlotPickerState();
}

class _RepairSlotPickerState extends State<RepairSlotPicker> with WidgetsBindingObserver {
  RepairSlots? _data;
  String? _date;
  String? _error;
  bool _isLoading = false;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load(initial: true));
  }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }
  Future<void> _load({bool initial = false}) async {
    final int request = ++_request;
    final int session = tokenManager.sessionId;
    setState(() { _isLoading = true; _error = null; });
    try {
      // 首次和前台刷新先取得服务端 today/dates，再请求仍有效的所选日期。
      RepairSlots data = await widget.loader(excludeId: widget.excludeId);
      if (!mounted || request != _request || session != tokenManager.sessionId) return;
      final String? initialDate = widget.initialSlot?.split('#').first;
      final String? preferred = initial ? initialDate : _date;
      final String date = data.dates.contains(preferred) ? preferred! : data.today;
      if (date != data.today) data = await widget.loader(date: date, excludeId: widget.excludeId);
      if (!mounted || request != _request || session != tokenManager.sessionId) return;
      setState(() { _data = data; _date = date; });
    } on Object catch (error) {
      if (mounted && request == _request && session == tokenManager.sessionId) setState(() { _data = null; _error = describeError(error, fallback: '时段查询失败，请重试'); });
    } finally { if (mounted && request == _request) setState(() => _isLoading = false); }
  }
  @override
  Widget build(BuildContext context) {
    final RepairSlots? data = _data;
    final List<RepairSlot> selectable = data?.slots.where((RepairSlot item) => item.selectable).toList() ?? <RepairSlot>[];
    const Map<String, String> periods = <String, String>{'morning': '上午', 'afternoon': '下午', 'evening': '晚上'};
    return SafeArea(child: SizedBox(height: MediaQuery.sizeOf(context).height * .78,
      child: ListView(padding: const EdgeInsets.all(20), children: <Widget>[
        Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (_isLoading) const LinearProgressIndicator(),
        if (_error != null) ...<Widget>[Text(_error!), TextButton(onPressed: _isLoading ? null : _load, child: const Text('重试'))],
        if (!_isLoading && _error == null && data != null) ...<Widget>[
          Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
            for (final String date in data.dates) ChoiceChip(
              label: Text('${date == data.today ? '今天 ' : ''}${date.substring(5)}'),
              selected: _date == date, onSelected: (_) { _date = date; unawaited(_load()); }),
          ]),
          for (final MapEntry<String, String> period in periods.entries) ...<Widget>[
            const SizedBox(height: 16), Text(period.value, style: Theme.of(context).textTheme.titleMedium),
            Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
              for (final RepairSlot item in selectable.where((RepairSlot item) => item.period == period.key))
                ActionChip(key: ValueKey(item.slot), label: Text('${item.start.substring(11, 16)}–${item.end.substring(11, 16)}'),
                  onPressed: () => Navigator.pop(context, item)),
            ]),
          ],
          if (selectable.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Text('可选其他日期或提交待安排')),
        ],
      ])));
  }
}

/// 旧草稿只做精确匹配，合法时间由服务端返回的时段集合决定。
Future<RepairSlot?> matchDraftSlot(String expectedTime, RepairSlotsLoader loader) async {
  final DateTime? instant = DateTime.tryParse(expectedTime);
  final bool hasZone = expectedTime.endsWith('Z') ||
      (expectedTime.length > 19 && (expectedTime.substring(19).contains('+') || expectedTime.substring(19).contains('-')));
  if (instant == null || !expectedTime.contains('T') || !hasZone) return null;
  final DateTime business = instant.toUtc().add(const Duration(hours: 8));
  final String date = formatDate(business);
  final RepairSlots today = await loader();
  if (!today.dates.contains(date)) return null;
  final RepairSlots data = date == today.today ? today : await loader(date: date);
  for (final RepairSlot item in data.slots) {
    if (item.selectable && (DateTime.tryParse(item.start)?.isAtSameMomentAs(instant) ?? false)) return item;
  }
  return null;
}
