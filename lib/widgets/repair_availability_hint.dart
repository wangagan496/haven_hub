import 'dart:async';
import 'package:flutter/material.dart';
import '../api/repair.dart';
import '../utils/emitter.dart';
import '../utils/token_manager.dart';

/// 首页只展示服务端判定的今天可约状态，不展示容量。
class RepairAvailabilityHint extends StatefulWidget {
  const RepairAvailabilityHint({this.loader = getRepairSlotsApi, super.key});
  final RepairSlotsLoader loader;
  @override
  State<RepairAvailabilityHint> createState() => _RepairAvailabilityHintState();
}

class _RepairAvailabilityHintState extends State<RepairAvailabilityHint> with WidgetsBindingObserver {
  String _message = '正在查询上门时段…';
  int _request = 0;
  bool _loading = false;
  late final StreamSubscription<LoginSuccessEvent> _loginSubscription;
  late final StreamSubscription<LogoutEvent> _logoutSubscription;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loginSubscription = eventBus.on<LoginSuccessEvent>().listen((_) => unawaited(_load()));
    _logoutSubscription = eventBus.on<LogoutEvent>().listen((_) {
      if (!mounted) return;
      ++_request;
      setState(() { _loading = false; _message = '暂时无法获取'; });
    });
    unawaited(_load());
  }
  @override
  void dispose() {
    _loginSubscription.cancel();
    _logoutSubscription.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }
  Future<void> _load() async {
    final request = ++_request;
    final session = tokenManager.sessionId;
    setState(() => _loading = true);
    try {
      final data = await widget.loader();
      if (!mounted || request != _request || session != tokenManager.sessionId) return;
      setState(() => _message = data.slots.any((slot) => slot.selectable && slot.slot.startsWith('${data.today}#'))
          ? '今天可预约' : '今天已约满，可选后续日期或提交待安排');
    } on Object {
      if (mounted && request == _request && session == tokenManager.sessionId) setState(() => _message = '暂时无法获取');
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }
  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.schedule), title: const Text('上门服务'),
    subtitle: Text(_message), trailing: IconButton(tooltip: '刷新上门时段',
      onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)));
}
