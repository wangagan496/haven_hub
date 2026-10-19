import 'dart:async';
import 'package:flutter/material.dart';
import '../../api/worker.dart';
import '../../models/repair.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/date_utils.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';
import '../../utils/worker_repair_read_store.dart';
import '../../widgets/notification_actions.dart';
import '../../widgets/repair_dialogs.dart';
import '../../widgets/repair_photos.dart';
import '../../widgets/repair_progress.dart';

class WorkerPage extends StatefulWidget {
  const WorkerPage({
    this.recordsLoader = getWorkerRepairsApi,
    this.recordLoader = getWorkerRepairApi,
    this.readStore,
    this.tokens,
    super.key,
  });
  final Future<List<RepairRecord>> Function() recordsLoader;
  final Future<RepairRecord> Function(String id) recordLoader;
  final WorkerRepairReadStore? readStore;
  final TokenManager? tokens;
  @override
  State<WorkerPage> createState() => _WorkerPageState();
}

class _WorkerPageState extends State<WorkerPage> {
  List<RepairRecord> _records = <RepairRecord>[];
  Set<String> _unreadIds = <String>{};
  WorkerRepairReadStore get _readStore =>
      widget.readStore ?? workerRepairReadStore;
  TokenManager get _tokens => widget.tokens ?? tokenManager;
  int _status = 5;
  bool _loading = false;
  bool _loggingOut = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading) return;
    final session = _tokens.sessionId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final records = await widget.recordsLoader();
      if (!mounted || session != _tokens.sessionId) return;
      final unreadIds = await _readStore.unreadIds(records);
      if (!mounted || session != _tokens.sessionId) return;
      setState(() {
        _records = records;
        _unreadIds = unreadIds;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _records = <RepairRecord>[];
          _error = describeError(error, fallback: '工单加载失败，请重试');
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _logout() async {
    if (_loggingOut) return;
    setState(() => _loggingOut = true);
    try {
      final removed = await _tokens.deleteToken();
      if (!removed) {
        // 与 TabsPage 一致：磁盘清理失败也要立即作废内存会话，避免继续带旧凭证请求。
        _tokens.invalidateLocalSession();
        if (mounted) await PromptAction.showError('本地登录信息清除失败，请重试');
        return;
      }
      if (!mounted) return;
      await Navigator.pushNamedAndRemoveUntil<void>(
          context, AppRoutes.login, (_) => false);
    } on Object catch (error) {
      if (mounted) {
        await PromptAction.showError(
            describeError(error, fallback: '退出登录失败，请重试'));
      }
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // “已完成”标签同时包含待住户确认，确认后才算彻底完成。
    final records = _records
        .where((r) =>
            r.status == _status ||
            (_status == RepairStatus.completed &&
                r.status == RepairStatus.confirming))
        .toList();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
          title: const Text('维修工作台'),
          automaticallyImplyLeading: false,
          actions: <Widget>[
            const NotificationInboxButton(),
            IconButton(
                tooltip: '刷新工单',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh)),
            TextButton(
                onPressed: _loggingOut ? null : _logout,
                child: const Text('退出登录')),
          ]),
      body: Column(children: <Widget>[
        Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(spacing: 12, children: <Widget>[
              for (final entry
                  in const <int, String>{5: '待接单', 2: '处理中', 3: '已完成'}.entries)
                Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    ChoiceChip(
                        showCheckmark: false,
                        label: Text(entry.value),
                        selected: _status == entry.key,
                        onSelected: (_) => setState(() => _status = entry.key)),
                    if (entry.key != 3 &&
                        _records.any((r) =>
                            r.status == entry.key && _unreadIds.contains(r.id)))
                      Positioned(
                        top: 2,
                        right: -4,
                        child: _UnreadDot(
                          key: ValueKey('worker-status-dot-${entry.key}'),
                          label: '${entry.value}有未查看工单',
                        ),
                      ),
                  ],
                ),
            ])),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: <Widget>[
                Text(_error!),
                TextButton(onPressed: _load, child: const Text('重试'))
              ])),
        Expanded(
            child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: <Widget>[
                      if (!_loading && _error == null && records.isEmpty)
                        const Padding(
                            padding: EdgeInsets.all(48),
                            child: Center(child: Text('当前没有此状态的工单'))),
                      for (final record in records)
                        ListTile(
                          key: ValueKey(record.id),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                          title: Text(
                            record.description.isEmpty
                                ? record.repairItemName
                                : record.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                                '${record.repairItemName} · ${record.statusText}'
                                '${record.reschedule != null || record.revokeRequest != null ? ' · 待你回应' : ''}'
                                '\n${record.houseInfo}\n'
                                '${record.agreedTime.isNotEmpty ? '约定' : '期望'}：'
                                '${record.visitTime.isNotEmpty ? formatVisitTime(record.visitTime) : record.appointment}'),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              if (_unreadIds.contains(record.id)) ...[
                                _UnreadDot(
                                  key: ValueKey(
                                      'worker-record-dot-${record.id}'),
                                  label: '未查看工单',
                                ),
                                const SizedBox(width: 8),
                              ],
                              const Icon(Icons.chevron_right),
                            ],
                          ),
                          onTap: () async {
                            final session = _tokens.sessionId;
                            await Navigator.push<void>(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => WorkerDetailPage(
                                          id: record.id,
                                          recordLoader: widget.recordLoader,
                                          readStore: _readStore,
                                        )));
                            if (mounted && session == _tokens.sessionId) {
                              await _load();
                            }
                          },
                        ),
                    ]))),
      ]),
    );
  }
}

