import 'dart:async';
import 'package:flutter/material.dart';
import '../../api/repair.dart';
import '../../api/worker.dart';
import '../../models/repair.dart';
import '../../platform/visitor_pass_share.dart';
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
import '../../widgets/repair_schedule_card.dart';
import 'worker_pool_pages.dart';

class WorkerPage extends StatefulWidget {
  const WorkerPage({
    this.recordsLoader = getWorkerRepairsApi,
    this.recordLoader = getWorkerRepairApi,
    this.readStore,
    this.tokens,
    this.skillsLoader = getWorkerSkillsApi,
    super.key,
  });
  final Future<List<RepairRecord>> Function() recordsLoader;
  final Future<RepairRecord> Function(String id) recordLoader;
  final WorkerRepairReadStore? readStore;
  final TokenManager? tokens;
  final Future<WorkerSkills> Function() skillsLoader;
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
  WorkerSkills? _skills;
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
      try {
        final skills = await widget.skillsLoader();
        if (!mounted || session != _tokens.sessionId) return;
        setState(() => _skills = skills);
      } on Object catch (_) { /* 工单可独立使用；技能页可重试查询。 */ }
    } on Object catch (error) {
      if (mounted && session == _tokens.sessionId) {
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
      unawaited(clearVisitorPassShareCache());
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
        Wrap(spacing: 12, children: <Widget>[
          FilledButton(onPressed: () => Navigator.push<void>(context, MaterialPageRoute(builder: (_) => const WorkerPoolPage())), child: const Text('可接单')),
          TextButton(onPressed: () async {
            final session = _tokens.sessionId;
            await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const WorkerSkillsPage()));
            if (!mounted || session != _tokens.sessionId) return;
            await _load();
          }, child: const Text('我的技能')),
        ]),
        if (_skills != null && _skills!.skills.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('请先登记你会的维修技能，登记后才能接新单')),
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
                                '${record.priority == 'urgent' ? ' · 急' : ''}${record.autoAccepted ? ' · 超时生效' : ''}'
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
                                          onReassigned: _load,
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
  const WorkerProposeAction(this.slot, this.reason);
  final String slot;
  final String reason;
}

final class WorkerRespondAction extends WorkerAction {
  const WorkerRespondAction({required this.accept, this.reason = ''});
  final bool accept;
  final String reason;
}

final class WorkerProgressAction extends WorkerAction {
  const WorkerProgressAction(this.content, {this.needsAdmin = false});
  final String content;
  final bool needsAdmin;
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
    case WorkerProposeAction(:final String slot, :final String reason):
      return proposeWorkerRescheduleApi(record, slot, reason);
    case WorkerRespondAction(:final bool accept, :final String reason):
      return respondWorkerRescheduleApi(record, accept: accept, reason: reason);
    case WorkerProgressAction(:final String content, :final bool needsAdmin):
      return workerProgressApi(record, content, needsAdmin: needsAdmin);
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
    this.resultSaver = saveWorkerRepairResultApi,
    this.acceptor = _defaultAcceptor,
    this.actionLoader = runWorkerAction,
    this.slotsLoader = getRepairSlotsApi,
    this.onReassigned,
    this.readStore,
    super.key,
  });
  final String id;
  final WorkerRepairReadStore? readStore;
  final Future<RepairRecord> Function(String id) recordLoader;
  final Future<RepairRecord> Function(RepairRecord record,
      {required bool complete, String result}) processor;
  final WorkerActionLoader actionLoader;
  final Future<RepairRecord> Function(RepairRecord record,
      {required bool ready, required String result, required num cost,
      String? problem, String? cause}) resultSaver;
  final Future<RepairRecord> Function(RepairRecord, {String? slot, String reason}) acceptor;
  final RepairSlotsLoader slotsLoader;
  final Future<void> Function()? onReassigned;
  @override
  State<WorkerDetailPage> createState() => _WorkerDetailPageState();
}

