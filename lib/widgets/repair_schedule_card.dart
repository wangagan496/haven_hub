import 'package:flutter/material.dart';
import '../models/repair.dart';
import '../utils/date_utils.dart';

class RepairScheduleCard extends StatelessWidget {
  const RepairScheduleCard({required this.record, required this.isResident, this.onAccept, this.onDecline, this.onInconvenient, super.key});
  final RepairRecord record;
  final bool isResident;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;
  final VoidCallback? onInconvenient;
  @override
  Widget build(BuildContext context) {
    final RepairPending? pending = record.firstSchedule;
    final String title = pending != null ? '首次提议待确认'
        : record.autoAccepted ? '超时已生效'
        : record.propertyFirstScheduled ? '物业已安排上门时间'
        : record.propertyAdjusted ? '物业已调整时间'
        : record.agreedTime.isNotEmpty ? '已约定' : '等待安排上门时间';
    final RepairSlotWindow? window = record.slotWindow;
    final String slot = pending?.proposedSlot ?? record.slot;
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        if (pending != null) ...<Widget>[
          Text(formatSlotWindow(slot: pending.proposedSlot, start: pending.proposedTime)),
          Text('确认期限：${formatVisitTime(pending.deadline)}'),
          if (pending.reason.trim().isNotEmpty) Text('原因：${pending.reason}'),
          if (onAccept != null || onDecline != null) Wrap(spacing: 12, children: <Widget>[
            TextButton(onPressed: onDecline, child: const Text('拒绝')),
            FilledButton(onPressed: onAccept, child: const Text('同意')),
          ]) else const Text('等待住户回应，接单不会代住户确认'),
        ] else ...<Widget>[
          if (record.agreedTime.isNotEmpty) Text('约定时间：${formatVisitTime(record.agreedTime)}'),
          if (slot.isNotEmpty || window != null) Text(formatSlotWindow(slot: slot, start: window?.start ?? '', end: window?.end ?? '')),
          if (record.autoAccepted) ...<Widget>[
            Text(isResident ? '确认期限已过，该时段已自动生效；如不方便可点下方按钮反馈'
                : '确认期限已过，当前时段已生效。住户未主动确认，请先电话确认。'),
            if (onInconvenient != null) TextButton(onPressed: onInconvenient, child: const Text('这个时间不方便')),
          ],
          if (record.propertyAdjusted) Text(record.propertyFirstScheduled
              ? '物业安排已生效，请按当前时段安排上门。' : '物业调整已生效，请按当前时段安排上门。'),
        ],
      ])));
  }
}

class RepairScheduleBadges extends StatelessWidget {
  const RepairScheduleBadges({required this.record, super.key});
  final RepairRecord record;
  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, children: <Widget>[
    if (record.priority == 'urgent') const Chip(label: Text('急')),
    if (record.autoAccepted) const Chip(label: Text('超时生效')),
  ]);
}
