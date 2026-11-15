import 'dart:async';

import 'package:flutter/material.dart';
import '../../api/repair.dart';
import '../../models/repair.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/date_utils.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';
import '../../widgets/async_state_view.dart';
import '../../widgets/notification_actions.dart';
import '../../widgets/repair_dialogs.dart';
import '../../widgets/repair_photos.dart';
import '../../widgets/repair_progress.dart';
import '../../widgets/repair_schedule_card.dart';
import '../../widgets/repair_slot_picker.dart';

class RepairDetailPage extends StatefulWidget {
  const RepairDetailPage({
    this.loadRepairDetail = getRepairDetailApi,
    this.cancelRepair = cancelRepairApi,
    // 保存函数供提交时调用，这里没有括号，不会立刻执行。
    this.submitAction = submitRepairActionApi,
    this.loadAvailableSlots = getRepairSlotsApi,
    this.loadReplacementSlots = getUnstaffedSlotsApi,
    this.submitReplacementChoice = chooseUnstaffedSlotApi,
    super.key,
  });
  static const String routeName = repairDetail;

  /// 根据工单编号读取详情。
  final RepairDetailLoader loadRepairDetail;

  /// 未接单时，直接取消报修。
  final RepairCancellationSubmitter cancelRepair;

  /// 提交工单操作时要调用的函数。
  /// 默认请求服务器；测试可用 submitAction: 模拟函数 替换它。
  final RepairActionSubmitter submitAction;

  /// 普通改约时，读取可选上门时段。
  final RepairSlotsLoader loadAvailableSlots;

  /// 人手不足、需要重新选时间时，读取可选时段。
  final RepairSlotsLoader loadReplacementSlots;

  /// 提交新时间，或提交“保持原时间，继续等”的选择。
  final ReplacementScheduleSubmitter submitReplacementChoice;
  @override
  State<RepairDetailPage> createState() => _RepairDetailPageState();
}

