import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart' show Get, Inst;

import '../../api/house.dart';
import '../../api/repair.dart';
import '../../api/user.dart';
import '../../controller/user_info_controller.dart';
import '../../models/house.dart';
import '../../models/repair.dart';
import '../../models/repair_page.dart';
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

export '../../models/repair_page.dart' show RepairStatusFilter;

/// 打开新增报修页，返回页面报告的新增结果；没有返回结果时为 null。
Future<bool?> openNewRepairPage(BuildContext context) {
  return Navigator.pushNamed<bool>(context, RepairFormPage.routeName);
}

/// 打开指定工单的详情页，返回页面报告的工单变化结果。
Future<bool?> openRepairDetailPage(BuildContext context, String repairId) {
  return Navigator.pushNamed<bool>(
    context,
    RepairDetailPage.routeName,
    arguments: repairId,
  );
}

class RepairListPage extends StatefulWidget {
  const RepairListPage({
    this.loadRepairs,
    this.loadPage = getPreloadedRepairPageApi,
    super.key,
  });
  static const String routeName = repairList;

  /// 兼容已有完整列表注入；正式入口默认按页读取。
  final RepairListLoader? loadRepairs;
  final RepairPageLoader loadPage;
  @override
  State<RepairListPage> createState() => _RepairListPageState();
}

class _RepairListPageState extends State<RepairListPage> {
  // 保存已读页；追加失败保留内容，刷新成功后替换为第一页。
  DataState<List<RepairRecord>> _repairListState = DataState.idle();
  DataState<void> _moreState = DataState.idle();
  int _generation = 0;
  int _listRevision = 0;
  int _nextPage = 2;
  int _total = 0;
  bool _hasMore = false;
  bool get _isPaged => widget.loadRepairs == null;

  // 用户当前选中的状态，例如“待派单”或“已完成”。
  RepairStatusFilter _selectedFilter = RepairStatusFilter.all;

  // 保存筛选结果，页面显示这里的工单；切换筛选或加载数据后更新。
  List<RepairRecord> _filterResult = const [];

  @override
  void initState() {
    super.initState();
    tokenManager.sessionChanges.addListener(_onSessionChanged);
    unawaited(_loadRepairs(usePreload: true));
  }

  @override
  void dispose() {
    tokenManager.sessionChanges.removeListener(_onSessionChanged);
    super.dispose();
  }