class _UnreadDot extends StatelessWidget {
  const _UnreadDot({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Semantics(
          label: label,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: const Color(0xFFFF3B30),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.surface, width: 2),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x33FF3B30),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      );
}

/// 师傅在详情页的其他操作：改约、回应改约、进展、退出、确认撤销。返回最新工单；退出返回 null。
typedef WorkerActionLoader = Future<RepairRecord?> Function(
    RepairRecord record, WorkerAction action);

sealed class WorkerAction {
  const WorkerAction();
}

final class WorkerProposeAction extends WorkerAction {
  const WorkerProposeAction(this.time, this.reason);
  final DateTime time;
  final String reason;
}

final class WorkerRespondAction extends WorkerAction {
  const WorkerRespondAction({required this.accept, this.reason = ''});
  final bool accept;
  final String reason;
}

final class WorkerProgressAction extends WorkerAction {
  const WorkerProgressAction(this.content);
  final String content;
}

final class WorkerReleaseAction extends WorkerAction {
  const WorkerReleaseAction(this.reason);
  final String reason;
}

final class WorkerAcknowledgeRevokeAction extends WorkerAction {
  const WorkerAcknowledgeRevokeAction();
}

Future<RepairRecord?> runWorkerAction(
    RepairRecord record, WorkerAction action) async {
  switch (action) {
    case WorkerProposeAction(:final DateTime time, :final String reason):
      return proposeWorkerRescheduleApi(record, time, reason);
    case WorkerRespondAction(:final bool accept, :final String reason):
      return respondWorkerRescheduleApi(record, accept: accept, reason: reason);
    case WorkerProgressAction(:final String content):
      return workerProgressApi(record, content);
    case WorkerReleaseAction(:final String reason):
      await releaseWorkerRepairApi(record, reason);
      return null;
    case WorkerAcknowledgeRevokeAction():
      return acknowledgeRevokeApi(record);
  }
}

class WorkerDetailPage extends StatefulWidget {
  const WorkerDetailPage({
    required this.id,
    this.recordLoader = getWorkerRepairApi,
    this.processor = _defaultProcessor,
    this.actionLoader = runWorkerAction,
    this.readStore,
    super.key,
  });
  final String id;
  final WorkerRepairReadStore? readStore;
  final Future<RepairRecord> Function(String id) recordLoader;
  final Future<RepairRecord> Function(RepairRecord record,
      {required bool complete, String result}) processor;
  final WorkerActionLoader actionLoader;
  @override
  State<WorkerDetailPage> createState() => _WorkerDetailPageState();
}

