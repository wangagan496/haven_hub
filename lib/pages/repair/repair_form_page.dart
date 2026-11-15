import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart' show Get, Inst;

import '../../api/house.dart';
import '../../api/repair.dart';
import '../../api/user.dart';
import '../../controller/repair/repair_submission_flow.dart';
import '../../controller/user_info_controller.dart';
import '../../models/house.dart';
import '../../models/repair.dart';
import '../../platform/avatar_picker.dart';
import '../../platform/repair_photo_picker.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/date_utils.dart';
import '../../utils/repair_draft_store.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';
import '../../utils/validators.dart';
import '../../widgets/async_state_view.dart';
import '../../widgets/repair_dialogs.dart';
import '../../widgets/repair_photos.dart';
import '../../widgets/repair_slot_picker.dart';
import 'repair_detail_page.dart';

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
  bool _preparingSubmission = false;
  bool _waitingForConfirmation = false;
  late final RepairSubmissionFlow _submissionFlow;
  bool get _submitting => _preparingSubmission || _submissionFlow.busy;
  bool get _submitted => _submissionFlow.submitted;
  bool get _resultUnconfirmed => _submissionFlow.resultUnconfirmed;
  RepairRecord? get _pendingSubmission => _submissionFlow.pendingSubmission;
  bool get _draftSaveFailed => _submissionFlow.draftSaveFailed;
  bool get _draftSaveConflict => _submissionFlow.draftSaveConflict;
  bool _optionsLoaded = false;
  bool _draftLoading = false;
  bool _formEdited = false;
  bool _restoringDraft = false;
  bool _draftLoaded = false;
  bool _draftRestored = false;
  bool _draftReadFailed = false;
  bool _draftCorrupted = false;
  bool _discardingCorruptedDraft = false;
  bool _identityLoading = false;
  String? _identityError;
  Timer? _draftTimer;
  VoidCallback? _removeUserListener;
  Future<void>? _identityRequest;
  Future<void>? _draftRestoreRequest;
  String get _draftUserKey => _submissionFlow.ownerKey;
  late final int _formSessionId;
  String? _error;
  @override
  void initState() {
    super.initState();
    _formSessionId = tokenManager.sessionId;
    _submissionFlow = RepairSubmissionFlow(
      ownerKey: _currentUserKey(),
      isOwnerCurrent: (owner) =>
          tokenManager.sessionId == _formSessionId &&
          _currentUserKey() == owner,
      draftStore: widget.draftStore ?? repairDraftStore,
      submitter: widget.submitter,
      submissionLoader: widget.submissionLoader,
      submissionCloser: widget.submissionCloser,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
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
    _submissionFlow.dispose();
    _mobile.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _slot.isNotEmpty &&
        !_submitting) {
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
    _captureDraft();
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_saveDraft());
    });
  }

  void _captureDraft() {
    if (!_sameOwner) return;
    _submissionFlow.captureDraft(_formRecord(),
        waitingSchedule: _waitingSchedule);
  }

  Future<bool> _saveDraft() {
    if (!_draftLoaded) return Future<bool>.value(false);
    _captureDraft();
    return _submissionFlow.saveDraft();
  }

  Future<void> _restoreDraft() {
    final Future<void>? pending = _draftRestoreRequest;
    if (pending != null) return pending;
    if (!mounted || _draftLoaded || _submitted || !_sameOwner) {
      return Future<void>.value();
    }
    // 未知身份时不登记一个已完成的恢复任务，避免它挡住稍后到达资料的恢复。
    if (_draftUserKey.isEmpty && _currentUserKey().isEmpty) {
      return Future<void>.value();
    }
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
      final RepairDraft? draft = await _submissionFlow.loadDraft(
          _draftUserKey.isEmpty ? _currentUserKey() : _draftUserKey);
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
          // 流程已恢复回执；新输入只影响可编辑内容。
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
        _captureDraft();
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
      final bool removed = await _submissionFlow.discardCorruptedDraft();
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
        _captureDraft();
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
    setState(() => _preparingSubmission = true);
    try {
      bool legacyConfirmed = false;
      if (_resultUnconfirmed) {
        legacyConfirmed = await _confirmSubmission(
          title: '上次提交结果未确认',
          content: '服务器可能已经创建报修记录。建议先查看“我的报修”；再次提交可能产生重复记录。',
          cancelLabel: '先不提交',
          confirmLabel: '仍然提交',
        );
        if (!mounted || !_sameOwner || !legacyConfirmed) return;
      }
      // 与原交互一致，在用户确认之后复查时段，避免等待确认期间容量变化。
      if (_slot.isNotEmpty) {
        final String selected = _slot;
        await _refreshSlot();
        if (!mounted || !_sameOwner) return;
        if (_slot != selected || _scheduleWarning != null) {
          await _saveDraft();
          if (!mounted || !_sameOwner) return;
          await AppPrompt.showWarning(_scheduleWarning ?? '时段已变化，请重新选择');
          return;
        }
      }
      _draftTimer?.cancel();
      _captureDraft();
      final RepairSubmissionResult result = await _submissionFlow.submit(
        confirmLegacySubmission: () async => legacyConfirmed,
      );
      await _presentSubmissionResult(result,
          fallback: '报修提交失败，请重试', refreshConflict: true);
    } on Object catch (error) {
      if (mounted && _sameOwner) {
        await AppPrompt.showException(error, fallback: '报修提交失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _preparingSubmission = false);
    }
  }

  Future<bool> _confirmSubmission({
    required String title,
    required String content,
    required String cancelLabel,
    required String confirmLabel,
  }) async {
    if (!mounted || !_sameOwner) return false;
    setState(() => _waitingForConfirmation = true);
    try {
      return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(title),
              content: Text(content),
              actions: <Widget>[
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(cancelLabel)),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(confirmLabel)),
              ],
            ),
          ) ??
          false;
    } finally {
      if (mounted) setState(() => _waitingForConfirmation = false);
    }
  }

  Future<void> _presentSubmissionResult(RepairSubmissionResult result,
      {required String fallback, bool refreshConflict = false}) async {
    if (!mounted || !_sameOwner) return;
    switch (result) {
      case RepairSubmissionIgnored():
        return;
      case RepairSubmissionCreated():
        await _finishSubmission(result);
      case RepairSubmissionNotSent():
        await AppPrompt.showWarning(result.conflict
            ? '已有一条待确认的报修，请先处理那条提交回执；当前内容没有覆盖它'
            : '提交回执未能保存，本次尚未发送，请重试');
      case RepairSubmissionUnknown():
        await AppPrompt.showWarning('暂未查到提交结果，原请求可能仍在处理；可稍后查询或按原内容重试');
      case RepairSubmissionStopped():
        await AppPrompt.showWarning(result.draftSaved
            ? '本次提交已停止，可以修改后重新提交'
            : '本次提交已停止，但本机草稿保存失败，请保留页面');
      case RepairSubmissionFailed():
        final Object error = result.error;
        if (result.uncertain) {
          await AppPrompt.showWarning('提交结果未确认，已保留提交回执，可查看结果或按原内容重试');
        } else if (refreshConflict &&
            error is NetworkException &&
            error.statusCode == 409) {
          await AppPrompt.showWarning('${error.message}，已刷新最新状态');
          if (!mounted || !_sameOwner) return;
          await _refreshSlot();
        } else {
          await AppPrompt.showException(error, fallback: fallback);
        }
    }
  }

  Future<void> _finishSubmission(RepairSubmissionCreated result) async {
    if (!mounted || !_sameOwner) return;
    if (!result.draftRemoved) {
      await AppPrompt.showWarning('报修已提交，但本机草稿清理失败，请勿重复提交');
    }
    if (!mounted || !_sameOwner) return;
    await AppPrompt.showSuccess('报修提交成功');
    if (!mounted || !_sameOwner) return;
    // 提交成功后直接进入新工单详情；拿不到编号时（旧服务端或测试替身）回到列表。
    final Object? created = result.value;
    final String createdId = created is String ? created.trim() : '';
    if (createdId.isNotEmpty) {
      await Navigator.pushReplacementNamed(context, RepairDetailPage.routeName,
          arguments: createdId, result: true);
    } else {
      Navigator.pop(context, true);
    }
  }

  Future<void> _resolveSubmission({bool retry = false}) async {
    if (_submitting || _submitted || _uploading || !_sameOwner) return;
    _captureDraft();
    final RepairSubmissionResult result = await _submissionFlow.resolve(
      confirmRetry: retry
          ? () => _confirmSubmission(
                title: '按原内容重试',
                content:
                    '将使用上次保存的报修内容和同一回执；如果已经提交成功，会打开原工单，不会重复创建。当前表单的修改不会用于这次重试。',
                cancelLabel: '先不提交',
                confirmLabel: '确认重试',
              )
          : null,
    );
    await _presentSubmissionResult(result, fallback: '提交结果暂时无法确认，请稍后重试');
  }

  Future<void> _stopSubmission() async {
    if (_submitting || _submitted || _uploading || !_sameOwner) return;
    _captureDraft();
    final RepairSubmissionResult result = await _submissionFlow.stop(
      confirm: () => _confirmSubmission(
        title: '停止本次提交',
        content: '若服务器已创建工单，会打开原工单；否则停止旧请求，之后可修改内容重新提交。此操作不会取消已创建的工单。',
        cancelLabel: '返回',
        confirmLabel: '确认停止',
      ),
    );
    await _presentSubmissionResult(result, fallback: '停止结果未确认，请稍后查询');
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
