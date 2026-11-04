import 'dart:async';
import 'package:flutter/material.dart';
import '../../api/notifications.dart';
import '../../router/app_routes.dart';
import '../../utils/app_exception.dart';
import '../../utils/emitter.dart';
import '../../utils/push_subscription.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';
import '../worker/worker_pages.dart';

Future<void> openRepairNotification(
    BuildContext context, String notificationId) async {
  final sessionAtOpen = tokenManager.sessionId;
  final notification = await readNotificationApi(notificationId);
  if (!context.mounted || sessionAtOpen != tokenManager.sessionId) return;
  final repairId = notification['repairId'] as String;
  if (notification['role'] == 'worker') {
    await Navigator.push<void>(context,
        MaterialPageRoute(builder: (_) => WorkerDetailPage(id: repairId)));
  } else if (notification['role'] == 'resident') {
    await AppRoutes.toRepairDetail<void>(context, repairId: repairId);
  } else {
    await AppPrompt.showWarning('请在物业工作台打开这条通知并处理工单');
  }
}

class NotificationPage extends StatefulWidget {
  const NotificationPage(
      {this.notificationId,
      this.loader = notificationsApi,
      this.reader = readNotificationApi,
      this.retrier = retryNotificationApi,
      super.key});
  final String? notificationId;
  final Future<List<Map<String, dynamic>>> Function() loader;
  final Future<Map<String, dynamic>> Function(String) reader;
  final Future<void> Function(String) retrier;
  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> _notifications = [];
  bool _isLoading = false;
  bool _isSubmitting = false;
  String? _loadErrorMessage;
  Timer? _timer;
  StreamSubscription<LogoutEvent>? _logout;
  StreamSubscription<LoginSuccessEvent>? _login;
  bool _initialNotificationOpened = false;
  // 打开页面时的会话：notificationId 只属于这个账号，换号后不再用它请求。
  late final int _openSession;
  // 正在加载的会话；换号后旧请求不能挡住新账号的加载。
  int? _loadingSession;
  int _latestLoadNumber = 0;

