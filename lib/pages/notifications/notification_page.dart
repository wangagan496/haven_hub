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

Future<void> openRepairNotification(BuildContext context, String id) async {
  final session = tokenManager.sessionId;
  final note = await readNotificationApi(id);
  if (!context.mounted || session != tokenManager.sessionId) return;
  final repairId = note['repairId'] as String;
  if (note['role'] == 'worker') {
    await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => WorkerDetailPage(id: repairId)));
  } else if (note['role'] == 'resident') {
    await AppRoutes.toRepairDetail<void>(context, repairId: repairId);
  } else {
    await PromptAction.showWarning('请在物业工作台打开这条通知并处理工单');
  }
}

class NotificationPage extends StatefulWidget {
  const NotificationPage({this.notificationId, this.loader = notificationsApi,
    this.reader = readNotificationApi, this.retrier = retryNotificationApi, super.key});
  final String? notificationId;
  final Future<List<Map<String, dynamic>>> Function() loader;
  final Future<Map<String, dynamic>> Function(String) reader;
  final Future<void> Function(String) retrier;
  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> with WidgetsBindingObserver {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = false;
  bool _changing = false;
  String? _error;
  Timer? _timer;
  StreamSubscription<LogoutEvent>? _logout;
  StreamSubscription<LoginSuccessEvent>? _login;
  bool _opened = false;
  // 打开页面时的会话：notificationId 只属于这个账号，换号后不再用它请求。
  late final int _openSession;
  // 正在加载的会话；换号后旧请求不能挡住新账号的加载。
  int? _loadingSession;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _openSession = tokenManager.sessionId;
    WidgetsBinding.instance.addObserver(this);
    _logout = eventBus.on<LogoutEvent>().listen((_) {
      if (mounted) setState(() { _rows = []; _error = '请登录后查看当前账号的待办'; });
    });
    _login = eventBus.on<LoginSuccessEvent>().listen((_) {
      if (mounted) { setState(() => _rows = []); unawaited(_load()); }
    });
    unawaited(_load());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) unawaited(_load());
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
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }

  Future<void> _load() async {
    final session = tokenManager.sessionId;
    if (_loading && _loadingSession == session) return;
    final token = ++_loadToken;
    _loadingSession = session;
    setState(() { _loading = true; _error = null; });
    var loaded = false;
    try {
      final rows = await widget.loader();
      if (!mounted || token != _loadToken || session != tokenManager.sessionId) return;
      setState(() => _rows = rows);
      loaded = true;
    } on Object catch (error) {
      if (mounted && token == _loadToken && session == tokenManager.sessionId) {
        setState(() => _error = describeError(error, fallback: '待办加载失败'));
      }
    } finally {
      if (mounted && token == _loadToken) setState(() => _loading = false);
    }
    final id = widget.notificationId;
    if (loaded && !_opened && id != null && session == _openSession && mounted) {
      _opened = true;
      await _change(() => openRepairNotification(context, id));
    }
  }

  Future<void> _change(Future<void> Function() action) async {
    if (_changing) return;
    final session = tokenManager.sessionId;
    setState(() => _changing = true);
    try {
      await action();
      if (!mounted || session != tokenManager.sessionId) return;
      await _load();
    } on Object catch (error) {
      if (mounted && session == tokenManager.sessionId) await PromptAction.showError(describeError(error, fallback: '操作失败，请重试'));
    } finally { if (mounted) setState(() => _changing = false); }
  }

  String _delivery(Map<String, dynamic> row) {
    if (row['kind'] == 'info') return '告知消息，阅读不代表同意时间';
    final deliveries = row['deliveries'] as List? ?? [];
    if (deliveries.isEmpty) return '尚未登记接收设备；待办已保存';
    return deliveries.map((value) {
      final item = value as Map;
      return switch (item['status']) {
        'accepted' => '推送服务已接收，设备送达未确认',
        'queued' || 'sending' => '正在等待发送',
        'cancelled' => '事项已处理，停止提醒',
        'failed' when item['stopped'] == true => '已停止自动重试，请点“重试系统提醒”',
        'failed' => '${item['reason'] ?? '发送失败'}（第 ${item['attempts']} 次失败）',
        _ => item['reason']?.toString() ?? '尚未发送',
      };
    }).toSet().join('；');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('报修通知与待办'), actions: [
      IconButton(tooltip: '刷新待办', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
    ]),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('待办会一直保留到工单事项处理完成。划掉系统通知或阅读消息，不等于同意或完成。'),
      const SizedBox(height: 12),
      Text('待处理 ${_rows.where((row) => row['kind'] != 'info' && row['active'] == 1).length} 项'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(onPressed: _changing ? null : () => _change(() async {
          await pushSubscription.enable();
          if (!mounted) return;
          await PromptAction.showSuccess('设备已登记，实际送达请以系统通知为准');
        }), icon: const Icon(Icons.notifications_active_outlined), label: const Text('开启系统通知')),
        TextButton(onPressed: _changing ? null : () => _change(() async {
          await pushSubscription.disable();
          if (!mounted) return;
          await PromptAction.showSuccess('本机系统通知已停用，待办仍保留');
        }), child: const Text('停用本机推送')),
      ]),
      ValueListenableBuilder<String?>(
        valueListenable: pushSubscription.resumeProblem,
        builder: (context, problem, _) => problem == null ? const SizedBox.shrink()
            : Padding(padding: const EdgeInsets.only(top: 12), child: Text('系统通知未恢复：$problem')),
      ),
      if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(_error!)),
      if (_loading) const LinearProgressIndicator(),
      if (!_loading && _rows.isEmpty && _error == null) const Padding(padding: EdgeInsets.all(24), child: Text('暂无报修通知')),
      for (final row in _rows) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${row['kind'] == 'info' ? (row['readAt'] == null ? '未读' : '已读') : (row['active'] == 1 ? '待处理' : '已处理')} · ${row['title']}', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6), Text(row['body'].toString()),
        const SizedBox(height: 6), Text(_delivery(row), style: Theme.of(context).textTheme.bodySmall),
        Wrap(spacing: 12, children: [
          TextButton(onPressed: _changing ? null : () => _change(() => openRepairNotification(context, row['id'] as String)), child: const Text('打开工单')),
          if (row['kind'] == 'info' && row['readAt'] == null)
            TextButton(onPressed: _changing ? null : () => _change(() async { await widget.reader(row['id'] as String); }), child: const Text('标为已读')),
          if (row['kind'] != 'info' && row['active'] == 1) TextButton(onPressed: _changing ? null : () => _change(() => widget.retrier(row['id'] as String)), child: const Text('重试系统提醒')),
        ]),
      ]))),
    ]),
  );
}
