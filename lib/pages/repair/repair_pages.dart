import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart' show Get, Inst;

import '../../api/house.dart';
import '../../api/repair.dart';
import '../../api/user.dart';
import '../../controller/user_info_controller.dart';
import '../../models/house.dart';
import '../../models/repair.dart';
import '../../platform/avatar_picker.dart';
import '../../platform/repair_photo_picker.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/data_state.dart';
import '../../utils/date_utils.dart';
import '../../utils/logger.dart';
import '../../utils/repair_draft_store.dart';
import '../../utils/retry_strategy.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';
import '../../utils/validators.dart';
import '../../widgets/async_state_view.dart';
import '../../widgets/notification_actions.dart';
import '../../widgets/repair_dialogs.dart';
import '../../widgets/repair_photos.dart';
import '../../widgets/repair_progress.dart';
import '../../widgets/repair_schedule_card.dart';
import '../../widgets/repair_slot_picker.dart';

/// 报修状态筛选枚举
enum RepairStatusFilter {
  /// 全部
  all,

  /// 待处理
  pending,
  waiting,

  /// 处理中
  processing,

  /// 已完成
  completed;

  /// 显示文字
  String get displayName {
    switch (this) {
      case RepairStatusFilter.all:
        return '全部';
      case RepairStatusFilter.pending:
        return '待派单';
      case RepairStatusFilter.waiting:
        return '待接单';
      case RepairStatusFilter.processing:
        return '处理中';
      case RepairStatusFilter.completed:
        return '已完成';
    }
  }

  /// 匹配报修记录的状态
  ///
  /// 返回 true 表示该记录应该显示。“处理中”包含待住户确认，因为都还没结单。
  bool matches(RepairRecord record) {
    switch (this) {
      case RepairStatusFilter.all:
        return true;
      case RepairStatusFilter.pending:
        return record.status == RepairStatus.pending;
      case RepairStatusFilter.waiting:
        return record.status == RepairStatus.assigned;
      case RepairStatusFilter.processing:
        return record.status == RepairStatus.processing ||
            record.status == RepairStatus.confirming;
      case RepairStatusFilter.completed:
        return record.status == RepairStatus.completed;
    }
  }
}

class RepairListPage extends StatefulWidget {
  const RepairListPage({this.loader = getPreloadedRepairListApi, super.key});
  static const String routeName = AppRoutes.repairList;
  final RepairListLoader loader;
  @override
  State<RepairListPage> createState() => _RepairListPageState();
}

class _RepairListPageState extends State<RepairListPage> {
  // 使用统一的状态管理
  DataState<List<RepairRecord>> _state = DataState.idle();

  // 当前选中的筛选条件
  RepairStatusFilter _currentFilter = RepairStatusFilter.all;

  // 缓存的过滤结果，避免每次 build 都重新过滤
  List<RepairRecord> _cachedFilteredRecords = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// 应用筛选逻辑，返回过滤后的列表
  List<RepairRecord> _applyFilter() {
    if (!_state.hasData) return const [];
    return _state.data!.where(_currentFilter.matches).toList();
  }

  /// 切换筛选条件
  void _changeFilter(RepairStatusFilter newFilter) {
    if (_currentFilter == newFilter) return;
    setState(() {
      _currentFilter = newFilter;
      _cachedFilteredRecords = _applyFilter();
    });
  }

  /// 加载报修列表
  ///
  /// [isManualRetry] 是否是用户手动点击重试按钮触发的
  Future<void> _load({bool isManualRetry = false}) async {
    // 如果正在加载，不重复加载
    if (!mounted || _state.isLoading) return;
    final int sessionId = tokenManager.sessionId;

    // 开始加载，保留旧数据
    setState(() => _state = DataState.loading(_state.data));

    try {
      // 使用智能重试策略加载数据
      final records = await retryAsync(
        action: () => widget.loader(),
        strategy: isManualRetry ? RetryStrategy.manual : RetryStrategy.auto,
        shouldRetry: () => mounted,
        onRetry: (attempt, error) {
          Logger.debug('[RepairList] 第 $attempt 次重试');
        },
      );

      if (!mounted) return;
      if (tokenManager.sessionId != sessionId) {
        throw const SessionChangedException();
      }
      setState(() {
        _state = DataState.success(records);
        _cachedFilteredRecords = _applyFilter();
      });
    } on Object catch (error) {
      final msg = describeError(error, fallback: '获取报修列表失败，请重试');
      if (!mounted) return;

      // 加载失败，保留旧数据
      setState(() {
        _state = DataState.error(
          msg,
          tokenManager.sessionId == sessionId ? _state.data : null,
        );
        _cachedFilteredRecords = _applyFilter();
      });

      // 如果是第一次加载失败（没有旧数据），显示错误提示
      // 如果是刷新失败（有旧数据），只在底部toast提示
      if (!_state.hasData) {
        await PromptAction.showError(msg);
      } else {
        await PromptAction.showToast(msg);
      }
    }
  }