  @override
  void initState() {
    super.initState();
    _openSession = tokenManager.sessionId;
    WidgetsBinding.instance.addObserver(this);
    _logout = eventBus.on<LogoutEvent>().listen((_) {
      if (mounted) {
        setState(() {
          _notifications = [];
          _loadErrorMessage = '请登录后查看当前账号的待办';
        });
      }
    });
    _login = eventBus.on<LoginSuccessEvent>().listen((_) {
      if (mounted) {
        setState(() => _notifications = []);
        unawaited(_loadNotifications());
      }
    });
    unawaited(_loadNotifications());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(_loadNotifications());
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _logout?.cancel();
    _login?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_loadNotifications());
  }

  Future<void> _loadNotifications() async {
    final sessionAtLoad = tokenManager.sessionId;
    if (_isLoading && _loadingSession == sessionAtLoad) return;
    final loadNumber = ++_latestLoadNumber;
    _loadingSession = sessionAtLoad;
    setState(() {
      _isLoading = true;
      _loadErrorMessage = null;
    });
    var loadSucceeded = false;
    try {
      final loadedNotifications = await widget.loader();
      if (!mounted ||
          loadNumber != _latestLoadNumber ||
          sessionAtLoad != tokenManager.sessionId) {
        return;
      }
      setState(() => _notifications = loadedNotifications);
      loadSucceeded = true;
    } on Object catch (error) {
      if (mounted &&
          loadNumber == _latestLoadNumber &&
          sessionAtLoad == tokenManager.sessionId) {
        setState(
            () => _loadErrorMessage = describeError(error, fallback: '待办加载失败'));
      }
    } finally {
      if (mounted && loadNumber == _latestLoadNumber) {
        setState(() => _isLoading = false);
      }
    }
    final notificationId = widget.notificationId;
    if (loadSucceeded &&
        !_initialNotificationOpened &&
        notificationId != null &&
        sessionAtLoad == _openSession &&
        mounted) {
      _initialNotificationOpened = true;
      await _runNotificationAction(
        () => openRepairNotification(context, notificationId),
      );
    }
  }

  Future<void> _runNotificationAction(Future<void> Function() action) async {
    if (_isSubmitting) return;
    final session = tokenManager.sessionId;
    setState(() => _isSubmitting = true);
    try {
      await action();
      if (!mounted || session != tokenManager.sessionId) return;
      await _loadNotifications();
    } on Object catch (error) {
      if (mounted && session == tokenManager.sessionId) {
        await AppPrompt.showError(describeError(error, fallback: '操作失败，请重试'));
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  String _pushStatusText(Map<String, dynamic> notification) {
    if (notification['kind'] == 'info') return '告知消息，阅读不代表同意时间';
    final deliveries = notification['deliveries'] as List? ?? [];
    if (deliveries.isEmpty) return '尚未登记接收设备；待办已保存';
    return deliveries
        .map((value) {
          final deviceDelivery = value as Map;
          return switch (deviceDelivery['status']) {
            'accepted' => '推送服务已接收，设备送达未确认',
            'queued' || 'sending' => '正在等待发送',
            'cancelled' => '事项已处理，停止提醒',
            'failed' when deviceDelivery['stopped'] == true =>
              '已停止自动重试，请点“重试系统提醒”',
            'failed' =>
              '${deviceDelivery['reason'] ?? '发送失败'}（第 ${deviceDelivery['attempts']} 次失败）',
            _ => deviceDelivery['reason']?.toString() ?? '尚未发送',
          };
        })
        .toSet()
        .join('；');
  }

  Widget _notificationCard(Map<String, dynamic> notification) {
    final bool isInfoMessage = notification['kind'] == 'info';
    final bool isUnread = notification['readAt'] == null;
    final bool needsAction = notification['active'] == 1;
    String statusText;
    if (isInfoMessage) {
      statusText = isUnread ? '未读' : '已读';
    } else {
      statusText = needsAction ? '待处理' : '已处理';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$statusText · ${notification['title']}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(notification['body'].toString()),
            const SizedBox(height: 6),
            Text(
              _pushStatusText(notification),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Wrap(spacing: 12, children: [
              TextButton(
                onPressed: _isSubmitting
                    ? null
                    : () => _runNotificationAction(
                          () => openRepairNotification(
                              context, notification['id'] as String),
                        ),
                child: const Text('打开工单'),
              ),
              if (isInfoMessage && isUnread)
                TextButton(
                  onPressed: _isSubmitting
                      ? null
                      : () => _runNotificationAction(() async {
                            await widget.reader(notification['id'] as String);
                          }),
                  child: const Text('标为已读'),
                ),
              if (!isInfoMessage && needsAction)
                TextButton(
                  onPressed: _isSubmitting
                      ? null
                      : () => _runNotificationAction(
                            () => widget.retrier(notification['id'] as String),
                          ),
                  child: const Text('重试系统提醒'),
                ),
            ]),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('报修通知与待办'), actions: [
          IconButton(
              tooltip: '刷新待办',
              onPressed: _isLoading ? null : _loadNotifications,
              icon: const Icon(Icons.refresh)),
        ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('待办会一直保留到工单事项处理完成。划掉系统通知或阅读消息，不等于同意或完成。'),
          const SizedBox(height: 12),
          Text(
              '待处理 ${_notifications.where((row) => row['kind'] != 'info' && row['active'] == 1).length} 项'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
                onPressed: _isSubmitting
                    ? null
                    : () => _runNotificationAction(() async {
                          await pushSubscription.enable();
                          if (!mounted) return;
                          await AppPrompt.showSuccess('设备已登记，实际送达请以系统通知为准');
                        }),
                icon: const Icon(Icons.notifications_active_outlined),
                label: const Text('开启系统通知')),
            TextButton(
                onPressed: _isSubmitting
                    ? null
                    : () => _runNotificationAction(() async {
                          await pushSubscription.disable();
                          if (!mounted) return;
                          await AppPrompt.showSuccess('本机系统通知已停用，待办仍保留');
                        }),
                child: const Text('停用本机推送')),
          ]),
          ValueListenableBuilder<String?>(
            valueListenable: pushSubscription.resumeProblem,
            builder: (context, problem, _) => problem == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('系统通知未恢复：$problem')),
          ),
          if (_loadErrorMessage != null)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_loadErrorMessage!)),
          if (_isLoading) const LinearProgressIndicator(),
          if (!_isLoading &&
              _notifications.isEmpty &&
              _loadErrorMessage == null)
            const Padding(padding: EdgeInsets.all(24), child: Text('暂无报修通知')),
          for (final notification in _notifications)
            _notificationCard(notification),
        ]),
      );
}