class _RepairDetailPageState extends State<RepairDetailPage>
    with WidgetsBindingObserver {
  // 人手不足时，覆盖选择新时间或继续等待的整个操作，包含弹窗。
  bool _isChoosingReplacementSchedule = false;
  RepairRecord? _detailReadDuringReplacementChoice;
  int _repairMutationEpoch = 0;
  late final int _ownerSession;
  String _proposalReason = '';
  String? _proposalSlot;
  String _responseReason = '';
  @override
  void initState() {
    super.initState();
    _ownerSession = tokenManager.sessionId;
    WidgetsBinding.instance.addObserver(this);
    tokenManager.sessionChanges.addListener(_onSessionChanged);
  }

  void _onSessionChanged() {
    if (!mounted || tokenManager.sessionId == _ownerSession) return;
    setState(() {
      _repair = null;
      _isLoadingDetail = false;
      _error = '登录账号已变化，请返回报修列表重新进入';
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    tokenManager.sessionChanges.removeListener(_onSessionChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_cancellationNeedsRefresh) {
      unawaited(_loadRepairDetail());
    }
  }

  String _repairId = '';
  RepairRecord? _repair;
  String? _error;
  // 读取详情、显示撤销确认框和提交操作分别计状态，避免把它们混为一次加载。
  bool _isLoadingDetail = false;
  bool _isCancellingRepair = false;
  bool _isConfirmingCancellation = false;
  bool _cancellationNeedsRefresh = false;
  bool _isConfirmingCompletion = false;
  bool _isSubmittingAction = false;
  // 操作成功后返回列表时，通知列表重新读取工单。
  bool _hasRepairChanges = false;

  Future<void> _chooseReplacementSchedule({bool keep = false}) async {
    final RepairRecord? record = _repair;
    if (_isChoosingReplacementSchedule ||
        _isCancellingRepair ||
        _isConfirmingCancellation ||
        _cancellationNeedsRefresh ||
        record == null ||
        tokenManager.sessionId != _ownerSession) {
      return;
    }
    final RepairRecord snapshot = record;
    _repairMutationEpoch++;
    _detailReadDuringReplacementChoice = null;
    setState(() => _isChoosingReplacementSchedule = true);
    try {
      Future<void> submitSelectedSchedule({RepairSlot? slot}) async {
        if (!mounted || tokenManager.sessionId != _ownerSession) return;
        final RepairRecord? current = _repair;
        final RepairRecord? loadedDuringChoice =
            _detailReadDuringReplacementChoice;
        if (current == null ||
            current.id != snapshot.id ||
            current.revision != snapshot.revision ||
            (loadedDuringChoice != null &&
                (loadedDuringChoice.id != snapshot.id ||
                    loadedDuringChoice.revision != snapshot.revision))) {
          if (mounted && tokenManager.sessionId == _ownerSession) {
            setState(() => _isChoosingReplacementSchedule = false);
            await AppPrompt.showWarning('工单状态已更新，请重新核对后再确认');
            if (mounted && tokenManager.sessionId == _ownerSession) {
              await _loadRepairDetail();
            }
          }
          return;
        }
        if (snapshot.rescheduleOffer == null ||
            !snapshot.rescheduleOffer!.isOpen ||
            (loadedDuringChoice != null &&
                (loadedDuringChoice.rescheduleOffer == null ||
                    !loadedDuringChoice.rescheduleOffer!.isOpen))) {
          setState(() => _isChoosingReplacementSchedule = false);
          await AppPrompt.showWarning('改约提议已关闭，请刷新工单状态');
          if (mounted && tokenManager.sessionId == _ownerSession) {
            await _loadRepairDetail();
          }
          return;
        }
        late final RepairRecord updated;
        try {
          updated = await widget.submitReplacementChoice(snapshot,
              slot: slot?.slot, keep: keep);
        } on Object catch (error) {
          if (error is NetworkException &&
              error.statusCode == 409 &&
              mounted &&
              tokenManager.sessionId == _ownerSession) {
            setState(() => _isChoosingReplacementSchedule = false);
            await _loadRepairDetail();
          }
          rethrow;
        }
        if (!mounted || tokenManager.sessionId != _ownerSession) return;
        setState(() {
          _repair = updated;
          _hasRepairChanges = true;
        });
        await AppPrompt.showSuccess(keep ? '已保持原时间，物业会联系您' : '上门时间已更新');
      }

      if (keep) {
        await submitSelectedSchedule();
      } else {
        await pickRepairSlot(context,
            initialSlot: record.slot,
            excludeId: record.id,
            title: '选择新的上门时间',
            loader: widget.loadReplacementSlots,
            onConfirm: (RepairSlot slot) => submitSelectedSchedule(slot: slot));
      }
    } on Object catch (error) {
      if (!mounted || tokenManager.sessionId != _ownerSession) return;
      await AppPrompt.showException(error, fallback: '操作失败，请重试');
    } finally {
      _detailReadDuringReplacementChoice = null;
      if (mounted) setState(() => _isChoosingReplacementSchedule = false);
    }
  }

  /// 执行提交函数，成功后用返回的工单更新页面。
  /// 防重复提交并检查页面、账号是否仍有效；版本冲突时只刷新，不重复执行旧操作。
  Future<void> _submitRepairAction(
    RepairAction action, {
    required String successMessage,
    required String failureMessage,
    RepairRecord? snapshot,
  }) async {
    final RepairRecord? currentRepair = _repair;
    if (_isSubmittingAction ||
        _isCancellingRepair ||
        (_isConfirmingCancellation && action is! RevokeAction) ||
        _cancellationNeedsRefresh ||
        currentRepair == null ||
        tokenManager.sessionId != _ownerSession) {
      return;
    }
    if (snapshot != null &&
        (_isLoadingDetail ||
            currentRepair.id != snapshot.id ||
            currentRepair.revision != snapshot.revision)) {
      await AppPrompt.showWarning('工单状态已更新，请重新核对后再确认');
      if (mounted && tokenManager.sessionId == _ownerSession) {
        await _loadRepairDetail();
      }
      return;
    }
    final int sessionId = tokenManager.sessionId;
    _repairMutationEpoch++;
    setState(() => _isSubmittingAction = true);
    try {
      // 调用创建页面时传入的提交函数，等待它返回更新后的工单。
      final RepairRecord updatedRepair =
          await widget.submitAction(snapshot ?? currentRepair, action);
      if (!mounted || tokenManager.sessionId != sessionId) {
        return;
      }

      // 只有提交成功，才把返回的工单显示到页面。
      _hasRepairChanges = true;
      setState(() => _repair = updatedRepair);
      await AppPrompt.showSuccess(successMessage);
    } on Object catch (error) {
      if (!mounted || tokenManager.sessionId != sessionId) {
        return;
      }
      if (action is RevokeAction) {
        setState(() => _cancellationNeedsRefresh = true);
        await AppPrompt.showException(error, fallback: failureMessage);
        return;
      }
      if (error is NetworkException && error.statusCode == 409) {
        // 工单已被其他操作更新：读取最新详情，交给用户重新决定。
        await AppPrompt.showWarning('${error.message}，已刷新最新状态');
        if (!mounted) {
          return;
        }
        setState(() => _isSubmittingAction = false);
        await _loadRepairDetail();
        return;
      }
      await AppPrompt.showException(error, fallback: failureMessage);
    } finally {
      // 成功或失败都会执行，让用户能够继续操作。
      if (mounted) {
        setState(() => _isSubmittingAction = false);
      }
    }
  }

  Future<void> _confirmRepair() async {
    final RepairRecord? snapshot = _repair;
    if (_isConfirmingCompletion ||
        _isCancellingRepair ||
        _isConfirmingCancellation ||
        _cancellationNeedsRefresh ||
        _isSubmittingAction ||
        _isLoadingDetail ||
        snapshot == null ||
        !snapshot.canConfirm ||
        tokenManager.sessionId != _ownerSession) {
      return;
    }
    setState(() => _isConfirmingCompletion = true);
    try {
      final bool? isConfirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('确认已修好'),
          content: const Text('确认后进入售后期，售后期内如有问题仍可申请返修。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认修好'),
            ),
          ],
        ),
      );

      // 返回或直接关闭弹窗都不提交，只有点击“确认修好”才继续。
      if (isConfirmed != true ||
          !mounted ||
          tokenManager.sessionId != _ownerSession) {
        return;
      }
      if (_isLoadingDetail ||
          _repair?.id != snapshot.id ||
          _repair?.revision != snapshot.revision ||
          !(_repair?.canConfirm ?? false)) {
        await AppPrompt.showWarning('工单状态已更新，请重新核对后再确认');
        return;
      }
      await _submitRepairAction(
        const ConfirmAction(),
        successMessage: '已确认修好',
        failureMessage: '确认失败，请重试',
      );
    } finally {
      if (mounted) setState(() => _isConfirmingCompletion = false);
    }
  }

  Future<void> _rejectRepair() async {
    final RepairRecord? snapshot = _repair;
    if (snapshot == null) return;
    final String? reason = await askReason(context,
        title: '还没修好',
        label: '哪里还有问题',
        message: '开启新一轮维修，由专业师傅重新排查原因并调整方案，再约定上门时间；需要时由物业协调人员。',
        confirmText: '交回返修');
    if (reason != null && mounted) {
      await _submitRepairAction(
        RejectAction(reason),
        snapshot: snapshot,
        successMessage: '已交回师傅返修',
        failureMessage: '提交失败，请重试',
      );
    }
  }

  Future<void> _applyForAftersale() async {
    final RepairRecord? snapshot = _repair;
    if (snapshot == null) return;
    final String? reason = await askReason(context,
        title: '申请售后返修',
        label: '遇到了什么问题',
        message: '物业审核通过后开启新一轮维修，由专业师傅重新排查并调整方案。',
        confirmText: '提交申请');
    if (reason != null && mounted) {
      await _submitRepairAction(
        AftersaleAction(reason),
        snapshot: snapshot,
        successMessage: '售后申请已提交，等待物业审核',
        failureMessage: '提交失败，请重试',
      );
    }
  }

  Future<void> _submitFeedback() async {
    final RepairRecord? snapshot = _repair;
    if (snapshot == null) return;
    final String? content = await askReason(context,
        title: '反馈问题',
        label: '问题说明',
        message: '物业会核实处理并在时间线中回复。',
        confirmText: '提交反馈');
    if (content != null && mounted) {
      await _submitRepairAction(
        FeedbackAction(content),
        snapshot: snapshot,
        successMessage: '反馈已提交',
        failureMessage: '提交失败，请重试',
      );
    }
  }

  Future<void> _requestRevocation() async {
    final RepairRecord? record = _repair;
    if (record == null) return;
    final bool needsWorker = record.revokeNeedsWorker;
    setState(() => _isConfirmingCancellation = true);
    try {
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
      if (reason == null ||
          !mounted ||
          tokenManager.sessionId != _ownerSession) {
        return;
      }
      if (_isLoadingDetail ||
          _repair?.id != record.id ||
          _repair?.revision != record.revision ||
          _repair?.revokeNeedsWorker != needsWorker ||
          !(_repair?.canRevoke ?? false)) {
        await AppPrompt.showWarning('工单状态已更新，请重新核对后再确认');
        return;
      }
      await _submitRepairAction(
        RevokeAction(reason, notified: needsWorker),
        successMessage: needsWorker ? '撤销申请已提交' : '报修已撤销',
        failureMessage: '撤销失败，请重试',
      );
    } finally {
      if (mounted) setState(() => _isConfirmingCancellation = false);
    }
  }

  Future<void> _proposeReschedule() async {
    final RepairRecord? record = _repair;
    if (record == null) return;
    final RepairSlot? time = await pickVisitTime(context,
        initialSlot: _proposalSlot ?? record.slot,
        excludeId: record.id,
        loader: widget.loadAvailableSlots,
        title: '选择新的上门时间');
    if (time == null || !mounted) return;
    _proposalSlot = time.slot;
    final String? reason = await askReason(context,
        title: '修改预约',
        label: '改约原因',
        initialText: _proposalReason,
        message:
            '新时间：${formatSlotWindow(slot: time.slot, start: time.start, end: time.end)}\n'
            '请先电话告知师傅。师傅同意后新时间才生效，之前按原约定。',
        phone: record.workerMobile,
        notifyHint: '我已电话告知师傅',
        confirmText: '发起改约');
    if (reason != null && mounted) {
      _proposalReason = reason;
      await _submitRepairAction(
        ProposeAction(time.slot, reason),
        snapshot: record,
        successMessage: '改约已发起，等待师傅同意',
        failureMessage: '改约失败，请重试',
      );
    }
  }

  Future<void> _respondToSchedule({required bool accept}) async {
    final RepairRecord? snapshot = _repair;
    if (snapshot == null) return;
    final bool isFirstSchedule = snapshot.firstSchedule != null;
    String reason = '';
    if (!accept) {
      final String? enteredReason = await askReason(context,
          title: isFirstSchedule ? '拒绝首次上门时间' : '不同意改约',
          label: '原因',
          initialText: _responseReason,
          message: isFirstSchedule
              ? '拒绝后等待师傅或物业重新提议，请填写原因。'
              : '将保持原约定时间，建议电话与师傅再沟通。',
          confirmText: isFirstSchedule ? '确认拒绝' : '保持原约定');
      if (enteredReason == null || !mounted) return;
      reason = enteredReason;
      _responseReason = reason;
    }

    final String successMessage;
    if (accept) {
      successMessage = '已同意新时间';
    } else if (isFirstSchedule) {
      successMessage = '已拒绝，等待重新安排';
    } else {
      successMessage = '已保持原约定';
    }
    await _submitRepairAction(
      RespondAction(accept: accept, reason: reason),
      snapshot: snapshot,
      successMessage: successMessage,
      failureMessage: '操作失败，请重试',
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_repairId.isEmpty) {
      _repairId =
          ModalRoute.of(context)?.settings.arguments?.toString().trim() ?? '';
      if (_repairId.isEmpty) {
        _error = '报修参数不正确';
      } else {
        unawaited(_loadRepairDetail());
      }
    }
  }

  Future<void> _loadRepairDetail() async {
    // 提交期间不并发读取旧快照，避免迟到刷新覆盖操作成功后的状态。
    if (_isLoadingDetail ||
        _isSubmittingAction ||
        _isCancellingRepair ||
        _isChoosingReplacementSchedule ||
        _repairId.isEmpty ||
        tokenManager.sessionId != _ownerSession) {
      return;
    }
    final int session = tokenManager.sessionId;
    final int mutationEpoch = _repairMutationEpoch;
    setState(() {
      _isLoadingDetail = true;
      _error = null;
    });
    try {
      final RepairRecord loadedRepair =
          await widget.loadRepairDetail(_repairId);
      if (loadedRepair.id != _repairId) {
        throw const FormatException('工单详情不匹配，请重新加载');
      }
      if (mounted &&
          session == tokenManager.sessionId &&
          mutationEpoch == _repairMutationEpoch &&
          !_isChoosingReplacementSchedule &&
          !_isSubmittingAction) {
        setState(() {
          _repair = loadedRepair;
          if (_cancellationNeedsRefresh) _hasRepairChanges = true;
          _cancellationNeedsRefresh = false;
        });
      } else if (mounted &&
          session == tokenManager.sessionId &&
          _isChoosingReplacementSchedule &&
          !_isSubmittingAction) {
        // 不把读到的新详情渲染到操作页面，但保留它用于确认前的版本比较。
        _detailReadDuringReplacementChoice = loadedRepair;
      }
    } on Object catch (error) {
      final String errorMessage =
          describeError(error, fallback: '获取报修详情失败，请重试');
      if (mounted &&
          session == tokenManager.sessionId &&
          mutationEpoch == _repairMutationEpoch &&
          !_isChoosingReplacementSchedule &&
          !_isSubmittingAction) {
        setState(() {
          _error = errorMessage;
          if (error is NetworkException && error.statusCode == 404) {
            _repair = null;
            _hasRepairChanges = true;
          }
        });
        await AppPrompt.showError(errorMessage);
      }
    } finally {
      if (mounted) setState(() => _isLoadingDetail = false);
    }
  }

  /// 未接单前的直接撤销沿用原有流程；师傅接单后走 [_requestRevocation] 的撤销申请。
  Future<void> _cancelRepair() async {
    final RepairRecord? record = _repair;
    if (_isCancellingRepair ||
        _isConfirmingCancellation ||
        _isConfirmingCompletion ||
        _isLoadingDetail ||
        _isSubmittingAction ||
        _isChoosingReplacementSchedule ||
        _cancellationNeedsRefresh ||
        record == null ||
        !record.canRevoke ||
        _repairId.isEmpty ||
        tokenManager.sessionId != _ownerSession) {
      return;
    }
    if (record.revokeNeedsWorker) return _requestRevocation();
    // 确认框打开期间也阻止重复点击，避免叠加多个撤销确认框。
    setState(() => _isConfirmingCancellation = true);
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
      if (!confirmed || !mounted || tokenManager.sessionId != _ownerSession) {
        return;
      }
      if (_isLoadingDetail ||
          _repair?.id != record.id ||
          _repair?.revision != record.revision ||
          !(_repair?.canCancel ?? false)) {
        await AppPrompt.showWarning('工单状态已更新，请重新核对后再确认');
        return;
      }
      setState(() => _isCancellingRepair = true);
      await widget.cancelRepair(record.id, revision: record.revision);
      if (!mounted || tokenManager.sessionId != _ownerSession) return;
      await AppPrompt.showSuccess('报修已取消');
      if (mounted && tokenManager.sessionId == _ownerSession) {
        Navigator.pop(context, true);
      }
    } on Object catch (error) {
      if (!mounted || tokenManager.sessionId != _ownerSession) return;
      if (_isCancellingRepair) {
        setState(() => _cancellationNeedsRefresh = true);
      }
      await AppPrompt.showException(error, fallback: '取消报修失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _isCancellingRepair = false;
          _isConfirmingCancellation = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final RepairRecord? record = _repair;
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, _) {
        // 有操作成功时通知列表刷新。
        if (!didPop) Navigator.pop(context, _hasRepairChanges);
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: const Text('报修详情'), actions: <Widget>[
          if (record != null) RepairReminderButton(repairId: record.id),
          const NotificationInboxButton(),
          IconButton(
              tooltip: '刷新进度',
              onPressed: _isLoadingDetail ||
                      _isCancellingRepair ||
                      _isSubmittingAction ||
                      tokenManager.sessionId != _ownerSession
                  ? null
                  : _loadRepairDetail,
              icon: const Icon(Icons.refresh)),
        ]),
        body: AsyncStateView(
          isLoading: _isLoadingDetail,
          errorMessage: _error,
          onRetry: _loadRepairDetail,
          hasContent: record != null,
          builder: (_) => record == null
              ? const SizedBox.shrink()
              : AbsorbPointer(
                  absorbing: _isSubmittingAction ||
                      _isChoosingReplacementSchedule ||
                      _isCancellingRepair ||
                      _isConfirmingCancellation ||
                      _cancellationNeedsRefresh,
                  child: ListView(children: <Widget>[
                    if (record.workflowVersion == 1)
                      RepairProgress(record: record),
                    ..._buildStatusNotices(record),
                    if (record.hasActiveSchedule)
                      RepairScheduleCard(
                          record: record,
                          isResident: true,
                          onAccept: () => _respondToSchedule(accept: true),
                          onDecline: () => _respondToSchedule(accept: false),
                          onInconvenient:
                              record.canFeedback ? _submitFeedback : null),
                    const _Section('报修信息'),
                    _Row('维修项目', record.repairItemName),
                    if (record.staffingMessage.isNotEmpty)
                      _Row('安排进展', record.staffingMessage),
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
                    if (record.round > 1)
                      _Row('维修轮次', '第 ${record.round} 轮（返修）'),
                    const _Section('联系方式'),
                    if (record.workerName.isNotEmpty)
                      _Contact(
                          '维修师傅 ${record.workerName}', record.workerMobile),
                    _Contact('物业', record.propertyPhone),
                    const _Section('故障描述'),
                    _Row('描述', record.description),
                    if (record.attachment.isNotEmpty)
                      Padding(
                          padding: const EdgeInsets.all(16),
                          child: RepairPhotos(urls: record.attachment)),
                    ..._buildCurrentRoundAndFees(record),
                  ]),
                ),
        ),
        bottomNavigationBar:
            record == null ? null : _buildActionButtons(record),
      ),
    );
  }

  /// 顶部提示卡：待你回应的事项和截止时刻，不依赖推送。
  List<Widget> _buildStatusNotices(RepairRecord record) {
    final List<Widget> cards = <Widget>[];
    final RepairRescheduleOffer? offer = record.rescheduleOffer;
    if (offer != null && offer.isOpen) {
      cards.add(_Notice('请选择新的上门时间',
          '原定时间暂时排不开师傅，请在 ${formatVisitTime(offer.deadline)} 前选择新时间',
          actions: <Widget>[
            FilledButton(
                onPressed: _isChoosingReplacementSchedule
                    ? null
                    : _chooseReplacementSchedule,
                child: const Text('选择新时间')),
            TextButton(
                onPressed: _isChoosingReplacementSchedule
                    ? null
                    : () => _chooseReplacementSchedule(keep: true),
                child: const Text('保持原时间，继续等')),
          ]));
    }
    final RepairPending? reschedule = record.reschedule;
    if (record.canConfirm) {
      cards.add(_Notice(
          record.status == RepairStatus.processing
              ? '维修结果已保存，现场检查后可直接确认修好'
              : '师傅已提交完工，请确认是否修好',
          record.confirmDeadline.isEmpty
              ? ''
              : '${formatVisitTime(record.confirmDeadline)} 前未操作，将自动确认完成'));
    } else if (record.confirmUnavailableReason.isNotEmpty &&
        (record.status == RepairStatus.processing ||
            record.status == RepairStatus.confirming)) {
      cards.add(_Notice('暂时不能确认修好', record.confirmUnavailableReason));
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
                      onPressed: () => _respondToSchedule(accept: false),
                      child: const Text('不同意')),
                  FilledButton(
                      onPressed: () => _respondToSchedule(accept: true),
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
      cards.add(_Notice(
          '售后期至 ${formatVisitTime(record.warrantyEnd)}', '期间如有问题，可申请重新排查并返修'));
    }
    return cards;
  }

  /// 只展示本次维修内容；此前费用单独保留。
  List<Widget> _buildCurrentRoundAndFees(RepairRecord record) {
    final List<Widget> rows = <Widget>[];
    for (final RepairRound round in record.rounds) {
      // 当前区域只显示本轮维修，旧轮次的费用在下面单独显示。
      if (round.number != record.round) {
        continue;
      }

      final String problemDescription =
          round.problem.isEmpty ? record.description : round.problem;
      final String causeDescription = round.cause.isEmpty ? '待排查' : round.cause;

      rows.addAll(<Widget>[
        _Section('第 ${round.number} 轮维修'),
        _Row('本次问题', problemDescription),
        _Row('排查原因', causeDescription),
      ]);

      // 维修说明与排查原因相同时，不重复显示同一段文字。
      if (round.note.isNotEmpty && round.note != round.cause) {
        rows.add(_Row('维修说明', round.note));
      }
      final String reportedCost = round.cost == null ? '' : '${round.cost} 元';
      rows.add(_Row('上报费用', reportedCost));
      if (round.verifiedNote.isNotEmpty) {
        rows.add(_Row('物业核实', round.verifiedNote));
      }
      if (round.rejectReason.isNotEmpty) {
        rows.add(_Row('未修好原因', round.rejectReason));
      }
      if (round.confirmedAt.isNotEmpty) {
        final String confirmationLabel =
            round.confirmedBy == 'system' ? '自动确认' : '住户确认';
        rows.add(_Row(confirmationLabel, formatVisitTime(round.confirmedAt)));
      }
    }
    if (record.fees.isNotEmpty) {
      rows.add(const _Section('费用记录'));
      for (final fee in record.fees) {
        String feeDescription = '${fee.cost} 元';
        if (fee.verifiedNote.isNotEmpty) {
          feeDescription += '；${fee.verifiedNote}';
        }
        rows.add(_Row('第 ${fee.number} 轮上报费用', feeDescription));
      }
    }
    return rows;
  }

  Widget? _buildActionButtons(RepairRecord record) {
    if (_cancellationNeedsRefresh) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
            const Text('取消结果尚未确认，请刷新工单状态后再操作。'),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _isLoadingDetail ? null : _loadRepairDetail,
              child: const Text('刷新工单状态'),
            ),
          ]),
        ),
      );
    }
    final List<Widget> buttons = <Widget>[
      if (record.canConfirm ||
          (record.confirmationAction != null &&
              (record.status == RepairStatus.processing ||
                  record.status == RepairStatus.confirming)))
        FilledButton(
          onPressed:
              record.canConfirm && !_isConfirmingCompletion && !_isLoadingDetail
                  ? _confirmRepair
                  : null,
          child: const Text('确认修好'),
        ),
      if (record.canReject)
        OutlinedButton(onPressed: _rejectRepair, child: const Text('还没修好')),
      if (record.canReschedule && record.agreedTime.isNotEmpty)
        OutlinedButton(
            onPressed: _proposeReschedule, child: const Text('修改预约')),
      if (record.canApplyAftersale)
        FilledButton(
            onPressed: _applyForAftersale, child: const Text('申请售后返修')),
      if (record.canFeedback &&
          (record.reworkUsed ||
              record.status == RepairStatus.completed ||
              record.status == RepairStatus.confirming))
        OutlinedButton(onPressed: _submitFeedback, child: const Text('反馈问题')),
      if (record.canRevoke)
        FilledButton(
          onPressed: _isCancellingRepair ||
                  _isConfirmingCancellation ||
                  _isLoadingDetail ||
                  _isChoosingReplacementSchedule ||
                  _isConfirmingCompletion
              ? null
              : _cancelRepair,
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          child: _isCancellingRepair
              ? const CircularProgressIndicator()
              : Text(record.revokeNeedsWorker ? '申请撤销' : '取消报修'),
        ),
    ];
    if (buttons.isEmpty) return null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AbsorbPointer(
          absorbing: _isCancellingRepair ||
              _isConfirmingCancellation ||
              _isChoosingReplacementSchedule,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.end,
            children: _isSubmittingAction
                ? const <Widget>[CircularProgressIndicator()]
                : buttons,
          ),
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