Future<RepairRecord> _defaultProcessor(RepairRecord record,
        {required bool complete, String result = ''}) =>
    processWorkerRepairApi(record, complete: complete, result: result);

Future<RepairRecord> _defaultAcceptor(RepairRecord record, {String? slot, String reason = ''}) =>
    processWorkerRepairApi(record, complete: false, slot: slot, reason: reason);

class _WorkerDetailPageState extends State<WorkerDetailPage> with WidgetsBindingObserver {
  String _proposalReason = '';
  String? _proposalSlot;
  String _progressText = '';
  bool _needsAdmin = false;
  bool _preparing = false;
  bool _reassigned = false;
  Future<void> _handleReassigned() async {
    if (!mounted) return;
    setState(() { _record = null; _reassigned = true; _error = '该工单已不再指派给你（可能已由物业改派）'; });
    await widget.onReassigned?.call();
  }
  RepairRecord? _record;
  final _result = TextEditingController();
  final _resultFocus = FocusNode();
  final _cost = TextEditingController(text: '0');
  final _problem = TextEditingController();
  final _cause = TextEditingController(text: '待排查');
  int? _editingRound;
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
      if (error is NetworkException && error.statusCode == 404) { await _handleReassigned(); return; }
      if (error is NetworkException && error.statusCode == 409) {
        await PromptAction.showWarning('${error.message}，已刷新最新状态');
        if (!mounted) return;
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
    final RepairSlot? time = await pickVisitTime(context,
        initialSlot: _proposalSlot ?? record.slot, excludeId: record.id, loader: widget.slotsLoader,
        title: '选择新的上门时间');
    if (time == null || !mounted) return;
    _proposalSlot = time.slot;
    final String? reason = await askReason(context,
        title: record.agreedTime.isEmpty ? '首次提议上门时间' : '修改预约',
        label: '改约原因',
        initialText: _proposalReason,
        message: '新时间：${formatSlotWindow(slot: time.slot, start: time.start, end: time.end)}\n'
            '请先电话告知住户。住户同意后新时间才生效，之前按原约定。',
        phone: record.mobile,
        notifyHint: '我已电话告知住户',
        confirmText: '发起改约');
    if (reason != null && mounted) {
      _proposalReason = reason;
      await _act(WorkerProposeAction(time.slot, reason), '时间已提议，等待住户回应');
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
    final ({String content, bool needsAdmin})? value = await showDialog<({String content, bool needsAdmin})>(
      context: context, builder: (_) => _ProgressDialog(content: _progressText, needsAdmin: _needsAdmin));
    if (value != null && mounted) {
      _progressText = value.content; _needsAdmin = value.needsAdmin;
      await _act(WorkerProgressAction(value.content, needsAdmin: value.needsAdmin), '进展已记录');
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
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _result.dispose();
    _resultFocus.dispose();
    _cost.dispose();
    _problem.dispose();
    _cause.dispose();
    super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load());
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
        if (_editingRound != record.round) {
          _editingRound = record.round;
          final current = record.rounds.isEmpty ? null : record.rounds.last;
          _problem.text = current?.problem ?? record.description;
          _cause.text = (current?.cause.isNotEmpty ?? false) ? current!.cause : '待排查';
          _result.text = current?.note ?? '';
          _cost.text = '${current?.cost ?? 0}';
        }
        _rememberDisplayed(record, session);
      }
    } on Object catch (error) {
      if (!mounted || session != tokenManager.sessionId) return;
      if (error is NetworkException && error.statusCode == 404) { await _handleReassigned(); return; }
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

  /// 有安排直接沿用；无安排可仅接单，也可同时向住户提出首次时段。
  Future<({String? slot, String reason})?> _confirmVisitTime(
      RepairRecord record) async {
    if (record.slot.isNotEmpty || record.agreedTime.isNotEmpty) return (slot: null, reason: '');
    final String? choice = await showDialog<String>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: const Text('确认上门时间'),
        content: const Text('当前等待安排上门时间，可以只接单，或同时提出首次时段。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('返回')),
          OutlinedButton(
              onPressed: () => Navigator.pop(dialog, 'other'),
              child: const Text('接单并提议时间')),
          FilledButton(onPressed: () => Navigator.pop(dialog, 'accept'), child: const Text('只接单')),
        ],
      ),
    );
    if (choice == null || !mounted) return null;
    if (choice == 'accept') return (slot: null, reason: '');
    final RepairSlot? time = await pickVisitTime(context, initialSlot: _proposalSlot, excludeId: record.id, loader: widget.slotsLoader);
    if (time == null || !mounted) return null;
    final String? reason = await askReason(context,
        title: '说明原因',
        label: '为什么选择这个时间',
        initialText: _proposalReason,
        message: '新时间：${formatSlotWindow(slot: time.slot, start: time.start, end: time.end)}\n请先电话告知住户。',
        notifyHint: '我已电话告知住户',
        phone: record.mobile,
        confirmText: '接单');
    if (reason == null || !mounted) return null;
    _proposalReason = reason; _proposalSlot = time.slot;
    return (slot: time.slot, reason: reason);
  }

  Future<void> _process({bool saveOnly = false, bool ready = false}) async {
    final record = _record;
    if (_saving || _loading || _preparing || record == null) return;
    final bool complete = record.status == RepairStatus.processing;
    final String result = record.round > 1 ? _cause.text.trim() : _result.text.trim();
    num cost = 0;
    ({String? slot, String reason})? visit;
    if (complete) {
      if (record.round > 1 && (_problem.text.trim().isEmpty || _cause.text.trim().isEmpty)) {
        await PromptAction.showWarning('请填写本次问题和排查原因，原因不明可填待排查');
        return;
      }
      if ((!saveOnly || ready) && result.isEmpty) {
        setState(() => _resultError = '请填写处理结果后再完成维修');
        _resultFocus.requestFocus();
        await PromptAction.showWarning('请填写处理结果后再完成维修');
        return;
      }
      final num? parsed = num.tryParse(_cost.text.trim().isEmpty ? '0' : _cost.text.trim());
      if (parsed == null || !parsed.isFinite || parsed < 0) {
        setState(() => _costError = '请填写有效金额，无费用填 0');
        await PromptAction.showWarning('请填写有效金额，无费用填 0');
        return;
      }
      cost = parsed;
    } else if (_usingDefaultProcessor) {
      _preparing = true;
      try { visit = await _confirmVisitTime(record); } finally { _preparing = false; }
      if (visit == null || !mounted) return;
    }
    final session = tokenManager.sessionId;
    setState(() => _saving = true);
    try {
      final RepairRecord updated = saveOnly
          ? await widget.resultSaver(record, ready: ready, result: result, cost: cost,
              problem: record.round > 1 ? _problem.text : null,
              cause: record.round > 1 ? _cause.text : null)
          : _usingDefaultProcessor
          ? complete ? await processWorkerRepairApi(record,
              complete: complete,
              result: result,
              cost: cost,
              saveOnly: saveOnly,
              ready: ready,
              problem: record.round > 1 ? _problem.text : null,
              cause: record.round > 1 ? _cause.text : null,
              slot: visit?.slot,
              reason: visit?.reason ?? '')
            : await widget.acceptor(record, slot: visit?.slot, reason: visit?.reason ?? '')
          : await widget.processor(record,
              complete: complete, result: result);
      if (!mounted || session != tokenManager.sessionId) return;
      setState(() => _record = updated);
      _rememberDisplayed(updated, session);
      await PromptAction.showSuccess(saveOnly ? (ready ? '结果已保存，业主可在报修详情直接确认修好' : '进度已保存') : updated.status == RepairStatus.processing
          ? '接单成功'
          : updated.status == RepairStatus.completed
              ? '维修已完成'
              : '已提交完工，等待住户确认');
      if (!mounted || session != tokenManager.sessionId) return;
      // 提交完工后返回工作台，列表按新状态刷新；接单后留在详情，便于约时间。
      if (complete && !saveOnly) Navigator.pop(context);
    } on Object catch (error) {
      if (!mounted || session != tokenManager.sessionId) return;
      if (error is NetworkException && error.statusCode == 404) { await _handleReassigned(); return; }
      if (error is NetworkException && error.statusCode == 409) {
        await PromptAction.showWarning('${error.message}，已刷新最新状态');
        if (!mounted) return;
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
                      if (_reassigned) TextButton(onPressed: () => Navigator.pop(context), child: const Text('返回工单列表'))
                      else TextButton(onPressed: _load, child: const Text('重试'))
                    ]))
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 792),
                      child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: <Widget>[
                            RepairProgress(record: record),
                            RepairScheduleBadges(record: record),
                            if (record.hasActiveSchedule) RepairScheduleCard(record: record, isResident: false),
                            const SizedBox(height: 12),
                            Text(record.repairItemName,
                                style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 16),
                            ..._workerNotices(record),
                            if (record.staffingIssue.isNotEmpty)
                              Text('待协调：${record.staffingIssue}；请联系物业确认安排', style: const TextStyle(color: AppColors.danger)),
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
                              if (record.round > 1) ...<Widget>[
                                TextField(controller: _problem, enabled: !_saving, maxLength: 1000,
                                  decoration: const InputDecoration(labelText: '本次问题')),
                                TextField(controller: _cause, enabled: !_saving, maxLength: 1000, maxLines: 3,
                                  decoration: const InputDecoration(labelText: '重新排查原因（含上次未查出的原因）', helperText: '原因不明可填写待排查；查明后在此补充调整方案和处理结果', helperMaxLines: 3)),
                              ],
                              if (record.round == 1) Padding(
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
                              const SizedBox(height: 16),
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
                              OutlinedButton(
                                onPressed: _saving || _loading ? null : () => _process(saveOnly: true),
                                child: const Text('保存进度')),
                              OutlinedButton(
                                onPressed: _saving || _loading ? null : () => _process(saveOnly: true, ready: true),
                                child: const Text('保存结果，供现场业主确认')),
                              const Text('业主在现场：保存结果和费用后，业主在自己的报修详情点击确认修好。业主不在场：点击提交完工，等待验收。'),
                            ],
                            if (record.status == RepairStatus.assigned ||
                                record.status == RepairStatus.processing)
                              Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
                                  if (record.canReschedule)
                                    OutlinedButton(
                                        onPressed: _saving ? null : _propose,
                                        child: Text(record.agreedTime.isEmpty ? '首次提议时间' : '修改预约')),
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
    if (reschedule != null && record.firstSchedule == null) {
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
    if (record.status == RepairStatus.confirming) {
      cards.add(_WorkerNotice('已提交完工，等待住户确认',
          '${formatVisitTime(record.confirmDeadline)} 前住户未操作将自动确认'));
    }
    return cards;
  }
}

class _ProgressDialog extends StatefulWidget {
  const _ProgressDialog({required this.content, required this.needsAdmin});
  final String content;
  final bool needsAdmin;
  @override
  State<_ProgressDialog> createState() => _ProgressDialogState();
}

class _ProgressDialogState extends State<_ProgressDialog> {
  late final TextEditingController _content = TextEditingController(text: widget.content);
  late bool _needsAdmin = widget.needsAdmin;
  @override
  void dispose() { _content.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('补充进展'),
    content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: _content, maxLength: 1000, maxLines: 3,
        onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: '进展说明（必填）')),
      CheckboxListTile(title: const Text('需要物业协助'), value: _needsAdmin,
        onChanged: (value) => setState(() => _needsAdmin = value ?? false)),
    ])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: _content.text.trim().isEmpty ? null : () => Navigator.pop(context,
        (content: _content.text.trim(), needsAdmin: _needsAdmin)), child: const Text('提交进展')),
    ],
  );
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
