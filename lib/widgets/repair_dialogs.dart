import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api/repair.dart';
import '../models/repair.dart';
import '../theme/app_colors.dart';
import '../utils/toast.dart';
import 'repair_slot_picker.dart';

Future<RepairSlot?> pickVisitTime(BuildContext context, {String? initialSlot, String? excludeId, String? repairItemId,
  String title = '选择上门时段', RepairSlotsLoader loader = getRepairSlotsApi}) =>
    pickRepairSlot(context, initialSlot: initialSlot, excludeId: excludeId, repairItemId: repairItemId, title: title, loader: loader);

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
  String initialText = '',
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
        initialText: initialText,
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
    required this.initialText,
  });
  final String title;
  final String label;
  final String message;
  final String confirmText;
  final String? notifyHint;
  final String? phone;
  final bool required;
  final bool danger;
  final String initialText;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final TextEditingController _text = TextEditingController();
  bool _notified = false;

  @override
  void initState() {
    super.initState();
    _text.text = widget.initialText;
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
