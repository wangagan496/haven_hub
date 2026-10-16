import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart' show Get, Inst;

import '../../api/house.dart';
import '../../api/repair.dart';
import '../../api/user.dart';
import '../../constant/index.dart';
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
import '../../widgets/repair_photos.dart';
import '../../widgets/repair_progress.dart';

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
        return GlobalVariable.localBackend ? '待派单' : '待处理';
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
  /// 返回 true 表示该记录应该显示
  bool matches(RepairRecord record) {
    switch (this) {
      case RepairStatusFilter.all:
        return true;
      case RepairStatusFilter.pending:
        return record.status == 1;
      case RepairStatusFilter.waiting:
        return record.status == 5;
      case RepairStatusFilter.processing:
        return record.status == 2;
      case RepairStatusFilter.completed:
        return record.status == 3;
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
        appBar: AppBar(title: const Text('我的报修')),
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
                          subtitle: Text('${item.appointment}\n${item.mobile}'),
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
      super.key});
  static const String routeName = AppRoutes.repairDetail;
  final RepairDetailLoader loader;
  final CancelRepairLoader cancelLoader;
  @override
  State<RepairDetailPage> createState() => _RepairDetailPageState();
}

class _RepairDetailPageState extends State<RepairDetailPage> {
  String _id = '';
  RepairRecord? _record;
  String? _error;
  bool _loading = false;
  bool _cancelling = false;
  bool _confirming = false;
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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await widget.loader(_id);
      if (mounted) setState(() => _record = value);
    } on Object catch (error) {
      final msg = describeError(error, fallback: '获取报修详情失败，请重试');
      if (mounted) {
        setState(() => _error = msg);
        await PromptAction.showError(msg);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cancel() async {
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
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('报修详情'), actions: <Widget>[
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
            : ListView(children: <Widget>[
                if (record.workflowVersion == 1) RepairProgress(record: record),
                const _Section('报修信息'),
                _Row('维修项目', record.repairItemName),
                _Row('预约时间', record.appointment),
                _Row('联系电话', record.mobile),
                _Row('报修房屋', record.houseInfo),
                _Row('处理状态', record.statusText),
                const _Section('故障描述'),
                _Row('描述', record.description),
                if (record.attachment.isNotEmpty)
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: RepairPhotos(urls: record.attachment)),
              ]),
      ),
      bottomNavigationBar: record?.canCancel != true
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: _cancelling || _confirming ? null : _cancel,
                  style:
                      FilledButton.styleFrom(backgroundColor: AppColors.danger),
                  child: _cancelling
                      ? const CircularProgressIndicator()
                      : const Text('取消报修'),
                ),
              ),
            ),
    );
  }
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
  DateTime? _date;
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
        appointment: _date == null ? '' : formatDate(_date!),
        description: _description.text.trim(),
        attachment: List<String>.of(_photos),
      );

  void _scheduleDraftSave() {
    if (_restoringDraft || !_sameOwner) return;
    _formEdited = true;
    if (!_draftLoaded || _submitted) return;
    _lastOwnedDraft = RepairDraft(
      record: _formRecord(),
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
              final DateTime today = DateUtils.dateOnly(DateTime.now());
              final DateTime? date =
                  DateTime.tryParse(draft.record.appointment);
              _date = date != null &&
                      !date.isBefore(today) &&
                      !date.isAfter(today.add(const Duration(days: 365)))
                  ? date
                  : null;
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
          resultUnconfirmed: _resultUnconfirmed,
        );
      });
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

  Future<void> _pickDate() async {
    final selected = await showDatePicker(
        context: context,
        initialDate: _date ?? DateTime.now(),
        firstDate: DateTime.now(),
        lastDate: DateTime.now().add(const Duration(days: 365)));
    if (selected != null && mounted) {
      setState(() => _date = selected);
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
    if (_date == null) {
      await PromptAction.showWarning('请选择预约日期');
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
      await widget.submitter(_formRecord());
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
      if (mounted) Navigator.pop(context, true);
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
                            ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(_date == null
                                    ? '请选择预约日期'
                                    : formatDate(_date!)),
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