  Future<void> _open(String route, [Object? arguments]) async {
    final bool result =
        await Navigator.pushNamed<bool>(context, route, arguments: arguments) ??
            false;
    if (mounted && (result || route == AppRoutes.repairDetail)) await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: const Text('我的报修'), actions: const [NotificationInboxButton()]),
        body: Column(children: <Widget>[
          // 筛选按钮行
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: RepairStatusFilter.values.map((filter) {
                final isSelected = _currentFilter == filter;
                return _buildFilterChip(
                  label: filter.displayName,
                  isSelected: isSelected,
                  onTap: () => _changeFilter(filter),
                );
              }).toList(),
            ),
          ),
          Expanded(
              child: AsyncStateView(
            isLoading: _state.isLoading,
            errorMessage: _state.errorMessage,
            onRetry: () => _load(isManualRetry: true), // 手动重试标记
            hasContent: _state.hasData,
            builder: (BuildContext context) => RefreshIndicator(
              onRefresh: _load,
              child: _cachedFilteredRecords.isEmpty
                  ? ListView(children: <Widget>[
                      const SizedBox(height: 180),
                      const Icon(Icons.build_outlined,
                          size: 52, color: AppColors.divider),
                      const SizedBox(height: 12),
                      Center(
                          child: Text(
                        _currentFilter == RepairStatusFilter.all
                            ? '还没有报修记录，点击下方按钮新增吧'
                            : '没有符合条件的报修记录\n试试切换到"全部"查看',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textTertiary),
                      ))
                    ])
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: _cachedFilteredRecords.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, int index) {
                        final item = _cachedFilteredRecords[index];
                        return Card(
                            child: ListTile(
                          title: Text(item.repairItemName.isEmpty
                              ? '维修服务'
                              : item.repairItemName),
                          subtitle: Text(
                              '${item.visitTime.isNotEmpty ? formatVisitTime(item.visitTime) : item.appointment}\n${item.mobile}'),
                          isThreeLine: true,
                          trailing: Text(item.statusText,
                              style: const TextStyle(color: AppColors.accent)),
                          onTap: item.id.isEmpty
                              ? null
                              : () =>
                                  _open(RepairDetailPage.routeName, item.id),
                        ));
                      }),
            ),
          )),
          SafeArea(
              top: false,
              child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: FilledButton.icon(
                          onPressed: () => _open(RepairFormPage.routeName),
                          icon: const Icon(Icons.add),
                          label: const Text('新增报修'))))),
        ]),
      );

  /// 构建自定义筛选按钮
  Widget _buildFilterChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.accent : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? AppColors.accent : const Color(0xFFE4E7EC),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : AppColors.textSecondary,
            fontSize: 14,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class RepairDetailPage extends StatefulWidget {
  const RepairDetailPage(
      {this.loader = getRepairDetailApi,
      this.cancelLoader = cancelRepairApi,
      this.actionLoader = runRepairAction,
      this.slotsLoader = getRepairSlotsApi,
      super.key});
  static const String routeName = AppRoutes.repairDetail;
  final RepairDetailLoader loader;
  final CancelRepairLoader cancelLoader;
  final RepairActionLoader actionLoader;
  final RepairSlotsLoader slotsLoader;
  @override
  State<RepairDetailPage> createState() => _RepairDetailPageState();
}