Future<RepairRecord> _defaultProcessor(RepairRecord record,
        {required bool complete, String result = ''}) =>
    processWorkerRepairApi(record, complete: complete, result: result);

class _WorkerDetailPageState extends State<WorkerDetailPage> {
  RepairRecord? _record;
  final _result = TextEditingController();
  final _resultFocus = FocusNode();
  final _cost = TextEditingController(text: '0');
  String? _resultError;
  String? _costError;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  bool get _usingDefaultProcessor =>
      identical(widget.processor, _defaultProcessor);

  /// 通用操作：防重复；异步后检查 mounted 与会话；409 刷新权威数据，不重放旧操作。
  Future<void> _act(WorkerAction action, String success,
      {bool leaveOnSuccess = false}) async {
    final RepairRecord? record = _record;
    if (_saving || _loading || record == null) return;
    final int session = tokenManager.sessionId;
    setState(() => _saving = true);
    try {
      final RepairRecord? updated = await widget.actionLoader(record, action);
      if (!mounted || session != tokenManager.sessionId) return;
      await PromptAction.showSuccess(success);
      if (!mounted || session != tokenManager.sessionId) return;
      if (leaveOnSuccess || updated == null) {
        // 退出后已无权查看此工单，返回工作台并刷新列表。
        Navigator.pop(context);
        return;
      }
      setState(() => _record = updated);
    } on Object catch (error) {
      if (!mounted || session != tokenManager.sessionId) return;
      if (error is NetworkException && error.statusCode == 409) {
        await PromptAction.showWarning('工单已被更新，已为你刷新，请确认后再操作');
        if (mounted) setState(() => _saving = false);
        await _load();
        return;
      }
      await PromptAction.showError(
          describeError(error, fallback: '操作失败，请刷新后重试'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _propose() async {
    final RepairRecord? record = _record;
    if (record == null) return;
    final DateTime? time = await pickVisitTime(context,
        initial: DateTime.tryParse(record.visitTime)?.toLocal(),
        title: '选择新的上门时间');
    if (time == null || !mounted) return;
    final String? reason = await askReason(context,
        title: '修改预约',
        label: '改约原因',
        message: '新时间：${formatVisitTime(time.toIso8601String())}\n'
            '请先电话告知住户。住户同意后新时间才生效，之前按原约定。',
        phone: record.mobile,
        notifyHint: '我已电话告知住户',
        confirmText: '发起改约');
    if (reason != null && mounted) {
      await _act(WorkerProposeAction(time, reason), '改约已发起，等待住户同意');
    }
  }

  Future<void> _respond(bool accept) async {
    String reason = '';
    if (!accept) {
      final String? value = await askReason(context,
          title: '不同意改约',
          label: '原因',
          message: '将保持原约定时间，建议电话与住户再沟通。',
          confirmText: '保持原约定');
      if (value == null || !mounted) return;
      reason = value;
    }
    await _act(WorkerRespondAction(accept: accept, reason: reason),
        accept ? '已同意新时间' : '已保持原约定');
  }

  Future<void> _progress() async {
    final String? content = await askReason(context,
        title: '补充进展',
        label: '进展说明',
        message: '例如：已电话联系住户、等待材料到货。不会改变工单状态。',
        confirmText: '提交');
    if (content != null && mounted) {
      await _act(WorkerProgressAction(content), '进展已记录');
    }
  }

  Future<void> _release() async {
    final String? reason = await askReason(context,
        title: '无法继续接单',
        label: '退出原因',
        message: '退出后工单交回物业重新派单，你将无法再查看这张工单。如只是时间冲突，请改用“修改预约”。',
        confirmText: '确认退出',
        danger: true);
    if (reason != null && mounted) {
      await _act(WorkerReleaseAction(reason), '已退出，物业会重新安排',
          leaveOnSuccess: true);
    }
  }

  Future<void> _acknowledgeRevoke() async {
    await _act(const WorkerAcknowledgeRevokeAction(), '已确认，报修已撤销');
  }

  void _rememberDisplayed(RepairRecord record, int session) {
    if (!WorkerRepairReadStore.needsAttention(record) ||
        record.workerId.isEmpty) {
      return;
    }
    // Opening a route is not enough: only mark a successfully rendered detail.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          session != tokenManager.sessionId ||
          !identical(_record, record) ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      unawaited(_saveViewed(record, session));
    });
  }

  Future<void> _saveViewed(RepairRecord record, int session) async {
    bool saved;
    try {
      saved =
          await (widget.readStore ?? workerRepairReadStore).markViewed(record);
    } on Object {
      saved = false;
    }
    if (!saved && mounted && session == tokenManager.sessionId) {
      await PromptAction.showWarning('查看记录保存失败，下次可能再次提醒');
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _result.dispose();
    _resultFocus.dispose();
    _cost.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || _saving) return;
    final session = tokenManager.sessionId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final record = await widget.recordLoader(widget.id);
      if (mounted && session == tokenManager.sessionId) {
        setState(() => _record = record);
        _rememberDisplayed(record, session);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _record = null;
          _error = describeError(error, fallback: '工单加载失败');
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 接单时确认上门时间：沿用住户期望时间，或选择其他时间（需住户同意）。
  /// 返回 null 表示取消；返回空记录表示按期望时间。
  Future<({DateTime? time, String reason})?> _confirmVisitTime(
      RepairRecord record) async {
    final DateTime? expected = DateTime.tryParse(record.expectedTime)?.toLocal();
    final bool expectedValid = expected != null && expected.isAfter(DateTime.now());
    final String? choice = await showDialog<String>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: const Text('确认上门时间'),
        content: Text(expectedValid
            ? '住户期望：${formatVisitTime(record.expectedTime)}'
            : record.expectedTime.isEmpty
                ? '住户未选择具体时间，请选择上门时间'
                : '住户期望时间（${formatVisitTime(record.expectedTime)}）已过，请选择新的上门时间'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('返回')),
          OutlinedButton(
              onPressed: () => Navigator.pop(dialog, 'other'),
              child: const Text('选择其他时间')),
          if (expectedValid)
            FilledButton(
                onPressed: () => Navigator.pop(dialog, 'expected'),
                child: const Text('按期望时间')),
        ],
      ),
    );
    if (choice == null || !mounted) return null;
    if (choice == 'expected') return (time: null, reason: '');
    final DateTime? time = await pickVisitTime(context, initial: expected);
    if (time == null || !mounted) return null;
    final String? reason = await askReason(context,
        title: '说明原因',
        label: '为什么选择这个时间',
        message: '新时间：${formatVisitTime(time.toIso8601String())}\n'
            '建议先电话与住户沟通。住户同意后生效。',
        phone: record.mobile,
        confirmText: '接单');
    if (reason == null) return null;
    return (time: time, reason: reason);
  }

  Future<void> _process() async {
    final record = _record;
    if (_saving || _loading || record == null) return;
    final bool complete = record.status == RepairStatus.processing;
    num cost = 0;
    ({DateTime? time, String reason})? visit;
    if (complete) {
      if (_result.text.trim().isEmpty) {
        setState(() => _resultError = '请填写处理结果后再完成维修');
        _resultFocus.requestFocus();
        await PromptAction.showWarning('请填写处理结果后再完成维修');
        return;
      }
      final num? parsed = num.tryParse(_cost.text.trim().isEmpty ? '0' : _cost.text.trim());
      if (parsed == null || parsed < 0) {
        setState(() => _costError = '请填写有效金额，无费用填 0');
        await PromptAction.showWarning('请填写有效金额，无费用填 0');
        return;
      }
      cost = parsed;
    } else if (_usingDefaultProcessor) {
      visit = await _confirmVisitTime(record);
      if (visit == null || !mounted) return;
    }
    final session = tokenManager.sessionId;
    setState(() => _saving = true);
    try {
      final RepairRecord updated = _usingDefaultProcessor
          ? await processWorkerRepairApi(record,
              complete: complete,
              result: _result.text.trim(),
              cost: cost,
              time: visit?.time,
              reason: visit?.reason ?? '')
          : await widget.processor(record,
              complete: complete, result: _result.text.trim());
      if (!mounted || session != tokenManager.sessionId) return;
      setState(() => _record = updated);
      _rememberDisplayed(updated, session);
      await PromptAction.showSuccess(updated.status == RepairStatus.processing
          ? '接单成功'
          : updated.status == RepairStatus.completed
              ? '维修已完成'
              : '已提交完工，等待住户确认');
      if (!mounted || session != tokenManager.sessionId) return;
      // 提交完工后返回工作台，列表按新状态刷新；接单后留在详情，便于约时间。
      if (complete) Navigator.pop(context);
    } on Object catch (error) {
      if (!mounted || session != tokenManager.sessionId) return;
      if (error is NetworkException && error.statusCode == 409) {
        await PromptAction.showWarning('工单已被更新，已为你刷新，请确认后再操作');
        if (mounted) setState(() => _saving = false);
        await _load();
        return;
      }
      await PromptAction.showError(
          describeError(error, fallback: '操作失败，请刷新后重试'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = _record;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('维修工单'), actions: <Widget>[
        if (record != null) RepairReminderButton(repairId: record.id),
        const NotificationInboxButton(),
        IconButton(
            tooltip: '刷新工单',
            onPressed: _loading || _saving ? null : _load,
            icon: const Icon(Icons.refresh))
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : record == null
              ? Center(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                      Text(_error ?? '工单不存在'),
                      TextButton(onPressed: _load, child: const Text('重试'))
                    ]))
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 792),
                      child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: <Widget>[
                            RepairProgress(record: record),
                            const SizedBox(height: 12),
                            Text(record.repairItemName,
                                style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 16),
                            ..._workerNotices(record),
                            SelectableText(
                                '房屋：${record.houseInfo}\n'
                                '${record.agreedTime.isNotEmpty ? '约定上门' : '住户期望'}：'
                                '${record.visitTime.isNotEmpty ? formatVisitTime(record.visitTime) : record.appointment}'),
                            const SizedBox(height: 8),
                            PhoneLine(label: '住户电话', phone: record.mobile),
                            PhoneLine(label: '物业电话', phone: record.propertyPhone),
                            if (record.round > 1)
                              Text('第 ${record.round} 轮维修（返修）',
                                  style: const TextStyle(color: AppColors.danger)),
                            const SizedBox(height: 16),
                            Text(record.description.isEmpty
                                ? '住户未填写补充描述'
                                : record.description),
                            const SizedBox(height: 20),
                            if (record.attachment.isNotEmpty)
                              RepairPhotos(urls: record.attachment),
                            if (record.status == RepairStatus.processing &&
                                record.revokeRequest == null) ...<Widget>[
                              Padding(
                                  padding: const EdgeInsets.only(top: 24),
                                  child: TextField(
                                      controller: _result,
                                      focusNode: _resultFocus,
                                      enabled: !_saving,
                                      onChanged: (_) {
                                        if (_resultError != null) {
                                          setState(() => _resultError = null);
                                        }
                                      },
                                      maxLength: 1000,
                                      maxLines: 3,
                                      decoration: InputDecoration(
                                          labelText: '修了什么（必填）',
                                          hintText: '简单说明即可，可用键盘语音输入',
                                          alignLabelWithHint: true,
                                          border: const OutlineInputBorder(),
                                          errorText: _resultError))),
                              TextField(
                                  controller: _cost,
                                  enabled: !_saving,
                                  keyboardType: const TextInputType.numberWithOptions(
                                      decimal: true),
                                  onChanged: (_) {
                                    if (_costError != null) {
                                      setState(() => _costError = null);
                                    }
                                  },
                                  decoration: InputDecoration(
                                      labelText: '费用（元）',
                                      helperText: '无费用填 0；物业会与住户核实',
                                      border: const OutlineInputBorder(),
                                      errorText: _costError)),
                            ],
                            if (record.status == RepairStatus.assigned ||
                                record.status == RepairStatus.processing)
                              Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
                                  if (record.canReschedule)
                                    OutlinedButton(
                                        onPressed: _saving ? null : _propose,
                                        child: const Text('修改预约')),
                                  OutlinedButton(
                                      onPressed: _saving ? null : _progress,
                                      child: const Text('补充进展')),
                                  TextButton(
                                      onPressed: _saving ? null : _release,
                                      style: TextButton.styleFrom(
                                          foregroundColor: AppColors.danger),
                                      child: const Text('无法继续接单')),
                                ]),
                              ),
                          ]))),
      bottomNavigationBar: record != null &&
              (record.status == RepairStatus.assigned ||
                  (record.status == RepairStatus.processing &&
                      record.revokeRequest == null))
          ? SafeArea(
                  child: Align(
                      heightFactor: 1,
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 792),
                          child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                      onPressed:
                                          _saving || _loading ? null : _process,
                                      child: Text(_saving
                                          ? '正在提交…'
                                          : record.status == RepairStatus.assigned
                                              ? '接单'
                                              : '提交完工')))))))
          : null,
    );
  }

  /// 顶部提示卡：待你回应的事项，不依赖推送。
  List<Widget> _workerNotices(RepairRecord record) {
    final List<Widget> cards = <Widget>[];
    final RepairPending? reschedule = record.reschedule;
    final RepairPending? revoke = record.revokeRequest;
    if (revoke != null) {
      cards.add(_WorkerNotice(
          '住户申请撤销报修',
          '原因：${revoke.reason}\n${formatVisitTime(revoke.deadline)} 前未回应将自动通过；如有异议可联系物业。',
          actions: <Widget>[
            FilledButton(
                onPressed: _saving ? null : _acknowledgeRevoke,
                child: const Text('已知晓')),
          ]));
    }
    if (reschedule != null) {
      cards.add(_WorkerNotice(
          reschedule.by == 'worker' ? '你发起的改约，等待住户同意' : '住户提议修改上门时间',
          '新时间：${formatVisitTime(reschedule.proposedTime)}\n原因：${reschedule.reason}\n同意前按原约定时间执行',
          actions: reschedule.by == 'worker'
              ? const <Widget>[]
              : <Widget>[
                  TextButton(
                      onPressed: _saving ? null : () => _respond(false),
                      child: const Text('不同意')),
                  FilledButton(
                      onPressed: _saving ? null : () => _respond(true),
                      child: const Text('同意新时间')),
                ]));
    }
    if (record.status == RepairStatus.processing &&
        record.agreedTime.isEmpty &&
        reschedule == null) {
      cards.add(const _WorkerNotice('尚未约定上门时间', '请电话联系住户后，点“修改预约”提出时间'));
    }
    if (record.status == RepairStatus.confirming) {
      cards.add(_WorkerNotice('已提交完工，等待住户确认',
          '${formatVisitTime(record.confirmDeadline)} 前住户未操作将自动确认'));
    }
    return cards;
  }
}

class _WorkerNotice extends StatelessWidget {
  const _WorkerNotice(this.title, this.detail,
      {this.actions = const <Widget>[]});
  final String title;
  final String detail;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: const Color(0xFFFFF8E7),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(detail,
                  style: const TextStyle(color: AppColors.textSecondary)),
              if (actions.isNotEmpty)
                Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(spacing: 8, children: actions)),
            ],
          ),
        ),
      );
}
