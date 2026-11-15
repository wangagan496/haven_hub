import 'dart:async';

import 'package:flutter/material.dart';
import '../../api/repair.dart';
import '../../models/repair.dart';
import '../../models/repair_page.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/data_state.dart';
import '../../utils/date_utils.dart';
import '../../utils/logger.dart';
import '../../utils/retry_strategy.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';
import '../../widgets/async_state_view.dart';
import '../../widgets/notification_actions.dart';
import 'repair_navigation.dart';

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