class _RepairDetailPageState extends State<RepairDetailPage> with WidgetsBindingObserver {
  String _proposalReason = '';
  String? _proposalSlot;
  String _responseReason = '';
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }
  String _id = '';
  RepairRecord? _record;
  String? _error;
  bool _loading = false;
  bool _cancelling = false;
  bool _confirming = false;
  bool _acting = false;
  bool _changed = false;

  /// 通用的工单操作：防重复提交；异步后检查 mounted 与会话；409 时刷新权威数据，不重放旧操作。
  Future<void> _act(
      RepairAction action, String success, String fallback) async {
    final RepairRecord? record = _record;
    if (_acting || record == null) return;
    final int sessionId = tokenManager.sessionId;
    setState(() => _acting = true);
    try {
      final RepairRecord updated = await widget.actionLoader(record, action);
      if (!mounted || tokenManager.sessionId != sessionId) return;
      _changed = true;
      setState(() => _record = updated);
      await PromptAction.showSuccess(success);
    } on Object catch (error) {
      if (!mounted || tokenManager.sessionId != sessionId) return;
      if (error is NetworkException && error.statusCode == 409) {
        await PromptAction.showWarning('${error.message}，已刷新最新状态');
        if (!mounted) return;
        if (mounted) setState(() => _acting = false);
        await _load();
        return;
      }
      await PromptAction.showError(describeError(error, fallback: fallback));
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _confirmRepair() async {
    final bool ok = await showDialog<bool>(
            context: context,
            builder: (BuildContext dialog) => AlertDialog(
                    title: const Text('确认已修好'),
                    content: const Text('确认后进入售后期，售后期内如有问题仍可申请返修。'),
                    actions: <Widget>[
                      TextButton(
                          onPressed: () => Navigator.pop(dialog, false),
                          child: const Text('返回')),
                      FilledButton(
                          onPressed: () => Navigator.pop(dialog, true),
                          child: const Text('确认修好')),
                    ])) ??
        false;
    if (ok && mounted) {
      await _act(const ConfirmAction(), '已确认修好', '确认失败，请重试');
    }
  }

  Future<void> _rejectRepair() async {
    final String? reason = await askReason(context,
        title: '还没修好',
        label: '哪里还有问题',
        message: '工单会直接交回原师傅返修。每张工单只有一次返修机会。',
        confirmText: '交回返修');
    if (reason != null && mounted) {
      await _act(RejectAction(reason), '已交回师傅返修', '提交失败，请重试');
    }
  }

  Future<void> _aftersale() async {
    final String? reason = await askReason(context,
        title: '申请售后返修',
        label: '遇到了什么问题',
        message: '申请提交后由物业审核，通过后交回原师傅返修。每张工单只有一次返修机会。',
        confirmText: '提交申请');
    if (reason != null && mounted) {
      await _act(AftersaleAction(reason), '售后申请已提交，等待物业审核', '提交失败，请重试');
    }
  }

  Future<void> _feedback() async {
    final String? content = await askReason(context,
        title: '反馈问题',
        label: '问题说明',
        message: '物业会核实处理并在时间线中回复。',
        confirmText: '提交反馈');
    if (content != null && mounted) {
      await _act(FeedbackAction(content), '反馈已提交', '提交失败，请重试');
    }
  }

  Future<void> _revoke() async {
    final RepairRecord? record = _record;
    if (record == null) return;
    final bool needsWorker = record.revokeNeedsWorker;
    final String? reason = await askReason(context,
        title: needsWorker ? '申请撤销报修' : '撤销报修',
        label: '撤销原因',
        message: needsWorker
            ? '师傅已接单，请先电话告知师傅。提交后师傅确认即撤销；师傅未回应时，到期自动通过。'
            : '撤销后工单关闭，如需维修请重新报修。',
        phone: needsWorker ? record.workerMobile : null,
        notifyHint: needsWorker ? '我已电话告知师傅' : null,
        confirmText: needsWorker ? '提交撤销申请' : '确认撤销',
        danger: true);
    if (reason == null || !mounted) return;
    await _act(RevokeAction(reason, notified: needsWorker),
        needsWorker ? '撤销申请已提交' : '报修已撤销', '撤销失败，请重试');
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
        title: '修改预约',
        label: '改约原因',
        initialText: _proposalReason,
        message: '新时间：${formatSlotWindow(slot: time.slot, start: time.start, end: time.end)}\n'
            '请先电话告知师傅。师傅同意后新时间才生效，之前按原约定。',
        phone: record.workerMobile,
        notifyHint: '我已电话告知师傅',
        confirmText: '发起改约');
    if (reason != null && mounted) {
      _proposalReason = reason;
      await _act(ProposeAction(time.slot, reason), '改约已发起，等待师傅同意', '改约失败，请重试');
    }
  }

  Future<void> _respond(bool accept) async {
    final bool first = _record?.firstSchedule != null;
    String reason = '';
    if (!accept) {
      final String? value = await askReason(context,
          title: first ? '拒绝首次上门时间' : '不同意改约',
          label: '原因',
          initialText: _responseReason,
          message: first ? '拒绝后等待师傅或物业重新提议，请填写原因。' : '将保持原约定时间，建议电话与师傅再沟通。',
          confirmText: first ? '确认拒绝' : '保持原约定');
      if (value == null || !mounted) return;
      reason = value;
      _responseReason = reason;
    }
    await _act(RespondAction(accept: accept, reason: reason),
        accept ? '已同意新时间' : first ? '已拒绝，等待重新安排' : '已保持原约定', '操作失败，请重试');
  }
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_id.isEmpty) {
      _id = ModalRoute.of(context)?.settings.arguments?.toString().trim() ?? '';
      if (_id.isEmpty) {
        _error = '报修参数不正确';
      } else {
        unawaited(_load());
      }
    }
  }

  Future<void> _load() async {
    if (_loading || _id.isEmpty) return;
    final int session = tokenManager.sessionId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await widget.loader(_id);
      if (mounted && session == tokenManager.sessionId) setState(() => _record = value);
    } on Object catch (error) {
      final msg = describeError(error, fallback: '获取报修详情失败，请重试');
      if (mounted && session == tokenManager.sessionId) {
        setState(() => _error = msg);
        await PromptAction.showError(msg);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 未接单前的直接撤销沿用原有流程；师傅接单后走 [_revoke] 的撤销申请。
  Future<void> _cancel() async {
    final RepairRecord? record = _record;
    if (record != null && record.revokeNeedsWorker) return _revoke();
    if (_cancelling || _confirming || _id.isEmpty) return;
    // The confirmation dialog is part of the operation too.
    setState(() => _confirming = true);
    try {
      final confirmed = await showDialog<bool>(
              context: context,
              builder: (dialog) => AlertDialog(
                      title: const Text('取消报修'),
                      content: const Text('确定取消该报修申请吗？'),
                      actions: <Widget>[
                        TextButton(
                            onPressed: () => Navigator.pop(dialog, false),
                            child: const Text('返回')),
                        FilledButton(
                            onPressed: () => Navigator.pop(dialog, true),
                            child: const Text('确认取消'))
                      ])) ??
          false;
      if (!confirmed || !mounted) return;
      setState(() => _cancelling = true);
      await widget.cancelLoader(_id);
      if (!mounted) return;
      await PromptAction.showSuccess('报修已取消');
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (!mounted) return;
      await PromptAction.showError(
          describeError(error, fallback: '取消报修失败，请重试'));
    } finally {
      if (mounted) {
        setState(() {
          _cancelling = false;
          _confirming = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final RepairRecord? record = _record;
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, _) {
        // 有操作成功时通知列表刷新。
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: const Text('报修详情'), actions: <Widget>[
          if (record != null) RepairReminderButton(repairId: record.id),
          const NotificationInboxButton(),
          IconButton(
              tooltip: '刷新进度',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh)),
        ]),
        body: AsyncStateView(
          isLoading: _loading,
          errorMessage: _error,
          onRetry: _load,
          hasContent: record != null,
          builder: (_) => record == null
              ? const SizedBox.shrink()
              : AbsorbPointer(
                  absorbing: _acting,
                  child: ListView(children: <Widget>[
                    if (record.workflowVersion == 1)
                      RepairProgress(record: record),
                    ..._notices(record),
                    if (record.hasActiveSchedule) RepairScheduleCard(record: record, isResident: true, onAccept: () => _respond(true),
                      onDecline: () => _respond(false), onInconvenient: record.canFeedback ? _feedback : null),
                    const _Section('报修信息'),
                    _Row('维修项目', record.repairItemName),
                    _Row(
                        record.agreedTime.isNotEmpty ? '约定时间' : '期望时间',
                        record.visitTime.isNotEmpty
                            ? formatVisitTime(record.visitTime)
                            : record.appointment),
                    if (record.agreedTime.isNotEmpty &&
                        record.expectedTime.isNotEmpty &&
                        record.agreedTime != record.expectedTime)
                      _Row('期望时间', formatVisitTime(record.expectedTime)),
                    _Row('联系电话', record.mobile),
                    _Row('报修房屋', record.houseInfo),
                    _Row('处理状态', record.statusText),
                    if (record.round > 1) _Row('维修轮次', '第 ${record.round} 轮（返修）'),
                    const _Section('联系方式'),
                    if (record.workerName.isNotEmpty)
                      _Contact('维修师傅 ${record.workerName}', record.workerMobile),
                    _Contact('物业', record.propertyPhone),
                    const _Section('故障描述'),
                    _Row('描述', record.description),
                    if (record.attachment.isNotEmpty)
                      Padding(
                          padding: const EdgeInsets.all(16),
                          child: RepairPhotos(urls: record.attachment)),
                    ..._roundHistory(record),
                  ]),
                ),
        ),
        bottomNavigationBar: record == null ? null : _actions(record),
      ),
    );
  }

  /// 顶部提示卡：待你回应的事项和截止时刻，不依赖推送。
  List<Widget> _notices(RepairRecord record) {
    final List<Widget> cards = <Widget>[];
    final RepairPending? reschedule = record.reschedule;
    if (record.canConfirm) {
      cards.add(_Notice(
          '师傅已提交完工，请确认是否修好',
          record.confirmDeadline.isEmpty
              ? ''
              : '${formatVisitTime(record.confirmDeadline)} 前未操作，将自动确认完成'));
    }
    if (reschedule != null && record.firstSchedule == null) {
      cards.add(_Notice(
          reschedule.by == 'resident' ? '你发起的改约，等待师傅同意' : '师傅提议修改上门时间',
          '新时间：${formatVisitTime(reschedule.proposedTime)}\n原因：${reschedule.reason}\n'
              '同意前按原约定时间执行',
          actions: reschedule.by == 'resident'
              ? const <Widget>[]
              : <Widget>[
                  TextButton(
                      onPressed: () => _respond(false),
                      child: const Text('不同意')),
                  FilledButton(
                      onPressed: () => _respond(true),
                      child: const Text('同意新时间')),
                ]));
    }
    if (record.revokeRequest != null) {
      cards.add(_Notice('撤销申请已提交，等待师傅确认',
          '${formatVisitTime(record.revokeRequest!.deadline)} 前师傅未回应将自动通过'));
    }
    if (record.status == RepairStatus.pending &&
        record.timeline.any((RepairEvent e) => e.action == 'released')) {
      cards.add(const _Notice('物业正在为你重新安排师傅', '安排好后会在这里更新'));
    }
    if (record.aftersale != null) {
      cards.add(_Notice('售后申请待物业审核', record.aftersale!.reason));
    }
    if (record.feedback != null) {
      cards.add(_Notice('反馈已提交，等待物业回复', record.feedback!.reason));
    }
    if (record.inWarranty) {
      cards.add(_Notice('售后期至 ${formatVisitTime(record.warrantyEnd)}',
          record.reworkUsed ? '返修机会已使用，如有问题可反馈给物业' : '期间如有问题，可申请售后返修'));
    }
    return cards;
  }

  /// 每一轮的维修说明、费用与确认结果都保留，不覆盖上一轮。
  List<Widget> _roundHistory(RepairRecord record) {
    final List<Widget> rows = <Widget>[];
    for (final RepairRound round in record.rounds) {
      if (round.completedAt.isEmpty && round.rejectReason.isEmpty) continue;
      rows
        ..add(_Section('第 ${round.number} 轮维修'))
        ..add(_Row('维修说明', round.note))
        ..add(_Row('上报费用', round.cost == null ? '' : '${round.cost} 元'));
      if (round.verifiedNote.isNotEmpty) rows.add(_Row('物业核实', round.verifiedNote));
      if (round.rejectReason.isNotEmpty) rows.add(_Row('未修好原因', round.rejectReason));
      if (round.confirmedAt.isNotEmpty) {
        rows.add(_Row(
            round.confirmedBy == 'system' ? '自动确认' : '住户确认',
            formatVisitTime(round.confirmedAt)));
      }
    }
    return rows;
  }

  Widget? _actions(RepairRecord record) {
    final List<Widget> buttons = <Widget>[
      if (record.canConfirm)
        FilledButton(onPressed: _confirmRepair, child: const Text('确认修好')),
      if (record.canReject)
        OutlinedButton(onPressed: _rejectRepair, child: const Text('还没修好')),
      if (record.canReschedule && record.agreedTime.isNotEmpty)
        OutlinedButton(onPressed: _propose, child: const Text('修改预约')),
      if (record.canApplyAftersale)
        FilledButton(onPressed: _aftersale, child: const Text('申请售后返修')),
      if (record.canFeedback &&
          (record.reworkUsed ||
              record.status == RepairStatus.completed ||
              record.status == RepairStatus.confirming))
        OutlinedButton(onPressed: _feedback, child: const Text('反馈问题')),
      if (record.canRevoke)
        FilledButton(
          onPressed: _cancelling || _confirming ? null : _cancel,
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          child: _cancelling
              ? const CircularProgressIndicator()
              : Text(record.revokeNeedsWorker ? '申请撤销' : '取消报修'),
        ),
    ];
    if (buttons.isEmpty) return null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.end,
          children: _acting
              ? const <Widget>[CircularProgressIndicator()]
              : buttons,
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.title, this.detail, {this.actions = const <Widget>[]});
  final String title;
  final String detail;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        color: const Color(0xFFFFF8E7),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (detail.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(detail,
                    style: const TextStyle(color: AppColors.textSecondary)),
              ],
              if (actions.isNotEmpty)
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(spacing: 8, children: actions),
                ),
            ],
          ),
        ),
      );
}

