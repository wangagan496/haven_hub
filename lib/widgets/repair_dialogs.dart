import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../utils/date_utils.dart';
import '../utils/toast.dart';

/// 选择具体上门时间：先选日期，再用“早、中、晚”快捷选项或时间选择器选具体几点。
/// 返回本地时间；取消返回 null。
Future<DateTime?> pickVisitTime(BuildContext context,
    {DateTime? initial, String title = '选择上门时间'}) async {
  final DateTime now = DateTime.now();
  final DateTime firstDate = DateUtils.dateOnly(now);
  final DateTime? date = await showDatePicker(
    context: context,
    helpText: title,
    initialDate: initial != null && !initial.isBefore(firstDate)
        ? DateUtils.dateOnly(initial)
        : firstDate,
    firstDate: firstDate,
    lastDate: firstDate.add(const Duration(days: 365)),
  );
  if (date == null || !context.mounted) return null;
  final TimeOfDay? time = await showModalBottomSheet<TimeOfDay>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext sheet) => _TimeSheet(
      date: date,
      initial: initial == null ? null : TimeOfDay.fromDateTime(initial),
    ),
  );
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

class _TimeSheet extends StatelessWidget {
  const _TimeSheet({required this.date, this.initial});
  final DateTime date;
  final TimeOfDay? initial;

  bool _passed(int hour) {
    final DateTime now = DateTime.now();
    return DateTime(date.year, date.month, date.day, hour).isBefore(now);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('${date.month}月${date.day}日 选择具体时间',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text('早、中、晚只是快捷选项，请点选具体几点',
                  style: TextStyle(color: AppColors.textTertiary, fontSize: 13)),
              for (final VisitPeriod period in VisitPeriod.values) ...<Widget>[
                const SizedBox(height: 14),
                Text(period.label,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
                  for (final int hour in period.hours)
                    ChoiceChip(
                      label: Text('${hour.toString().padLeft(2, '0')}:00'),
                      selected: initial?.hour == hour && initial?.minute == 0,
                      onSelected: _passed(hour)
                          ? null
                          : (_) => Navigator.pop(
                              context, TimeOfDay(hour: hour, minute: 0)),
                    ),
                ]),
              ],
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.schedule),
                label: const Text('其他时间'),
                onPressed: () async {
                  final TimeOfDay? picked = await showTimePicker(
                      context: context,
                      initialTime:
                          initial ?? const TimeOfDay(hour: 10, minute: 0));
                  if (picked != null && context.mounted) {
                    Navigator.pop(context, picked);
                  }
                },
              ),
            ],
          ),
        ),
      );
}

/// 需要填写原因的确认框。[notifyHint] 非空时额外要求勾选“已电话告知”。
/// 返回填写的内容；取消返回 null。
Future<String?> askReason(
  BuildContext context, {
  required String title,
  required String label,
  String message = '',
  String confirmText = '确定',
  String? notifyHint,
  String? phone,
  bool required = true,
  bool danger = false,
}) =>
    showDialog<String>(
      context: context,
      builder: (BuildContext dialog) => _ReasonDialog(
        title: title,
        label: label,
        message: message,
        confirmText: confirmText,
        notifyHint: notifyHint,
        phone: phone,
        required: required,
        danger: danger,
      ),
    );

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({
    required this.title,
    required this.label,
    required this.message,
    required this.confirmText,
    required this.notifyHint,
    required this.phone,
    required this.required,
    required this.danger,
  });
  final String title;
  final String label;
  final String message;
  final String confirmText;
  final String? notifyHint;
  final String? phone;
  final bool required;
  final bool danger;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final TextEditingController _text = TextEditingController();
  bool _notified = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _ready =>
      (!widget.required || _text.text.trim().isNotEmpty) &&
      (widget.notifyHint == null || _notified);

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (widget.message.isNotEmpty) ...<Widget>[
                Text(widget.message),
                const SizedBox(height: 12),
              ],
              if (widget.phone != null && widget.phone!.isNotEmpty) ...<Widget>[
                PhoneLine(label: '对方电话', phone: widget.phone!),
                const SizedBox(height: 8),
              ],
              TextField(
                controller: _text,
                maxLength: 500,
                maxLines: 3,
                // 系统键盘自带语音输入，可直接口述。
                decoration: InputDecoration(
                    labelText: widget.label,
                    helperText: widget.required ? null : '选填'),
              ),
              if (widget.notifyHint != null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _notified,
                  onChanged: (bool? value) =>
                      setState(() => _notified = value ?? false),
                  title: Text(widget.notifyHint!),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('返回')),
          FilledButton(
            style: widget.danger
                ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
                : null,
            onPressed:
                _ready ? () => Navigator.pop(context, _text.text.trim()) : null,
            child: Text(widget.confirmText),
          ),
        ],
      );
}

/// 一行电话：显示号码并支持复制。脱敏号码（含 *）不提供复制。
class PhoneLine extends StatelessWidget {
  const PhoneLine({required this.label, required this.phone, super.key});
  final String label;
  final String phone;

  @override
  Widget build(BuildContext context) {
    final bool masked = phone.contains('*');
    return Row(children: <Widget>[
      Text('$label：', style: const TextStyle(color: AppColors.textTertiary)),
      Expanded(child: SelectableText(phone.isEmpty ? '暂无' : phone)),
      if (phone.isNotEmpty && !masked)
        IconButton(
          tooltip: '复制号码',
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: phone));
            await PromptAction.showToast('号码已复制');
          },
        ),
    ]);
  }
}