  bool _isCurrent(int generation, int sessionId) =>
      mounted &&
      _generation == generation &&
      tokenManager.sessionId == sessionId;

  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {
      _generation++;
      _repairListState = tokenManager.getToken().isEmpty
          ? DataState.error('登录状态已变化，请重新登录')
          : DataState.idle();
      _filterResult = const [];
      _moreState = DataState.idle();
      _hasMore = false;
      _total = 0;
      _nextPage = 2;
    });
    if (tokenManager.getToken().isNotEmpty) unawaited(_loadRepairs());
  }

  /// 从已读取的工单中选出符合当前状态的记录，不请求服务器。
  List<RepairRecord> _filterRepairs() {
    final List<RepairRecord>? allRepairs = _repairListState.data;
    if (allRepairs == null) {
      return const [];
    }

    final List<RepairRecord> filteredRepairs = [];
    // 逐张检查工单，只留下当前筛选条件允许显示的工单。
    for (final RepairRecord repair in allRepairs) {
      if (_selectedFilter.shouldShow(repair)) {
        filteredRepairs.add(repair);
      }
    }
    return filteredRepairs;
  }

  /// 分页时从服务端重读该条件第一页，不能只筛选已经加载的部分记录。
  void _selectFilter(RepairStatusFilter newFilter) {
    if (_selectedFilter == newFilter) {
      return;
    }
    setState(() {
      _selectedFilter = newFilter;
      if (_isPaged) {
        _generation++;
        _repairListState = DataState.idle();
        _filterResult = const [];
        _moreState = DataState.idle();
        _hasMore = false;
      } else {
        _filterResult = _filterRepairs();
      }
    });
    if (_isPaged) unawaited(_loadRepairs());
  }

  /// 加载报修列表
  ///
  /// [isManualRetry] 是否是用户手动点击重试按钮触发的
  Future<void> _loadRepairs(
      {bool isManualRetry = false,
      bool usePreload = false,
      bool restart = false}) async {
    // 页面已离开就不再加载；正在加载时不重复请求。
    if (!mounted) return;
    if (_repairListState.isLoading && !restart) return;
    final int sessionId = tokenManager.sessionId;
    final int generation = ++_generation;
    final RepairStatusFilter filter = _selectedFilter;

    // 刷新期间继续保留已有工单，等新数据加载完成再替换。
    setState(() {
      final List<RepairRecord>? previousRepairs = _repairListState.data;
      _repairListState = DataState.loading(previousRepairs);
      _moreState = DataState.idle();
    });

    try {
      // 读取工单；失败时沿用自动重试或手动重试策略。
      RepairPage? firstPage;
      final List<RepairRecord> loadedRepairs = await retryAsync(
        action: () async {
          if (!_isPaged) return widget.loadRepairs!();
          firstPage = await widget.loadPage(
              current: 1, filter: filter, usePreload: usePreload);
          return firstPage!.rows;
        },
        strategy: isManualRetry ? RetryStrategy.manual : RetryStrategy.auto,
        shouldRetry: () => _isCurrent(generation, sessionId),
        onRetry: (attempt, error) {
          Logger.debug('[RepairList] 第 $attempt 次重试');
        },
      );

      if (!_isCurrent(generation, sessionId)) return;
      setState(() {
        _repairListState = DataState.success(loadedRepairs);
        _filterResult = _filterRepairs();
        _nextPage = 2;
        _total = firstPage?.total ?? loadedRepairs.length;
        _hasMore = firstPage?.hasMore ?? false;
        if (_isPaged) _listRevision++;
      });
    } on Object catch (error) {
      final String errorMessage =
          describeError(error, fallback: '获取报修列表失败，请重试');
      if (!_isCurrent(generation, sessionId)) return;
      final List<RepairRecord>? previousRepairs = _repairListState.data;
      setState(() {
        _repairListState = DataState.error(errorMessage, previousRepairs);
        _filterResult = _filterRepairs();
      });

      // 如果是第一次加载失败（没有旧数据），显示错误提示
      // 如果是刷新失败（有旧数据），只在底部toast提示
      if (!_repairListState.hasData) {
        await AppPrompt.showError(errorMessage);
      } else {
        await AppPrompt.showToast(errorMessage);
      }
    }
  }

  Future<void> _loadMore() async {
    if (!mounted ||
        !_isPaged ||
        !_hasMore ||
        _moreState.isLoading ||
        _repairListState.isLoading) {
      return;
    }
    final int generation = _generation;
    final int sessionId = tokenManager.sessionId;
    final int current = _nextPage;
    final RepairStatusFilter filter = _selectedFilter;
    final List<RepairRecord> previous = _repairListState.data ?? const [];
    setState(() => _moreState = DataState.loading());
    try {
      final RepairPage page = await retryAsync(
        action: () => widget.loadPage(
            current: current, filter: filter, usePreload: false),
        strategy: RetryStrategy.manual,
        shouldRetry: () => _isCurrent(generation, sessionId),
      );
      if (!_isCurrent(generation, sessionId)) return;
      final Set<String> ids = previous.map((record) => record.id).toSet();
      if (page.current != current ||
          page.total != _total ||
          page.rows.isEmpty ||
          page.rows.any((record) => !ids.add(record.id)) ||
          (!page.hasMore && previous.length + page.rows.length != page.total)) {
        throw const FormatException('报修记录已变化，请刷新列表后继续');
      }
      setState(() {
        _repairListState = DataState.success(
            List<RepairRecord>.unmodifiable([...previous, ...page.rows]));
        _filterResult = _filterRepairs();
        _nextPage = current + 1;
        _hasMore = page.hasMore;
        _moreState = DataState.idle();
      });
    } on Object catch (error) {
      if (!_isCurrent(generation, sessionId)) return;
      setState(() => _moreState =
          DataState.error(describeError(error, fallback: '加载更多失败，请重试')));
    }
  }

  Future<void> _openRepairDetail(String repairId) async {
    await openRepairDetailPage(context, repairId);
    if (!mounted) return;

    // 从详情页回来就刷新，因为查看期间师傅也可能更新工单。
    await _loadRepairs(restart: true);
  }

  Future<void> _openNewRepair() async {
    // 打开新增报修页，等待它报告是否新增成功。
    final bool? isRepairCreated = await openNewRepairPage(context);
    if (!mounted) return;

    // 页面没有交回结果，就结束这里的处理，不刷新列表。
    if (isRepairCreated == null) {
      return;
    }

    if (isRepairCreated) {
      // 页面报告新增成功后，重新加载报修列表。
      await _loadRepairs(restart: true);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: const Text('我的报修'),
          actions: const [NotificationInboxButton()],
        ),
        body: Column(children: <Widget>[
          // 筛选按钮行
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: RepairStatusFilter.values.map((buttonOption) {
                return _buildFilterChip(
                  label: buttonOption.displayName,
                  isButtonSelected: _selectedFilter == buttonOption,
                  selectOption: () => _selectFilter(buttonOption),
                );
              }).toList(),
            ),
          ),
          Expanded(
              child: AsyncStateView(
            isLoading: _repairListState.isLoading,
            errorMessage: _repairListState.errorMessage,
            onRetry: () => _loadRepairs(isManualRetry: true), // 手动重试标记
            hasContent: _repairListState.hasData,
            builder: (BuildContext context) => RefreshIndicator(
              onRefresh: _loadRepairs,
              child: _buildRepairList(),
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
                          onPressed: _openNewRepair,
                          icon: const Icon(Icons.add),
                          label: const Text('新增报修'))))),
        ]),
      );

  /// 没有符合条件的工单时显示提示，否则逐条显示工单。
  Widget _buildRepairList() {
    if (_filterResult.isEmpty) {
      final String emptyMessage = _selectedFilter == RepairStatusFilter.all
          ? '还没有报修记录，点击下方按钮新增吧'
          : '没有符合条件的报修记录\n试试切换到"全部"查看';
      return ListView(
        key: ValueKey((_selectedFilter, _listRevision)),
        physics: const AlwaysScrollableScrollPhysics(),
        children: <Widget>[
          const SizedBox(height: 180),
          const Icon(Icons.build_outlined, size: 52, color: AppColors.divider),
          const SizedBox(height: 12),
          Center(
            child: Text(
              emptyMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textTertiary),
            ),
          ),
        ],
      );
    }

    // 筛选结果里一共有多少张工单。
    final int repairCount = _filterResult.length;

    return ListView.separated(
      key: ValueKey((_selectedFilter, _listRevision)),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      // 告诉列表一共要显示多少张工单。
      itemCount: repairCount + (_isPaged ? 1 : 0),
      // 两张工单卡片之间留出间距。
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (BuildContext context, int repairIndex) {
        if (repairIndex == repairCount) return _buildPageFooter();
        // 按位置取出这张工单的数据；位置从 0 开始，不是工单编号。
        final RepairRecord repairData = _filterResult[repairIndex];
        final String serviceName = repairData.repairItemName.isEmpty
            ? '维修服务'
            : repairData.repairItemName;
        final String visitTimeText = repairData.visitTime.isNotEmpty
            ? formatVisitTime(repairData.visitTime)
            : repairData.appointment;

        return _buildRepairCard(
          serviceName: serviceName,
          visitTimeText: visitTimeText,
          mobile: repairData.mobile,
          statusText: repairData.statusText,
          openDetail: repairData.id.isEmpty
              ? null
              : () => _openRepairDetail(repairData.id),
        );
      },
    );
  }

  Widget _buildPageFooter() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(children: <Widget>[
          Text('已加载 ${_filterResult.length} / $_total 条'),
          if (_moreState.hasError) ...[
            Text(_moreState.errorMessage!, textAlign: TextAlign.center),
            TextButton(
                onPressed: _repairListState.isLoading ? null : _loadRepairs,
                child: const Text('刷新列表')),
          ],
          if (_hasMore)
            TextButton(
              onPressed: _moreState.isLoading || _repairListState.isLoading
                  ? null
                  : _loadMore,
              child: Text(_moreState.isLoading
                  ? '加载中…'
                  : _moreState.hasError
                      ? '重试加载更多'
                      : '加载更多'),
            )
          else
            const Text('已显示全部记录'),
        ]),
      );

  /// 显示一张工单卡片，把业务内容放到 Flutter 对应的显示位置。
  Widget _buildRepairCard({
    required String serviceName,
    required String visitTimeText,
    required String mobile,
    required String statusText,
    required VoidCallback? openDetail,
  }) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: openDetail,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                flex: 3,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(serviceName,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(visitTimeText),
                    Text(mobile),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                flex: 2,
                child: Text(
                  statusText,
                  textAlign: TextAlign.end,
                  style: const TextStyle(color: AppColors.accent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建自定义筛选按钮
  Widget _buildFilterChip({
    required String label,
    required bool isButtonSelected,
    required VoidCallback selectOption,
  }) {
    // 按钮内部留白：左右各 16，上下各 8。
    const buttonPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 8);
    // 按钮外观：背景颜色、圆角和边框。
    final buttonStyle = BoxDecoration(
      color: isButtonSelected ? AppColors.accent : Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
        color: isButtonSelected ? AppColors.accent : const Color(0xFFE4E7EC),
      ),
    );

    return GestureDetector(
      onTap: selectOption,
      child: Container(
        padding: buttonPadding,
        decoration: buttonStyle,
        child: Text(
          label,
          style: TextStyle(
            color: isButtonSelected ? Colors.white : AppColors.textSecondary,
            fontSize: 14,
            fontWeight: isButtonSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

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

class RepairFormPage extends StatefulWidget {
  const RepairFormPage(
      {this.houseLoader = getHouseListApi,
      this.itemLoader = getRepairItemsApi,
      this.submitter = submitRepairApi,
      this.submissionLoader = getRepairSubmissionApi,
      this.submissionCloser = closeRepairSubmissionApi,
      this.userInfoLoader = getUserInfoApi,
      this.photoPicker = pickRepairPhotos,
      this.photoUploader = uploadPhotoAPI,
      this.draftStore,
      this.draftUserKey,
      this.slotsLoader = getRepairSlotsApi,
      super.key});
  static const String routeName = repairForm;
  final HouseListLoader houseLoader;
  final RepairItemLoader itemLoader;
  final SubmitRepairLoader submitter;
  final Future<String?> Function(String) submissionLoader;
  final Future<String?> Function(String) submissionCloser;
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
  int _slotRefreshRequest = 0;
  bool _loading = false;
  bool _submitting = false;
  bool _waitingForConfirmation = false;
  bool _resultUnconfirmed = false;
  RepairRecord? _pendingSubmission;
  bool _optionsLoaded = false;
  bool _draftLoading = false;
  bool _formEdited = false;
  bool _restoringDraft = false;
  bool _draftLoaded = false;
  bool _draftRestored = false;
  bool _draftReadFailed = false;
  bool _draftCorrupted = false;
  bool _discardingCorruptedDraft = false;
  bool _draftSaveFailed = false;
  bool _draftSaveConflict = false;
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
    if (state == AppLifecycleState.resumed && _slot.isNotEmpty && !_submitting) {
      unawaited(_refreshSlot());
    }
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
      Get.find<UserInfoController>().updateLocalUserInfo(info);
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
        slot: _slot,
        urgentRequest: _urgentRequest,
        asap: _asap,
        description: _description.text.trim(),
        attachment: List<String>.of(_photos),
      );

  void _scheduleDraftSave() {
    if (_restoringDraft || !_sameOwner) return;
    _formEdited = true;
    if (!_draftLoaded || _submitted) return;
    _lastOwnedDraft = RepairDraft(
      submission: _pendingSubmission,
      record: _formRecord(),
      waitingSchedule: _waitingSchedule,
      resultUnconfirmed: _resultUnconfirmed,
    );
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_saveDraft());
    });
  }

  Future<bool> _saveDraft({String? expectedSubmissionId}) async {
    if (!_draftLoaded || _submitted || _draftUserKey.isEmpty) return false;
    final RepairRecord? record =
        _sameOwner ? _formRecord() : _lastOwnedDraft?.record;
    if (record == null) return false;
    final RepairDraft draft = RepairDraft(
      submission: _pendingSubmission,
      record: record,
      waitingSchedule:
          _sameOwner ? _waitingSchedule : _lastOwnedDraft?.waitingSchedule,
      resultUnconfirmed: _resultUnconfirmed,
    );
    _lastOwnedDraft = draft;
    try {
      final bool saved = await _draftStore.save(_draftUserKey, draft,
          expectedSubmissionId: expectedSubmissionId);
      if (mounted && _sameOwner) {
        setState(() {
          _draftSaveFailed = !saved;
          _draftSaveConflict = false;
        });
      }
      return saved;
    } on RepairDraftConflictException {
      RepairDraft? existing;
      try {
        existing = await _draftStore.load(_draftUserKey);
      } on Object {/* Keep the conflict visible below. */}
      if (mounted && _sameOwner) {
        setState(() {
          _draftSaveFailed = true;
          _draftSaveConflict = true;
          if (existing?.submission != null) {
            _pendingSubmission = existing!.submission;
            _resultUnconfirmed = true;
            _lastOwnedDraft = existing;
          }
        });
      }
      return false;
    } on Object {
      if (mounted && _sameOwner) {
        setState(() {
          _draftSaveFailed = true;
          _draftSaveConflict = false;
        });
      }
      return false;
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
      final bool legacy = draft != null &&
          draft.record.slot.isEmpty &&
          draft.record.expectedTime.isNotEmpty;
      if (legacy && !_formEdited) {
        try {
          migrated = await matchDraftSlot(
              draft.record.expectedTime, widget.slotsLoader);
        } on Object catch (error) {
          migrationError = describeError(error, fallback: '旧草稿时段查询失败，请重新选择');
        }
        if (!mounted || !_sameOwner) return;
      }
      setState(() {
        if (draft != null) {
          // 即使已有新输入，也不能丢掉旧草稿的未确认提交记录。
          _resultUnconfirmed = _resultUnconfirmed || draft.resultUnconfirmed;
          _pendingSubmission ??= draft.submission;
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
              _waitingSchedule =
                  _slot.isEmpty && ((draft.waitingSchedule ?? false) || _asap);
              if ((legacy && migrated == null) ||
                  draft.record.appointment.isNotEmpty) {
                _scheduleWarning =
                    migrationError ?? '旧草稿时间无法对应可预约时段，请重新选择或提交待安排';
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
          submission: _pendingSubmission,
          record: _formRecord(),
          waitingSchedule: _waitingSchedule,
          resultUnconfirmed: _resultUnconfirmed,
        );
      });
      if (!_formEdited && _slot.isNotEmpty) await _refreshSlot();
      if (_formEdited) await _saveDraft();
    } on RepairDraftCorruptedException {
      // 损坏记录可能仍包含已发送的回执，保留它并把处理权交给用户。
      if (mounted && _sameOwner) {
        setState(() {
          _draftReadFailed = true;
          _draftCorrupted = true;
        });
      }
    } on Object {
      // 未能读取时不覆盖磁盘草稿，也不允许跳过可能存在的二次确认。
      if (mounted && _sameOwner) {
        setState(() {
          _draftReadFailed = true;
          _draftCorrupted = false;
        });
      }
    } finally {
      if (mounted) setState(() => _draftLoading = false);
    }
  }

  Future<void> _discardCorruptedDraft() async {
    if (_discardingCorruptedDraft ||
        !_draftCorrupted ||
        _draftUserKey.isEmpty ||
        !_sameOwner) {
      return;
    }
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            title: const Text('丢弃损坏草稿'),
            content: const Text('这条本机报修草稿无法安全读取，可能包含未确认的提交回执。确认后只会清除这条损坏记录。'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('确认丢弃'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted || !_sameOwner) return;
    setState(() => _discardingCorruptedDraft = true);
    try {
      final bool removed = await _draftStore.discardCorrupted(_draftUserKey);
      if (!mounted || !_sameOwner) return;
      if (!removed) {
        await AppPrompt.showWarning('本机草稿状态已变化，请重新读取后再操作');
        return;
      }
      setState(() {
        _draftCorrupted = false;
        _draftReadFailed = false;
        _draftLoaded = true;
        _draftRestored = false;
        _draftSaveFailed = false;
        _draftSaveConflict = false;
        _pendingSubmission = null;
        _resultUnconfirmed = false;
        _lastOwnedDraft = RepairDraft(
          record: _formRecord(),
          waitingSchedule: _waitingSchedule,
        );
      });
      await AppPrompt.showSuccess('已丢弃损坏草稿，可以新建报修');
    } on Object catch (error) {
      if (mounted && _sameOwner) {
        await AppPrompt.showException(error, fallback: '丢弃损坏草稿失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _discardingCorruptedDraft = false);
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
        await AppPrompt.showError(msg);
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
    final int request = ++_slotRefreshRequest;
    try {
      final RepairSlots data = await widget.slotsLoader(
          date: selected.split('#').first, repairItemId: _itemId);
      if (!mounted ||
          !_sameOwner ||
          selected != _slot ||
          request != _slotRefreshRequest) {
        return;
      }
      final bool valid = data.slots
          .any((RepairSlot item) => item.slot == selected && item.selectable);
      setState(() {
        _scheduleWarning = valid ? null : '原时段已不可选，请重新选择或提交待安排';
        if (!valid) {
          _slot = '';
          _waitingSchedule = false;
        }
      });
    } on Object catch (error) {
      if (mounted &&
          _sameOwner &&
          selected == _slot &&
          request == _slotRefreshRequest) {
        setState(() =>
            _scheduleWarning = describeError(error, fallback: '时段查询失败，请重试'));
      }
    }
  }

  Future<void> _pickDate() async {
    if (_itemId == null) {
      await AppPrompt.showWarning('请先选择维修项目');
      return;
    }
    if (_itemId == '1001' || _itemId == '1003') {
      await AppPrompt.showWarning('此类报修由物业明确技能后安排，请选择提交后等待安排');
      return;
    }
    final RepairSlot? selected = await pickVisitTime(context,
        initialSlot: _slot,
        repairItemId: _itemId,
        title: '选择期望上门日期',
        loader: widget.slotsLoader);
    if (selected != null && mounted && _sameOwner) {
      _slotRefreshRequest++;
      setState(() {
        _slot = selected.slot;
        _waitingSchedule = false;
        _asap = false;
        _scheduleWarning = null;
      });
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
        await AppPrompt.showException(error, fallback: '添加照片失败，请重试');
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
      await AppPrompt.showWarning('请重试或移除上传失败的照片');
      return;
    }
    if (!_sameOwner) {
      await AppPrompt.showWarning('登录账号已变化，请返回后重新打开报修页面');
      return;
    }
    if (!_draftLoaded) {
      await _ensureIdentity();
      if (!mounted) return;
      await _restoreDraft();
      if (!mounted) return;
      if (!_sameOwner) {
        await AppPrompt.showWarning('登录账号已变化，请返回后重新打开报修页面');
        return;
      }
      if (!_draftLoaded) {
        if (_draftCorrupted) {
          await AppPrompt.showWarning('本机报修草稿已损坏，请先丢弃后再提交');
          return;
        }
        await AppPrompt.showWarning(_draftUserKey.isEmpty
            ? _identityError ?? '账号信息尚未就绪，请保留当前页面，稍后再提交'
            : _draftReadFailed
                ? '本机草稿读取失败，请保留当前页面并重试'
                : '草稿尚未读取完成，请保留当前页面，稍后再提交');
        return;
      }
      // 读取草稿期间其他点击可能已经开始提交。
      if (_submitting || _submitted) return;
    }
    if (_pendingSubmission != null && _resultUnconfirmed) {
      await _resolveSubmission(retry: true);
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_slot.isEmpty && !_waitingSchedule) {
      await AppPrompt.showWarning('请选择上门时段或提交后等待安排');
      return;
    }
    if (_slot.isNotEmpty && _scheduleWarning != null) {
      await AppPrompt.showWarning('请重新查询并选择上门时段');
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
      if (_slot.isNotEmpty) {
        final String selected = _slot;
        await _refreshSlot();
        if (!mounted || !_sameOwner) return;
        if (_slot != selected || _scheduleWarning != null) {
          await _saveDraft();
          if (!mounted) return;
          await AppPrompt.showWarning(_scheduleWarning ?? '时段已变化，请重新选择');
          return;
        }
      }
      _draftTimer?.cancel();
      _pendingSubmission = RepairDraft.prepareSubmission(_formRecord());
      _resultUnconfirmed = true;
      if (!await _saveDraft()) {
        if (_draftSaveConflict) {
          if (mounted && _sameOwner) {
            await AppPrompt.showWarning('已有一条待确认的报修，请先处理那条提交回执；当前内容没有覆盖它');
          }
          return;
        }
        _pendingSubmission = null;
        _resultUnconfirmed = wasUnconfirmed;
        if (mounted && _sameOwner) {
          await AppPrompt.showWarning('提交回执未能保存，本次尚未发送，请重试');
        }
        return;
      }
      if (!mounted) return;
      if (!_sameOwner) throw const SessionChangedException();
      requestSent = true;
      final Object? created =
          await widget.submitter(_pendingSubmission!) as Object?;
      if (!mounted) return;
      if (!_sameOwner) throw const SessionChangedException();
      await _finishSubmission(created);
    } on Object catch (error) {
      if (!mounted) return;
      final bool uncertain = requestSent &&
          error is! BusinessException &&
          (error is! NetworkException ||
              (error.isTimeout ||
                  error is SessionChangedException ||
                  const <int?>{null, 408}.contains(error.statusCode) ||
                  (error.statusCode != null && error.statusCode! >= 500)));
      final String? previousSubmissionId = _pendingSubmission?.submissionId;
      setState(() {
        _resultUnconfirmed = wasUnconfirmed || uncertain;
        if (!_resultUnconfirmed) _pendingSubmission = null;
      });
      await _saveDraft(
          expectedSubmissionId:
              _resultUnconfirmed ? null : previousSubmissionId);
      if (!mounted || !_sameOwner) return;
      if (uncertain) {
        await AppPrompt.showWarning('提交结果未确认，已保留提交回执，可查看结果或按原内容重试');
      } else if (error is NetworkException && error.statusCode == 409) {
        await AppPrompt.showWarning('${error.message}，已刷新最新状态');
        if (!mounted || !_sameOwner) return;
        await _refreshSlot();
      } else {
        await AppPrompt.showException(error, fallback: '报修提交失败，请重试');
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

  Future<void> _finishSubmission(Object? created) async {
    if (!mounted || !_sameOwner) return;
    _submitted = true;
    if (_draftUserKey.isNotEmpty) {
      try {
        final bool removed = await _draftStore.remove(_draftUserKey);
        if (!mounted || !_sameOwner) return;
        if (!removed) {
          await AppPrompt.showWarning('报修已提交，但本机草稿清理失败，请勿重复提交');
        }
      } on Object {
        if (!mounted || !_sameOwner) return;
        await AppPrompt.showWarning('报修已提交，但本机草稿清理失败，请勿重复提交');
      }
    }
    if (!mounted || !_sameOwner) return;
    await AppPrompt.showSuccess('报修提交成功');
    if (!mounted || !_sameOwner) return;
    // 提交成功后直接进入新工单详情；拿不到编号时（旧服务端或测试替身）回到列表。
    final String createdId = created is String ? created.trim() : '';
    if (createdId.isNotEmpty) {
      await Navigator.pushReplacementNamed(context, RepairDetailPage.routeName,
          arguments: createdId, result: true);
    } else {
      Navigator.pop(context, true);
    }
  }

  Future<void> _resolveSubmission({bool retry = false}) async {
    final RepairRecord? pending = _pendingSubmission;
    if (_submitting ||
        _submitted ||
        _uploading ||
        pending == null ||
        !_sameOwner) {
      return;
    }
    setState(() => _submitting = true);
    try {
      final String? createdId =
          await widget.submissionLoader(pending.submissionId);
      if (!mounted || !_sameOwner) return;
      if (createdId != null) {
        await _finishSubmission(createdId);
        return;
      }
      if (!retry) {
        await AppPrompt.showWarning('暂未查到提交结果，原请求可能仍在处理；可稍后查询或按原内容重试');
        return;
      }
      setState(() => _waitingForConfirmation = true);
      final bool confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                    title: const Text('按原内容重试'),
                    content: const Text(
                        '将使用上次保存的报修内容和同一回执；如果已经提交成功，会打开原工单，不会重复创建。当前表单的修改不会用于这次重试。'),
                    actions: <Widget>[
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('先不提交')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('确认重试')),
                    ],
                  )) ??
          false;
      if (!mounted || !_sameOwner || !confirmed) return;
      setState(() => _waitingForConfirmation = false);
      final Object? created = await widget.submitter(pending) as Object?;
      if (!mounted || !_sameOwner) return;
      await _finishSubmission(created);
    } on Object catch (error) {
      if (!mounted || !_sameOwner) return;
      if (error is BusinessException && error.code == 40903) {
        await _clearSubmission();
        return;
      }
      await AppPrompt.showException(error, fallback: '提交结果暂时无法确认，请稍后重试');
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
          _waitingForConfirmation = false;
        });
      }
    }
  }

  Future<void> _clearSubmission() async {
    if (!mounted || !_sameOwner) return;
    final String? expectedSubmissionId = _pendingSubmission?.submissionId;
    setState(() {
      _pendingSubmission = null;
      _resultUnconfirmed = false;
    });
    final bool saved =
        await _saveDraft(expectedSubmissionId: expectedSubmissionId);
    if (!mounted || !_sameOwner) return;
    await AppPrompt.showWarning(
        saved ? '本次提交已停止，可以修改后重新提交' : '本次提交已停止，但本机草稿保存失败，请保留页面');
  }

  Future<void> _stopSubmission() async {
    final RepairRecord? pending = _pendingSubmission;
    if (_submitting ||
        _submitted ||
        _uploading ||
        pending == null ||
        !_sameOwner) {
      return;
    }
    setState(() {
      _submitting = true;
      _waitingForConfirmation = true;
    });
    try {
      final bool confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                    title: const Text('停止本次提交'),
                    content: const Text(
                        '若服务器已创建工单，会打开原工单；否则停止旧请求，之后可修改内容重新提交。此操作不会取消已创建的工单。'),
                    actions: <Widget>[
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('返回')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('确认停止')),
                    ],
                  )) ??
          false;
      if (!mounted || !_sameOwner || !confirmed) return;
      setState(() => _waitingForConfirmation = false);
      final String? createdId =
          await widget.submissionCloser(pending.submissionId);
      if (!mounted || !_sameOwner) return;
      if (createdId != null) {
        await _finishSubmission(createdId);
      } else {
        await _clearSubmission();
      }
    } on Object catch (error) {
      if (!mounted || !_sameOwner) return;
      await AppPrompt.showException(error, fallback: '停止结果未确认，请稍后查询');
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
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                          _draftSaveConflict
                                              ? '已有一条待确认的报修，请先处理提交回执；当前表单没有覆盖它。'
                                              : _pendingSubmission == null
                                                  ? '提交结果未确认：请先查看“我的报修”。再次提交可能产生重复记录。'
                                                  : '提交结果未确认：已保留上次内容与回执，可查询结果或按原内容重试。',
                                          style: const TextStyle(
                                              color: AppColors.danger)),
                                      if (_pendingSubmission != null)
                                        TextButton(
                                            onPressed: _resolveSubmission,
                                            child: const Text('查看提交结果')),
                                      if (_pendingSubmission != null)
                                        TextButton(
                                            onPressed: _stopSubmission,
                                            child: const Text('停止本次提交')),
                                    ]),
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
                            if (_draftReadFailed && _draftCorrupted)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    const Text(
                                        '本机报修草稿已损坏，可能包含未确认的提交回执；请先处理这条记录。'),
                                    TextButton(
                                      onPressed: _discardingCorruptedDraft
                                          ? null
                                          : _discardCorruptedDraft,
                                      child: Text(_discardingCorruptedDraft
                                          ? '正在丢弃…'
                                          : '丢弃损坏草稿'),
                                    ),
                                  ],
                                ),
                              )
                            else if (_draftReadFailed)
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
                                  _slotRefreshRequest++;
                                  setState(() {
                                    _itemId = value;
                                    _slot = '';
                                    _scheduleWarning = null;
                                    _waitingSchedule =
                                        value == '1003' || value == '1001';
                                  });
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
                            CheckboxListTile(
                                value: _waitingSchedule,
                                contentPadding: EdgeInsets.zero,
                                title: const Text('提交后等待安排'),
                                subtitle: _itemId == '1003'
                                    ? const Text('其他维修先由物业判断需要的技能，再安排上门')
                                    : null,
                                onChanged: (bool? value) {
                                  setState(() {
                                    _waitingSchedule = value ?? false;
                                    if (_waitingSchedule) {
                                      _slot = '';
                                    } else {
                                      _asap = false;
                                    }
                                    _scheduleWarning = null;
                                  });
                                  _scheduleDraftSave();
                                }),
                            CheckboxListTile(
                                value: _urgentRequest,
                                contentPadding: EdgeInsets.zero,
                                title: const Text('紧急诉求'),
                                onChanged: (bool? value) {
                                  setState(() {
                                    _urgentRequest = value ?? false;
                                    if (!_urgentRequest) _asap = false;
                                  });
                                  _scheduleDraftSave();
                                }),
                            if (_urgentRequest)
                              CheckboxListTile(
                                  value: _asap,
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('尽快上门'),
                                  onChanged: (bool? value) {
                                    setState(() {
                                      _asap = value ?? false;
                                      if (_asap) {
                                        _slot = '';
                                        _waitingSchedule = true;
                                        _scheduleWarning = null;
                                      }
                                    });
                                    _scheduleDraftSave();
                                  }),
                            if (_scheduleWarning != null)
                              Text(_scheduleWarning!),
                            ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(_slot.isEmpty
                                    ? '请选择期望上门时间'
                                    : formatSlotWindow(slot: _slot)),
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