class _Contact extends StatelessWidget {
  const _Contact(this.label, this.phone);
  final String label;
  final String phone;
  @override
  Widget build(BuildContext context) => Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: PhoneLine(label: label, phone: phone));
}

class RepairFormPage extends StatefulWidget {
  const RepairFormPage(
      {this.houseLoader = getHouseListApi,
      this.itemLoader = getRepairItemsApi,
      this.submitter = submitRepairApi,
      this.userInfoLoader = getUserInfoApi,
      this.photoPicker = pickRepairPhotos,
      this.photoUploader = uploadPhotoAPI,
      this.draftStore,
      this.draftUserKey,
      this.slotsLoader = getRepairSlotsApi,
      super.key});
  static const String routeName = AppRoutes.repairForm;
  final HouseListLoader houseLoader;
  final RepairItemLoader itemLoader;
  final SubmitRepairLoader submitter;
  final UserInfoLoader userInfoLoader;
  final RepairPhotoPicker photoPicker;
  final UploadPhotoLoader photoUploader;
  final RepairDraftStore? draftStore;
  final String Function()? draftUserKey;
  final RepairSlotsLoader slotsLoader;
  @override
  State<RepairFormPage> createState() => _RepairFormPageState();
}

class _RepairFormPageState extends State<RepairFormPage>
    with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  final _mobile = TextEditingController();
  final _description = TextEditingController();
  List<String> _photos = <String>[];
  final List<PickedAvatar> _failedPhotos = <PickedAvatar>[];
  bool _uploading = false;
  List<House> _houses = const <House>[];
  List<RepairItem> _items = const <RepairItem>[];
  String? _houseId;
  String? _itemId;
  String _slot = '';
  bool _waitingSchedule = false;
  bool _urgentRequest = false;
  bool _asap = false;
  String? _scheduleWarning;
  bool _loading = false;
  bool _submitting = false;
  bool _waitingForConfirmation = false;
  bool _resultUnconfirmed = false;
  bool _optionsLoaded = false;
  bool _draftLoading = false;
  bool _formEdited = false;
  bool _restoringDraft = false;
  bool _draftLoaded = false;
  bool _draftRestored = false;
  bool _draftReadFailed = false;
  bool _draftSaveFailed = false;
  bool _identityLoading = false;
  String? _identityError;
  bool _submitted = false;
  RepairDraft? _lastOwnedDraft;
  Timer? _draftTimer;
  VoidCallback? _removeUserListener;
  Future<void>? _identityRequest;
  Future<void>? _draftRestoreRequest;
  late String _draftUserKey;
  late final int _formSessionId;
  RepairDraftStore get _draftStore => widget.draftStore ?? repairDraftStore;
  String? _error;
  @override
  void initState() {
    super.initState();
    _draftUserKey = _currentUserKey();
    _formSessionId = tokenManager.sessionId;
    if (widget.draftUserKey == null) {
      final UserInfoController users = Get.isRegistered<UserInfoController>()
          ? Get.find<UserInfoController>()
          : Get.put(UserInfoController(), permanent: true);
      _removeUserListener = users.addListener(_onUserInfoChanged);
    }
    WidgetsBinding.instance.addObserver(this);
    _mobile.addListener(_scheduleDraftSave);
    _description.addListener(_scheduleDraftSave);
    unawaited(_loadOptions());
    unawaited(_prepareDraft());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _removeUserListener?.call();
    _draftTimer?.cancel();
    // 快照在控制器销毁前读取；离开页面也保留尚未确认的提交。
    unawaited(_saveDraft());
    _mobile.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _slot.isNotEmpty) unawaited(_refreshSlot());
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _draftTimer?.cancel();
      unawaited(_saveDraft());
    }
  }

  String _currentUserKey() {
    final String Function()? resolver = widget.draftUserKey;
    if (resolver != null) return resolver().trim();
    if (tokenManager.getToken().isEmpty ||
        !Get.isRegistered<UserInfoController>()) {
      return '';
    }
    final UserInfoController controller = Get.find<UserInfoController>();
    return controller.currentUserSessionId == tokenManager.sessionId
        ? controller.currentUser.id.trim()
        : '';
  }

  bool get _sameOwner =>
      tokenManager.sessionId == _formSessionId &&
      (_draftUserKey.isEmpty || _currentUserKey() == _draftUserKey);

  Future<void> _ensureIdentity() {
    if (!mounted ||
        !_sameOwner ||
        widget.draftUserKey != null ||
        _currentUserKey().isNotEmpty ||
        tokenManager.getToken().isEmpty) {
      return Future<void>.value();
    }
    final Future<void>? pending = _identityRequest;
    if (pending != null) return pending;
    final Future<void> request = _loadIdentity();
    _identityRequest = request;
    return request.whenComplete(() {
      if (identical(_identityRequest, request)) _identityRequest = null;
    });
  }

  Future<void> _loadIdentity() async {
    setState(() {
      _identityLoading = true;
      _identityError = null;
    });
    try {
      // 冷启动直接进入报修时，“我的”尚未加载资料，需要本页主动补取。
      final info = await widget.userInfoLoader();
      if (!mounted || !_sameOwner || tokenManager.getToken().isEmpty) return;
      // 同会话的其他页面可能已经取得资料，不用迟到结果覆盖它。
      if (_currentUserKey().isNotEmpty) return;
      if (info.id.trim().isEmpty) {
        throw const FormatException('账号信息缺少用户 ID，请重试加载');
      }
      Get.find<UserInfoController>().updateUser(info);
    } on Object catch (error) {
      if (!mounted || !_sameOwner || _currentUserKey().isNotEmpty) return;
      setState(() =>
          _identityError = describeError(error, fallback: '无法获取账号信息，请稍后重试'));
    } finally {
      if (mounted) setState(() => _identityLoading = false);
    }
  }

  Future<void> _prepareDraft() async {
    await _ensureIdentity();
    if (!mounted || !_optionsLoaded || _loading) return;
    await _restoreDraft();
  }

  void _onUserInfoChanged() {
    // 用户资料也可能在其他组件构建时更新；不在其构建过程中更新本页。
    scheduleMicrotask(() {
      if (mounted && _optionsLoaded && !_loading) {
        unawaited(_restoreDraft());
      }
    });
  }

  RepairRecord _formRecord() => RepairRecord(
        houseId: _houseId ?? '',
        repairItemId: _itemId ?? '',
        mobile: _mobile.text.trim(),
        slot: _slot, urgentRequest: _urgentRequest, asap: _asap,
        description: _description.text.trim(),
        attachment: List<String>.of(_photos),
      );

  void _scheduleDraftSave() {
    if (_restoringDraft || !_sameOwner) return;
    _formEdited = true;
    if (!_draftLoaded || _submitted) return;
    _lastOwnedDraft = RepairDraft(
      record: _formRecord(),
      waitingSchedule: _waitingSchedule,
      resultUnconfirmed: _resultUnconfirmed,
    );
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_saveDraft());
    });
  }

  Future<void> _saveDraft() async {
    if (!_draftLoaded || _submitted || _draftUserKey.isEmpty) return;
    final RepairRecord? record =
        _sameOwner ? _formRecord() : _lastOwnedDraft?.record;
    if (record == null) return;
    final RepairDraft draft = RepairDraft(
      record: record,
      waitingSchedule: _sameOwner ? _waitingSchedule : _lastOwnedDraft?.waitingSchedule,
      resultUnconfirmed: _resultUnconfirmed,
    );
    _lastOwnedDraft = draft;
    try {
      final bool saved = await _draftStore.save(_draftUserKey, draft);
      if (mounted && _sameOwner) setState(() => _draftSaveFailed = !saved);
    } on Object {
      if (mounted && _sameOwner) setState(() => _draftSaveFailed = true);
    }
  }

  Future<void> _restoreDraft() {
    final Future<void>? pending = _draftRestoreRequest;
    if (pending != null) return pending;
    if (!mounted || _draftLoaded || _submitted || !_sameOwner) {
      return Future<void>.value();
    }
    // 未知身份时不登记一个已完成的恢复任务，避免它挡住稍后到达资料的恢复。
    if (_draftUserKey.isEmpty) _draftUserKey = _currentUserKey();
    if (_draftUserKey.isEmpty) return Future<void>.value();
    final Future<void> request = _readDraft();
    _draftRestoreRequest = request;
    return request.whenComplete(() {
      if (identical(_draftRestoreRequest, request)) {
        _draftRestoreRequest = null;
      }
    });
  }

  Future<void> _readDraft() async {
    setState(() => _draftLoading = true);
    try {
      final RepairDraft? draft = await _draftStore.load(_draftUserKey);
      if (!mounted || !_sameOwner) return;
      RepairSlot? migrated;
      String? migrationError;
      final bool legacy = draft != null && draft.record.slot.isEmpty && draft.record.expectedTime.isNotEmpty;
      if (legacy && !_formEdited) {
        try {
          migrated = await matchDraftSlot(draft.record.expectedTime, widget.slotsLoader);
        } on Object catch (error) {
          migrationError = describeError(error, fallback: '旧草稿时段查询失败，请重新选择');
        }
        if (!mounted || !_sameOwner) return;
      }
      setState(() {
        if (draft != null) {
          // 即使已有新输入，也不能丢掉旧草稿的未确认提交记录。
          _resultUnconfirmed = _resultUnconfirmed || draft.resultUnconfirmed;
          if (!_formEdited) {
            _restoringDraft = true;
            try {
              _houseId =
                  _houses.any((house) => house.id == draft.record.houseId)
                      ? draft.record.houseId
                      : null;
              _itemId =
                  _items.any((item) => item.id == draft.record.repairItemId)
                      ? draft.record.repairItemId
                      : null;
              _mobile.text = draft.record.mobile;
              _description.text = draft.record.description;
              _photos = List<String>.of(draft.record.attachment.take(8));
              _slot = legacy ? migrated?.slot ?? '' : draft.record.slot;
              _urgentRequest = draft.record.urgentRequest;
              _asap = _urgentRequest && draft.record.asap;
              if (_asap) _slot = '';
              _waitingSchedule = _slot.isEmpty && ((draft.waitingSchedule ?? false) || _asap);
              if ((legacy && migrated == null) || draft.record.appointment.isNotEmpty) {
                _scheduleWarning = migrationError ?? '旧草稿时间无法对应可预约时段，请重新选择或提交待安排';
              }
              _draftRestored = true;
            } finally {
              _restoringDraft = false;
            }
          }
        }
        _draftLoaded = true;
        _draftReadFailed = false;
        _lastOwnedDraft = RepairDraft(
          record: _formRecord(),
          waitingSchedule: _waitingSchedule,
          resultUnconfirmed: _resultUnconfirmed,
        );
      });
      if (!_formEdited && _slot.isNotEmpty) await _refreshSlot();
      if (_formEdited) await _saveDraft();
    } on Object {
      // 未能读取时不覆盖磁盘草稿，也不允许跳过可能存在的二次确认。
      if (mounted && _sameOwner) setState(() => _draftReadFailed = true);
    } finally {
      if (mounted) setState(() => _draftLoading = false);
    }
  }

  Future<void> _loadOptions() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final values = await Future.wait(
          <Future<Object>>[widget.houseLoader(), widget.itemLoader()]);
      if (!mounted) return;
      if (!_sameOwner) throw const SessionChangedException();
      setState(() {
        _houses = values[0] as List<House>;
        _items = values[1] as List<RepairItem>;
        _optionsLoaded = true;
      });
      await _restoreDraft();
    } on Object catch (error) {
      final msg = describeError(error, fallback: '加载报修选项失败，请重试');
      if (mounted) {
        setState(() => _error = msg);
        await PromptAction.showError(msg);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
      // 覆盖资料恰好在上面的 await 与 finally 之间到达的情况。
      if (mounted && !_draftReadFailed) _onUserInfoChanged();
    }
  }

  Future<void> _refreshSlot() async {
    final String selected = _slot;
    if (selected.isEmpty) return;
    try {
      final RepairSlots data = await widget.slotsLoader(date: selected.split('#').first);
      if (!mounted || !_sameOwner || selected != _slot) return;
      final bool valid = data.slots.any((RepairSlot item) => item.slot == selected && item.selectable);
      setState(() {
        _scheduleWarning = valid ? null : '原时段已不可选，请重新选择或提交待安排';
        if (!valid) { _slot = ''; _waitingSchedule = false; }
      });
    } on Object catch (error) {
      if (mounted && _sameOwner && selected == _slot) setState(() => _scheduleWarning = describeError(error, fallback: '时段查询失败，请重试'));
    }
  }

  Future<void> _pickDate() async {
    final RepairSlot? selected =
        await pickVisitTime(context, initialSlot: _slot, title: '选择期望上门日期', loader: widget.slotsLoader);
    if (selected != null && mounted && _sameOwner) {
      setState(() { _slot = selected.slot; _waitingSchedule = false; _asap = false; _scheduleWarning = null; });
      _scheduleDraftSave();
    }
  }

  Future<void> _addPhotos() async {
    if (_uploading ||
        _submitting ||
        !_sameOwner ||
        _photos.length + _failedPhotos.length >= 8) {
      return;
    }
    setState(() => _uploading = true);
    try {
      final remaining = 8 - _photos.length - _failedPhotos.length;
      List<PickedAvatar> files;
      if (supportsAvatarCamera) {
        final source = await showModalBottomSheet<AvatarSource>(
            context: context,
            builder: (sheet) => SafeArea(
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                      ListTile(
                          leading: const Icon(Icons.photo_library_outlined),
                          title: const Text('从相册选择'),
                          onTap: () =>
                              Navigator.pop(sheet, AvatarSource.gallery)),
                      ListTile(
                          leading: const Icon(Icons.camera_alt_outlined),
                          title: const Text('拍照'),
                          onTap: () =>
                              Navigator.pop(sheet, AvatarSource.camera)),
                    ])));
        if (!mounted || !_sameOwner || source == null) return;
        if (source == AvatarSource.camera) {
          final file = await pickAvatar(source);
          files = file == null ? <PickedAvatar>[] : <PickedAvatar>[file];
        } else {
          files = await widget.photoPicker(remaining);
        }
      } else {
        files = await widget.photoPicker(remaining);
      }
      if (!mounted || !_sameOwner) return;
      if (files.length > remaining) throw FormatException('还能添加$remaining张照片');
      await _uploadFiles(files);
    } on Object catch (error) {
      if (mounted && _sameOwner) {
        await PromptAction.showError(
            describeError(error, fallback: '添加照片失败，请重试'));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _uploadFiles(List<PickedAvatar> files) async {
    for (final file in files) {
      if (!mounted || !_sameOwner) return;
      try {
        final url = await widget.photoUploader(
            fileBytes: file.bytes, fileName: file.fileName);
        if (!mounted || !_sameOwner) return;
        setState(() => _photos.add(url));
        _scheduleDraftSave();
      } on Object {
        if (!mounted || !_sameOwner) return;
        setState(() => _failedPhotos.add(file));
      }
    }
  }

  Future<void> _retryPhotos() async {
    if (_uploading || !_sameOwner) return;
    final files = List<PickedAvatar>.of(_failedPhotos);
    setState(() {
      _failedPhotos.clear();
      _uploading = true;
    });
    try {
      await _uploadFiles(files);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _submit() async {
    if (_submitting || _submitted || _uploading) return;
    if (_failedPhotos.isNotEmpty) {
      await PromptAction.showWarning('请重试或移除上传失败的照片');
      return;
    }
    if (!_sameOwner) {
      await PromptAction.showWarning('登录账号已变化，请返回后重新打开报修页面');
      return;
    }
    if (!_draftLoaded) {
      await _ensureIdentity();
      if (!mounted) return;
      await _restoreDraft();
      if (!mounted) return;
      if (!_sameOwner) {
        await PromptAction.showWarning('登录账号已变化，请返回后重新打开报修页面');
        return;
      }
      if (!_draftLoaded) {
        await PromptAction.showWarning(_draftUserKey.isEmpty
            ? _identityError ?? '账号信息尚未就绪，请保留当前页面，稍后再提交'
            : _draftReadFailed
                ? '本机草稿读取失败，请保留当前页面并重试'
                : '草稿尚未读取完成，请保留当前页面，稍后再提交');
        return;
      }
      // 读取草稿期间其他点击可能已经开始提交。
      if (_submitting || _submitted) return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_slot.isEmpty && !_waitingSchedule) {
      await PromptAction.showWarning('请选择上门时段或提交后等待安排');
      return;
    }
    if (_slot.isNotEmpty && _scheduleWarning != null) {
      await PromptAction.showWarning('请重新查询并选择上门时段');
      return;
    }
    setState(() => _submitting = true);
    final bool wasUnconfirmed = _resultUnconfirmed;
    bool requestSent = false;
    try {
      if (wasUnconfirmed) {
        setState(() => _waitingForConfirmation = true);
        final bool confirmed = await showDialog<bool>(
              context: context,
              builder: (BuildContext context) => AlertDialog(
                title: const Text('上次提交结果未确认'),
                content: const Text('服务器可能已经创建报修记录。建议先查看“我的报修”；再次提交可能产生重复记录。'),
                actions: <Widget>[
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('先不提交')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('仍然提交')),
                ],
              ),
            ) ??
            false;
        if (!mounted || !confirmed) return;
        setState(() => _waitingForConfirmation = false);
      }
      if (!_sameOwner) throw const SessionChangedException();
      _draftTimer?.cancel();
      _resultUnconfirmed = true;
      await _saveDraft();
      if (!mounted) return;
      if (!_sameOwner) throw const SessionChangedException();
      requestSent = true;
      final Object? created = await widget.submitter(_formRecord()) as Object?;
      if (!mounted) return;
      if (!_sameOwner) throw const SessionChangedException();
      _submitted = true;
      if (_draftUserKey.isNotEmpty) {
        try {
          final bool removed = await _draftStore.remove(_draftUserKey);
          if (!mounted) return;
          if (!removed) {
            await PromptAction.showWarning('报修已提交，但本机草稿清理失败，请勿重复提交');
          }
        } on Object {
          if (!mounted) return;
          await PromptAction.showWarning('报修已提交，但本机草稿清理失败，请勿重复提交');
        }
      }
      if (!mounted || !_sameOwner) return;
      await PromptAction.showSuccess('报修提交成功');
      if (!mounted || !_sameOwner) return;
      // 提交成功后直接进入新工单详情；拿不到编号时（旧服务端或测试替身）回到列表。
      final String createdId = created is String ? created.trim() : '';
      if (createdId.isNotEmpty) {
        await Navigator.pushReplacementNamed(context, RepairDetailPage.routeName,
            arguments: createdId, result: true);
      } else {
        Navigator.pop(context, true);
      }
    } on Object catch (error) {
      if (!mounted) return;
      final bool uncertain = requestSent &&
          error is NetworkException &&
          (error.isTimeout ||
              error is SessionChangedException ||
              const <int?>{null, 408}.contains(error.statusCode) ||
              (error.statusCode != null && error.statusCode! >= 500));
      setState(() => _resultUnconfirmed = wasUnconfirmed || uncertain);
      await _saveDraft();
      if (!mounted) return;
      if (uncertain) {
        await PromptAction.showWarning(error is SessionChangedException
            ? '${error.message}；提交结果请先查看“我的报修”'
            : '提交结果未确认，服务器可能已收到，请先查看“我的报修”，避免重复提交');
      } else if (error is NetworkException && error.statusCode == 409) {
        await PromptAction.showWarning('${error.message}，已刷新最新状态');
        if (!mounted || !_sameOwner) return;
        await _refreshSlot();
      } else {
        await PromptAction.showError(
            describeError(error, fallback: '报修提交失败，请重试'));
      }
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
          _waitingForConfirmation = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('新增报修')),
      body: AsyncStateView(
          isLoading: _loading,
          errorMessage: _error,
          onRetry: _loadOptions,
          hasContent: _houses.isNotEmpty && _items.isNotEmpty,
          builder: (_) => AbsorbPointer(
              absorbing: _submitting || _submitted,
              child: Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            if (_draftUserKey.isEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    const Text(
                                        '账号信息尚未就绪，草稿暂未保存；请保留当前页面，待账号信息加载后再提交'),
                                    if (_identityError != null)
                                      Text(_identityError!),
                                    if (widget.draftUserKey == null)
                                      TextButton(
                                        onPressed: _identityLoading
                                            ? null
                                            : _prepareDraft,
                                        child: Text(_identityLoading
                                            ? '正在加载账号信息…'
                                            : '重试加载账号信息'),
                                      ),
                                  ],
                                ),
                              ),
                            if (_draftLoading)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 12),
                                child: Text('正在读取当前账号的草稿，请稍后提交'),
                              ),
                            if (_resultUnconfirmed && !_submitting)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 16),
                                child: Text('提交结果未确认：请先查看“我的报修”。再次提交可能产生重复记录。',
                                    style: TextStyle(color: AppColors.danger)),
                              ),
                            if (_draftRestored)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 12),
                                child: Text('已恢复之前未完成的内容'),
                              ),
                            if (_draftSaveFailed)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 12),
                                child: Text('本机草稿保存不可用，请保留当前页面的填写内容'),
                              ),
                            if (_draftReadFailed)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 12),
                                child: Text('本机草稿读取失败，请保留当前页面，点击提交可重试'),
                              ),
                            DropdownButtonFormField<String>(
                                key: ValueKey('house:$_draftRestored'),
                                initialValue: _houseId,
                                decoration:
                                    const InputDecoration(labelText: '报修房屋'),
                                validator: (v) => v == null ? '请选择报修房屋' : null,
                                items: _houses
                                    .map((house) => DropdownMenuItem(
                                        value: house.id,
                                        child: Text(house.fullName)))
                                    .toList(),
                                onChanged: (value) {
                                  setState(() => _houseId = value);
                                  _scheduleDraftSave();
                                }),
                            const SizedBox(height: 14),
                            DropdownButtonFormField<String>(
                                key: ValueKey('item:$_draftRestored'),
                                initialValue: _itemId,
                                decoration:
                                    const InputDecoration(labelText: '维修项目'),
                                validator: (v) => v == null ? '请选择维修项目' : null,
                                items: _items
                                    .map((item) => DropdownMenuItem(
                                        value: item.id, child: Text(item.name)))
                                    .toList(),
                                onChanged: (value) {
                                  setState(() => _itemId = value);
                                  _scheduleDraftSave();
                                }),
                            const SizedBox(height: 14),
                            TextFormField(
                                controller: _mobile,
                                keyboardType: TextInputType.phone,
                                decoration:
                                    const InputDecoration(labelText: '联系电话'),
                                validator: Validators.required('请输入联系电话')
                                    .chain(Validators.mobile())
                                    .validate),
                            const SizedBox(height: 14),
                            CheckboxListTile(value: _waitingSchedule, contentPadding: EdgeInsets.zero,
                              title: const Text('提交后等待安排'), onChanged: (bool? value) {
                                setState(() { _waitingSchedule = value ?? false; if (_waitingSchedule) { _slot = ''; } else { _asap = false; } _scheduleWarning = null; });
                                _scheduleDraftSave();
                              }),
                            CheckboxListTile(value: _urgentRequest, contentPadding: EdgeInsets.zero,
                              title: const Text('紧急诉求'), onChanged: (bool? value) {
                                setState(() { _urgentRequest = value ?? false; if (!_urgentRequest) _asap = false; }); _scheduleDraftSave();
                              }),
                            if (_urgentRequest) CheckboxListTile(value: _asap, contentPadding: EdgeInsets.zero,
                              title: const Text('尽快上门'), onChanged: (bool? value) {
                                setState(() { _asap = value ?? false; if (_asap) { _slot = ''; _waitingSchedule = true; _scheduleWarning = null; } }); _scheduleDraftSave();
                              }),
                            if (_scheduleWarning != null) Text(_scheduleWarning!),
                            ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(_slot.isEmpty ? '请选择期望上门时间' : formatSlotWindow(slot: _slot)),
                                subtitle: const Text('以服务端可选时段为准；选时段后取消尽快上门'),
                                trailing:
                                    const Icon(Icons.calendar_today_outlined),
                                onTap: _pickDate),
                            TextFormField(
                                controller: _description,
                                decoration: const InputDecoration(
                                    labelText: '故障描述（选填）'),
                                maxLines: 4),
                            const SizedBox(height: 20),
                            RepairPhotos(
                                urls: _photos,
                                editable: true,
                                uploading: _uploading,
                                selectedCount:
                                    _photos.length + _failedPhotos.length,
                                onAdd: _addPhotos,
                                onRemove: (index) {
                                  setState(() => _photos.removeAt(index));
                                  _scheduleDraftSave();
                                }),
                            if (_failedPhotos.isNotEmpty) ...<Widget>[
                              Text(
                                  '${_failedPhotos.length}张照片上传失败，离开页面前请重试或移除'),
                              Wrap(spacing: 12, children: <Widget>[
                                TextButton(
                                    onPressed: _uploading ? null : _retryPhotos,
                                    child: const Text('重试上传')),
                                TextButton(
                                    onPressed: _uploading
                                        ? null
                                        : () => setState(_failedPhotos.clear),
                                    child: const Text('移除失败照片')),
                              ]),
                            ],
                            const SizedBox(height: 28),
                            FilledButton(
                                onPressed:
                                    _submitting || _submitted || _uploading
                                        ? null
                                        : _submit,
                                child: _submitting && !_waitingForConfirmation
                                    ? const CircularProgressIndicator()
                                    : const Text('提交报修'))
                          ]))))));
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(text,
          style: const TextStyle(
              fontWeight: FontWeight.w600, color: AppColors.textSecondary)));
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      child: Row(children: <Widget>[
        SizedBox(
            width: 82,
            child: Text(label,
                style: const TextStyle(color: AppColors.textTertiary))),
        Expanded(child: Text(value.isEmpty ? '暂无' : value))
      ]));
}
