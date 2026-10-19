import 'package:flutter/material.dart';
import '../api/notifications.dart';
import '../router/app_routes.dart';
import '../utils/app_exception.dart';
import '../utils/toast.dart';

class NotificationInboxButton extends StatelessWidget {
  const NotificationInboxButton({super.key});
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '报修通知与待办', icon: const Icon(Icons.notifications_outlined),
    onPressed: () => Navigator.pushNamed<void>(context, AppRoutes.notifications),
  );
}

class RepairReminderButton extends StatefulWidget {
  const RepairReminderButton({required this.repairId, super.key});
  final String repairId;
  @override
  State<RepairReminderButton> createState() => _RepairReminderButtonState();
}
class _RepairReminderButtonState extends State<RepairReminderButton> {
  bool _sending = false;
  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await remindRepairApi(widget.repairId);
      if (!mounted) return;
      await PromptAction.showSuccess('已加入提醒队列，实际送达以系统通知为准');
    } on Object catch (error) {
      if (mounted) await PromptAction.showError(describeError(error, fallback: '提醒失败，请重试'));
    } finally { if (mounted) setState(() => _sending = false); }
  }
  @override
  Widget build(BuildContext context) => IconButton(tooltip: '提醒对方处理待办',
    onPressed: _sending ? null : _send, icon: const Icon(Icons.notification_add_outlined));
}
