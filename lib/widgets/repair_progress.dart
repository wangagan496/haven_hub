import 'package:flutter/material.dart';
import '../models/repair.dart';
import '../theme/app_colors.dart';

/// 状态由服务端操作推进；记录只展示实际发生的时间。
class RepairProgress extends StatelessWidget {
  const RepairProgress({required this.record, super.key});
  final RepairRecord record;

  @override
  Widget build(BuildContext context) {
    final Color color = switch (record.status) {
      2 => const Color(0xFFB85C00),
      3 => const Color(0xFF2E7D32),
      _ => Theme.of(context).colorScheme.primary,
    };
    final IconData statusIcon = switch (record.status) {
      2 => Icons.schedule_rounded,
      3 => Icons.task_alt,
      1 || 5 => Icons.handyman_outlined,
      _ => Icons.info_outline,
    };
    final String description = switch (record.status) {
      1 => '报修已提交，等待物业安排维修人员',
      5 => '物业已派单，等待维修人员接单',
      2 => '维修人员已接单，正在处理本次报修',
      3 => '本次维修已完成，可查看处理结果',
      0 || 4 => '本次报修已取消',
      _ => '暂未获取到工单状态，请刷新后重试',
    };
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Card(
          color: AppColors.surface,
          elevation: 0,
          margin: const EdgeInsets.symmetric(vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(children: <Widget>[
                  Icon(statusIcon, color: color, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(record.statusText,
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              color: color)),
                      const SizedBox(height: 4),
                      Text(description,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                    ],
                  )),
                ]),
                if (record.workerName.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 20),
                  const Divider(height: 1, color: AppColors.placeholder),
                  const SizedBox(height: 16),
                  Wrap(spacing: 20, runSpacing: 6, children: <Widget>[
                    Text('维修人员：${record.workerName}'),
                    if (record.workerMobile.isNotEmpty)
                      SelectableText('联系电话：${record.workerMobile}'),
                  ]),
                ],
                if (record.completionNote.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 16),
                  Text('处理结果', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text(record.completionNote),
                ],
                if (record.timeline.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: const Text('处理记录', style: TextStyle(fontSize: 14)),
                    subtitle: Text('共${record.timeline.length}条记录',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                    children: <Widget>[
                      for (final event in record.timeline.reversed)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Padding(
                                  padding:
                                      const EdgeInsets.only(top: 5, right: 12),
                                  child: Icon(Icons.circle,
                                      size: 8, color: color)),
                              Expanded(
                                  child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(event.detail.isEmpty
                                      ? event.label
                                      : '${event.label} · ${event.detail}'),
                                  const SizedBox(height: 4),
                                  Text(_time(event.at),
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: AppColors.textSecondary)),
                                ],
                              )),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _time(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return value;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }
}
