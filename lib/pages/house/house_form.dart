import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../api/house.dart';
import '../../api/user.dart';
import '../../controller/build_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../models/house.dart';
import '../../platform/local_image.dart'
    if (dart.library.io) '../../platform/local_image_io.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/house_submission_store.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';
import '../../utils/validators.dart';
import '../../widgets/cached_image.dart';
import '../../widgets/camera_dialog.dart';
import '../../widgets/house_draft_actions.dart';
import '../../widgets/image_preview.dart';
import '../../widgets/section_title.dart';
import 'house_list.dart';

final RegExp _mobilePattern = RegExp(r'^1[3-9]\d{9}$');
const int _maxIdentityPhotoBytes = 8 * 1024 * 1024;
const Set<String> _allowedIdentityPhotoExtensions = <String>{
  'jpg',
  'jpeg',
  'png',
};

typedef HousePhotoPicker = Future<XFile?> Function(ImageSource source);

/// 身份证的两面，替代原来用字段名字符串当 tag 的写法。
enum _IdcardSide { front, back }

Future<XFile?> pickHousePhoto(ImageSource source) {
  return ImagePicker().pickImage(source: source);
}

/// 用选楼流程里已选中的小区、楼栋、房间初始化一份空白房屋表单。
House createHouseFormData(BuildController controller) {
  final buildingInfo = controller.buildingInfo;
  return House(
    point: buildingInfo.name,
    building: buildingInfo.building,
    room: buildingInfo.room,
    floor: buildingInfo.floor,
  );
}

String? _validateHouseSelection(House house) {
  if (house.point.trim().isEmpty ||
      house.building.trim().isEmpty ||
      house.room.trim().isEmpty) {
    return '小区、楼栋、房间不能为空';
  }
  return null;
}

String? _validateOwnerName(String? value) {
  final String name = value?.trim() ?? '';
  if (name.isEmpty) return '请输入姓名';
  if (!Validators.ownerNamePattern.hasMatch(name)) return '姓名格式不正确';
  return null;
}

String? _validateMobile(String? value) {
  final String mobile = value?.trim() ?? '';
  if (mobile.isEmpty) return '请输入手机号';
  if (!_mobilePattern.hasMatch(mobile)) return '手机号格式不正确';
  return null;
}

/// 校验房屋表单，返回第一条错误提示；全部通过时返回 null。
String? validateHouseFormData(House house) {
  // 逐项 trim：选楼流程和详情接口都可能带回只含空白的字段。
  final String? selectionError = _validateHouseSelection(house);
  if (selectionError != null) return selectionError;

  final String? nameError = _validateOwnerName(house.name);
  if (nameError != null) return nameError;

  final String? mobileError = _validateMobile(house.mobile);
  if (mobileError != null) return mobileError;

  if (house.idcardFrontUrl.trim().isEmpty ||
      house.idcardBackUrl.trim().isEmpty) {
    return '请上传身份证正反面照片';
  }

  return null;
}

class HouseForm extends StatefulWidget {
  const HouseForm({
    this.photoPicker = pickHousePhoto,
    this.uploadPhotoLoader = uploadPhotoAPI,
    this.submitHouseLoader = submitHouseAPI,
    this.houseDetailLoader = getHouseEditDetailApi,
    this.userInfoLoader = getUserInfoApi,
    this.submissionLoader = getHouseSubmissionApi,
    this.submissionCloser = closeHouseSubmissionApi,
    this.submissionStore,
    this.draftId,
    super.key,
  });

  static const String routeName = houseForm;

  final HousePhotoPicker photoPicker;
  final UploadPhotoLoader uploadPhotoLoader;
  final SubmitHouseLoader submitHouseLoader;
  final HouseDetailLoader houseDetailLoader;
  final UserInfoLoader userInfoLoader;
  final Future<HouseSubmissionResult> Function(String) submissionLoader;
  final Future<HouseSubmissionResult> Function(String) submissionCloser;
  final HouseSubmissionStore? submissionStore;
  final String? draftId;

  @override
  State<HouseForm> createState() => _HouseFormState();
}

class _HouseFormState extends State<HouseForm> {
  late final BuildController _controller;
  final int _session = tokenManager.sessionId;
  String? _draftId;
  bool get _active =>
      mounted &&
      tokenManager.sessionId == _session &&
      (_draftId == null || _controller.draftFor(_draftId!) != null);
  late House _house;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _mobileController = TextEditingController();
  String _idcardFrontPhotoPath = '';
  String _idcardBackPhotoPath = '';
  bool _isPickingImage = false;
  bool _isLoading = false;
  bool _isLoadingDetail = false;
  bool _hasEditConflict = false;
  bool _isConfirmingReload = false;
  bool _isLoadingSubmission = false;
  bool _submissionReady = false;
  bool _receiptResolved = false;
  String _owner = '';
  HouseSubmission? _pending;
  String? _submissionError;
  String? _pendingMessage;
  HouseSubmissionStore get _submissionStore =>
      widget.submissionStore ?? houseSubmissionStore;
  bool get _photoActionsBlocked =>
      _isPickingImage ||
      _isLoading ||
      _isLoadingDetail ||
      _isConfirmingReload ||
      (_houseId.isEmpty && (!_submissionReady || _pending != null));
  bool _showValidationErrors = false;
  bool _didReadRouteArguments = false;
  String _houseId = '';
  String? _detailErrorMessage;
  String? _ownerNameServerError;
  String? _rejectedOwnerName;

  String? _validateOwnerNameField(String? value) {
    final String? formatError = _validateOwnerName(value);
    if (formatError != null) return formatError;
    return value?.trim() == _rejectedOwnerName ? _ownerNameServerError : null;
  }

  @override
  void initState() {
    super.initState();
    _controller = BuildController.instance();
    _house = const House();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didReadRouteArguments) return;
    _didReadRouteArguments = true;

    final Object? arguments = ModalRoute.of(context)?.settings.arguments;
    if (arguments == null) {
      _restoreDraft(widget.draftId ?? _controller.currentDraftId);
      return;
    }

    final String id = switch (arguments) {
      String() => arguments.trim(),
      HouseFormArguments() => arguments.houseId?.trim() ?? '',
      Map<dynamic, dynamic>() => arguments['id']?.toString().trim() ?? '',
      _ => '',
    };
    if (arguments is HouseFormArguments && arguments.isCreate) {
      _restoreDraft(
          arguments.draftId ?? widget.draftId ?? _controller.currentDraftId);
      return;
    }
    if (id.isEmpty) {
      setState(() => _detailErrorMessage = '房屋参数不正确');
      return;
    }

    _houseId = id;
    unawaited(_loadHouseDetail());
  }

  void _restoreDraft(String id) {
    _draftId = id;
    _controller.resumeAt(id, HouseSelectionStep.owner);
    _house = _controller.houseFor(id);
    _nameController.text = _house.name;
    _mobileController.text = _house.mobile;
    _idcardFrontPhotoPath = _house.idcardFrontUrl;
    _idcardBackPhotoPath = _house.idcardBackUrl;
    unawaited(_loadSubmission());
  }

  Future<void> _loadSubmission() async {
    if (!_active || _isLoadingSubmission || _isLoading || _houseId.isNotEmpty) {
      return;
    }
    setState(() {
      _isLoadingSubmission = true;
      _submissionReady = false;
      _submissionError = null;
    });
    try {
      final user = await widget.userInfoLoader();
      if (!_active) return;
      if (user.id.trim().isEmpty) {
        throw const FormatException('账号信息缺少用户 ID，请重新加载');
      }
      final owner = user.id.trim();
      final pending = await _submissionStore.load(owner);
      if (!_active) return;
      setState(() {
        _owner = owner;
        _pending = pending;
        _submissionReady = true;
      });
    } on Object catch (error) {
      if (_active) {
        setState(() => _submissionError =
            describeError(error, fallback: '加载房屋提交回执失败，请重新加载'));
      }
    } finally {
      if (mounted) setState(() => _isLoadingSubmission = false);
    }
  }

  Future<bool> _clearSubmission() async {
    final pending = _pending;
    if (!_active || pending == null) return false;
    final removed = await _submissionStore.remove(_owner, pending.id);
    if (!_active) return false;
    if (!removed) throw const FormatException('本机房屋回执尚未清理，请再次查看提交结果');
    setState(() {
      _pending = null;
      _pendingMessage = null;
      _receiptResolved = false;
    });
    return true;
  }

  Future<void> _finishCreation({bool deleted = false}) async {
    final pending = _pending;
    if (!_active || pending == null) return;
    setState(() {
      _receiptResolved = true;
      _pendingMessage = deleted
          ? '原房屋已删除，本次提交不会重新创建；本机回执尚未清理。'
          : '房屋已创建，本机回执尚未清理；清理失败时请再次查看提交结果。';
    });
    if (!await _clearSubmission() || !_active) return;
    await AppPrompt.showSuccess(deleted ? '原房屋已删除，本次提交已处理' : '添加成功');
    if (!mounted || !_active) return;
    final original = _controller.draftFor(pending.draftId);
    if (original != null &&
        pending.matches(_controller.houseFor(pending.draftId))) {
      _controller.clearSelection(draftId: pending.draftId);
    }
    unawaited(Navigator.pushNamedAndRemoveUntil<void>(
        context, HouseList.routeName, (route) => false));
  }

  Future<void> _recoverSubmission(
      {bool retry = false, bool close = false}) async {
    final pending = _pending;
    if (_isLoading || !_active || pending == null) return;
    setState(() => _isLoading = true);
    try {
      if (retry || close) {
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
                  title: Text(close ? '停止本次提交' : '按原内容重试'),
                  content: Text(close
                      ? '已创建的房屋会找回原结果；未创建的提交将被停止，迟到请求不能再创建。此操作不会删除已有房屋。'
                      : '将使用已保存的房屋、业主和证件照片地址重试，不会另建一套房屋。'),
                  actions: <Widget>[
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('先不操作')),
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: Text(close ? '确认停止' : '确认重试')),
                  ],
                ));
        if (!_active || confirmed != true) return;
      }
      if (retry) {
        await widget.submitHouseLoader(pending.house);
        if (_active) await _finishCreation();
        return;
      }
      final result = await (close
          ? widget.submissionCloser
          : widget.submissionLoader)(pending.id);
      if (!_active) return;
      switch (result.state) {
        case HouseSubmissionState.created:
          await _finishCreation();
        case HouseSubmissionState.deleted:
          await _finishCreation(deleted: true);
        case HouseSubmissionState.closed:
          setState(() {
            _receiptResolved = true;
            _pendingMessage = '本次提交已停止，本机回执尚未清理。';
          });
          await _clearSubmission();
        case HouseSubmissionState.unknown:
          setState(() => _pendingMessage = '暂未查到结果，原请求可能仍在处理；可按原内容重试或停止本次提交。');
      }
    } on Object catch (error) {
      if (_active) {
        await AppPrompt.showException(error, fallback: '尚未确认提交结果，请保留回执后重试');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _saveDraft() {
    if (_active && _draftId != null) _controller.saveForm(_draftId!, _house);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _nameController.dispose();
    _mobileController.dispose();
    super.dispose();
  }

  Future<void> _loadHouseDetail() async {
    if (_isLoadingDetail ||
        _isLoading ||
        _isPickingImage ||
        _houseId.isEmpty ||
        !_active) {
      return;
    }

    setState(() {
      _isLoadingDetail = true;
      _detailErrorMessage = null;
    });
    try {
      final House detail = await widget.houseDetailLoader(_houseId);
      if (!_active) return;

      setState(() {
        // 详情接口不返回 id 时以路由参数为准，避免提交时退化成“新增”。
        _house = detail.copyWith(id: _houseId);
        _nameController.text = detail.name;
        _mobileController.text = detail.mobile;
        _idcardFrontPhotoPath = detail.idcardFrontUrl;
        _idcardBackPhotoPath = detail.idcardBackUrl;
        _hasEditConflict = false;
        _ownerNameServerError = null;
        _rejectedOwnerName = null;
        _showValidationErrors = false;
      });
    } on Object catch (error) {
      final String msg = describeError(
        error,
        fallback: '获取房屋详情失败，请重试',
      );
      if (!_active) return;
      setState(() => _detailErrorMessage = msg);
      await AppPrompt.showError(msg);
    } finally {
      if (mounted) setState(() => _isLoadingDetail = false);
    }
  }

  Future<void> _reloadLatestHouse() async {
    if (_photoActionsBlocked || !_hasEditConflict || !_active) return;
    setState(() => _isConfirmingReload = true);
    try {
      final bool? replace = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('重新加载最新资料'),
          content:
              const Text('重新加载成功后，当前填写的姓名、手机号、性别和照片将替换为服务器上的最新资料，请重新核对后提交。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('保留当前填写'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('替换为最新资料'),
            ),
          ],
        ),
      );
      if (!mounted || !_active || replace != true) return;
      FocusScope.of(context).unfocus();
      await _loadHouseDetail();
    } finally {
      if (mounted) setState(() => _isConfirmingReload = false);
    }
  }

  Future<void> _submit() async {
    if (_photoActionsBlocked || _hasEditConflict || !_active) return;

    final String? selectionError = _validateHouseSelection(_house);
    if (selectionError != null) {
      await AppPrompt.showWarning(selectionError);
      return;
    }
    if (_validateOwnerNameField(_house.name) != null ||
        _validateMobile(_house.mobile) != null) {
      setState(() => _showValidationErrors = true);
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      return;
    }

    final String? validationMessage = validateHouseFormData(_house);
    if (validationMessage != null) {
      await AppPrompt.showWarning(validationMessage);
      return;
    }

    setState(() => _isLoading = true);
    final House submittingHouse = _house.copyWith(
      name: _house.name.trim(),
      mobile: _house.mobile.trim(),
    );
    try {
      if (_houseId.isEmpty) {
        final pending =
            HouseSubmissionStore.prepare(submittingHouse, draftId: _draftId!);
        final saved = await _submissionStore.save(_owner, pending);
        if (!_active) return;
        if (!saved) {
          setState(() {
            _submissionReady = false;
            _submissionError = '提交回执未能保存，本次尚未发送，请重新加载';
          });
          return;
        }
        setState(() {
          _pending = pending;
          _pendingMessage = null;
        });
        await widget.submitHouseLoader(pending.house);
        if (_active) await _finishCreation();
        return;
      }
      await widget.submitHouseLoader(submittingHouse);
      if (!_active) return;

      await AppPrompt.showSuccess(
        _houseId.isEmpty ? '添加成功' : '修改成功',
      );
      if (!mounted || !_active) return;

      if (_houseId.isNotEmpty) {
        // 编辑路径不清选楼上下文：用户可能是从「添加房屋」流程点进来的，
        // 这份小区/楼栋/房间还要接着用。
        Navigator.pop(context, true);
        return;
      }
    } on Object catch (error) {
      if (!_active) return;
      if (_houseId.isEmpty) {
        if (_pending != null && isDefiniteRequestRejection(error)) {
          try {
            if (!await _clearSubmission()) return;
          } on Object {
            if (!_active) return;
            await AppPrompt.showWarning('请求已明确失败，但本机回执尚未清理；请重新查看提交结果');
            return;
          }
          if (!_active) return;
          if (error is BusinessException && error.code == 40002 &&
              _nameController.text.trim() == submittingHouse.name) {
            final String message = describeError(error, fallback: '姓名已被登记');
            setState(() {
              _ownerNameServerError = message;
              _rejectedOwnerName = submittingHouse.name;
              _showValidationErrors = true;
            });
            if (_scrollController.hasClients) _scrollController.jumpTo(0);
            return;
          }
          await AppPrompt.showException(error, fallback: '添加房屋失败，请重试');
          return;
        }
        if (_pending == null) {
          setState(() {
            _submissionReady = false;
            _submissionError = describeError(error, fallback: '提交回执保存失败，请重新加载');
          });
        }
        await AppPrompt.showException(error, fallback: '尚未确认房屋提交结果，请保留回执后重试');
        return;
      }
      final String msg = describeError(
        error,
        fallback: _houseId.isEmpty ? '添加房屋失败，请重试' : '修改房屋失败，请重试',
      );
      if (_houseId.isNotEmpty &&
          ((error is NetworkException && error.statusCode == 409) ||
              (error is BusinessException && error.code == 40900))) {
        setState(() {
          _hasEditConflict = true;
          _detailErrorMessage = null;
        });
        if (_scrollController.hasClients) _scrollController.jumpTo(0);
      }
      if (error is BusinessException && error.code == 40002) {
        if (mounted && _nameController.text.trim() == submittingHouse.name) {
          setState(() {
            _ownerNameServerError = msg;
            _rejectedOwnerName = submittingHouse.name;
            _showValidationErrors = true;
          });
          if (_scrollController.hasClients) _scrollController.jumpTo(0);
        }
        return;
      }
      await AppPrompt.showError(msg);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _goToHouseSelection() async {
    if (!_active) return;
    // 直达房屋表单时替换当前空表单，避免完成选择后又返回到这份无效页面。
    await Navigator.pushReplacementNamed<void, void>(
      context,
      locationList,
      arguments:
          HouseSelectionArguments(_draftId ?? _controller.currentDraftId),
    );
  }

  Future<void> _showIdcardPhotoOptions(_IdcardSide side) async {
    if (_photoActionsBlocked || !_active) return;

    await showCameraDialog(
      context,
      onOpenGallery: () => _pickIdcardPhoto(side, ImageSource.gallery),
      onOpenCamera: () => _pickIdcardPhoto(side, ImageSource.camera),
    );
  }

  /// 读取当前已保存的证件照地址。
  String _idcardUrl(_IdcardSide side) {
    return switch (side) {
      _IdcardSide.front => _house.idcardFrontUrl,
      _IdcardSide.back => _house.idcardBackUrl,
    };
  }

  /// 更新证件照地址与本地预览路径，两者始终一起变化。
  void _setIdcardPhoto(_IdcardSide side, {String? url, String? photoPath}) {
    setState(() {
      switch (side) {
        case _IdcardSide.front:
          if (url != null) _house = _house.copyWith(idcardFrontUrl: url);
          if (photoPath != null) _idcardFrontPhotoPath = photoPath;
        case _IdcardSide.back:
          if (url != null) _house = _house.copyWith(idcardBackUrl: url);
          if (photoPath != null) _idcardBackPhotoPath = photoPath;
      }
    });
    _saveDraft();
  }

  Future<void> _pickIdcardPhoto(_IdcardSide side, ImageSource source) async {
    if (_photoActionsBlocked || !_active) return;

    setState(() => _isPickingImage = true);
    final AppLocalizations l10n = AppLocalizations.of(context)!;
    try {
      final XFile? photo = await widget.photoPicker(source);
      if (photo == null || !_active) {
        return;
      }

      final String photoPath = photo.path.trim();
      if (photoPath.isEmpty) {
        throw const FormatException('所选图片路径为空');
      }
      final String fileName = _getPhotoFileName(photo);
      final String extension =
          fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
      if (!_allowedIdentityPhotoExtensions.contains(extension)) {
        throw FormatException(
          l10n.idPhotoFormatError,
        );
      }
      final Uint8List fileBytes = await photo.readAsBytes();
      if (fileBytes.isEmpty) {
        throw const FormatException('所选图片内容为空');
      }
      if (fileBytes.length > _maxIdentityPhotoBytes) {
        throw FormatException(l10n.idPhotoTooLarge);
      }
      if (!_active) return;

      _setIdcardPhoto(side, photoPath: photoPath);

      final String photoUrl = await widget.uploadPhotoLoader(
        fileBytes: fileBytes,
        fileName: fileName,
      );
      if (!_active) return;
      _setIdcardPhoto(side, url: photoUrl);
    } on Object catch (error) {
      if (!_active) return;
      if (mounted) {
        // 上传失败时回退到已保存的图片地址，避免界面留着一张没上传成功的本地图。
        _setIdcardPhoto(side, photoPath: _idcardUrl(side));
      }
      final String msg = describeError(error, fallback: '上传图片失败，请重试');
      await AppPrompt.showError(msg);
    } finally {
      if (mounted) setState(() => _isPickingImage = false);
    }
  }

  String _getPhotoFileName(XFile photo) {
    final String fileName =
        photo.name.trim().replaceAll('\\', '/').split('/').last;
    if (fileName.isNotEmpty) {
      return fileName;
    }

    final String pathName = photo.path.replaceAll('\\', '/').split('/').last;
    return pathName.isEmpty ? 'photo.jpg' : pathName;
  }

  void _clearIdcardPhoto(_IdcardSide side) {
    if (_photoActionsBlocked || !_active) return;
    _setIdcardPhoto(side, url: '', photoPath: '');
  }

  Widget _buildAddIdcardPhoto(_IdcardSide side, String info) {
    return Semantics(
      button: true,
      label: info,
      child: InkWell(
        onTap:
            _photoActionsBlocked ? null : () => _showIdcardPhotoOptions(side),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.add, size: 30, color: AppColors.primary),
              Text(info, style: const TextStyle(color: AppColors.primary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIdcardPhoto(_IdcardSide side, String photoPath) {
    return Stack(
      children: <Widget>[
        Semantics(
          button: true,
          label: '点击查看大图',
          child: InkWell(
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => ImagePreview(child: _buildPhoto(photoPath)),
            ),
            child: _buildPhoto(photoPath),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            tooltip: '删除照片',
            onPressed:
                _photoActionsBlocked ? null : () => _clearIdcardPhoto(side),
          ),
        ),
      ],
    );
  }

  Widget _buildPhoto(String photoPath) {
    return _isNetworkPhotoPath(photoPath)
        ? _buildNetworkPhoto(photoPath)
        : buildLocalImage(photoPath, fit: BoxFit.contain);
  }

  Widget _buildIdcardPhotoSection(
    _IdcardSide side,
    String info,
    String photoPath,
  ) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(10),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
          child: photoPath.isEmpty
              ? AspectRatio(
                  aspectRatio: 4 / 3,
                  child: _buildAddIdcardPhoto(side, info),
                )
              : _buildIdcardPhoto(side, photoPath),
        ),
      ),
    );
  }

  bool _isNetworkPhotoPath(String photoPath) {
    final String scheme = Uri.tryParse(photoPath)?.scheme.toLowerCase() ?? '';
    return scheme == 'http' || scheme == 'https';
  }

  Widget _buildNetworkPhoto(String photoPath) {
    return CachedImage(
      imageUrl: photoPath,
      fit: BoxFit.contain,
      errorWidget: const Center(
        child: Icon(Icons.broken_image_outlined, color: Colors.grey, size: 42),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => HouseDraftGuard(
      draftId: _draftId, sessionId: _session, child: _buildPage(context));

  Widget _buildPage(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(_houseId.isEmpty ? '添加房屋信息' : '修改房屋信息'),
        actions: <Widget>[
          if (_houseId.isEmpty)
            HouseDraftActions(
                enabled:
                    !_isLoading && !_isPickingImage && !_isLoadingSubmission),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final pending = _pending;
    if (_houseId.isEmpty && pending != null) {
      return ListView(padding: const EdgeInsets.all(16), children: <Widget>[
        const Text('当前账号有一份待确认的房屋提交，确认结果前不能再提交新的房屋；其他选房草稿仍会保留。'),
        const SizedBox(height: 12),
        Text(pending.house.fullName),
        Text('业主：${pending.house.name}'),
        Text('手机号：${pending.house.mobile}'),
        const Text('重试将沿用已保存的两面证件照片。'),
        if (_pendingMessage != null) Text(_pendingMessage!),
        if (_isLoading) const LinearProgressIndicator(),
        FilledButton(
            onPressed: _isLoading ? null : _recoverSubmission,
            child: const Text('查看提交结果')),
        OutlinedButton(
            onPressed: _isLoading || _receiptResolved
                ? null
                : () => _recoverSubmission(retry: true),
            child: const Text('按原内容重试')),
        TextButton(
            onPressed:
                _isLoading ? null : () => _recoverSubmission(close: true),
            child: const Text('停止本次提交')),
      ]);
    }
    if (_houseId.isEmpty && !_submissionReady) {
      return Center(
          child: _isLoadingSubmission
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(_submissionError ?? '房屋提交回执尚未就绪',
                        textAlign: TextAlign.center),
                    TextButton(
                        onPressed: _loadSubmission, child: const Text('重新加载')),
                  ],
                ));
    }
    if (_isLoadingDetail && !_hasEditConflict) {
      return const Center(child: CircularProgressIndicator());
    }

    final String? detailErrorMessage = _detailErrorMessage;
    if (detailErrorMessage != null && !_hasEditConflict) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                detailErrorMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red),
              ),
              if (_houseId.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _loadHouseDetail,
                  child: const Text('重新加载'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final String houseLabel = <String>[
      _house.building,
      _house.floorLabel,
      _house.room,
    ].where((String value) => value.isNotEmpty).join(' ');
    final bool hasCompleteHouseSelection = _house.point.trim().isNotEmpty &&
        _house.building.trim().isNotEmpty &&
        _house.room.trim().isNotEmpty;
    final bool canSelectHouse = _houseId.isEmpty && !hasCompleteHouseSelection;

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.only(top: 10, bottom: 10),
      children: <Widget>[
        if (_hasEditConflict)
          Card(
            margin: const EdgeInsets.all(10),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('房屋资料或审核状态已更新，当前填写内容已保留；重新加载并核对后才能提交。'),
                  if (detailErrorMessage != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(detailErrorMessage,
                        style: const TextStyle(color: Colors.red)),
                  ],
                  if (_isLoadingDetail) const LinearProgressIndicator(),
                  TextButton(
                    onPressed: _photoActionsBlocked ? null : _reloadLatestHouse,
                    child: const Text('重新加载最新资料'),
                  ),
                ],
              ),
            ),
          ),
        const SectionTitle('房屋信息'),
        Material(
          color: Colors.white,
          child: InkWell(
            onTap: canSelectHouse ? _goToHouseSelection : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 15,
              ),
              child: SizedBox(
                width: double.infinity,
                child: hasCompleteHouseSelection
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            _house.point,
                            style: const TextStyle(fontSize: 16),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            houseLabel,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 14,
                            ),
                          ),
                          if (_houseId.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 6),
                            Text('审核状态：${_house.statusText}'),
                            if (_house.reviewReason.isNotEmpty)
                              Text('打回原因：${_house.reviewReason}'),
                          ],
                        ],
                      )
                    : const Text(
                        '未选择房屋',
                        style: TextStyle(fontSize: 16),
                      ),
              ),
            ),
          ),
        ),
        const SectionTitle('业主信息'),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: TextFormField(
            controller: _nameController,
            enabled: !_photoActionsBlocked,
            maxLength: 15,
            onChanged: (String value) {
              _house = _house.copyWith(name: value);
              _saveDraft();
              if (_ownerNameServerError != null) {
                setState(() {
                  _ownerNameServerError = null;
                  _rejectedOwnerName = null;
                });
              }
            },
            decoration: const InputDecoration(
              labelText: '姓名',
              hintText: '请输入姓名',
              hintStyle: TextStyle(color: Colors.grey),
              border: InputBorder.none,
            ),
            autovalidateMode: _showValidationErrors
                ? AutovalidateMode.always
                : AutovalidateMode.onUnfocus,
            validator: _validateOwnerNameField,
            inputFormatters: <TextInputFormatter>[
              LengthLimitingTextInputFormatter(15),
            ],
          ),
        ),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: RadioGroup<int>(
            groupValue: _house.gender,
            onChanged: (int? value) {
              if (value == null || _photoActionsBlocked || !_active) return;
              setState(() => _house = _house.copyWith(gender: value));
              _saveDraft();
            },
            child: const Row(
              children: <Widget>[
                Text('性别', style: TextStyle(fontSize: 16)),
                SizedBox(width: 20),
                Radio<int>(value: 1),
                Text('男'),
                SizedBox(width: 10),
                Radio<int>(value: 0),
                Text('女'),
              ],
            ),
          ),
        ),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: TextFormField(
            controller: _mobileController,
            enabled: !_photoActionsBlocked,
            keyboardType: TextInputType.phone,
            maxLength: 11,
            onChanged: (String value) {
              _house = _house.copyWith(mobile: value);
              _saveDraft();
            },
            decoration: const InputDecoration(
              labelText: '手机号',
              hintText: '请输入手机号',
              hintStyle: TextStyle(color: Colors.grey),
              border: InputBorder.none,
            ),
            autovalidateMode: _showValidationErrors
                ? AutovalidateMode.always
                : AutovalidateMode.onUnfocus,
            validator: _validateMobile,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(11),
            ],
          ),
        ),
        const SectionTitle('本人身份证照片'),
        const Padding(
          padding: EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: Text(
            '请拍摄证件原件，并使照片中证件边缘完整，文字清晰，光线均匀。',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ),
        _buildIdcardPhotoSection(
          _IdcardSide.front,
          '上传人像面照片',
          _idcardFrontPhotoPath,
        ),
        const SizedBox(height: 20),
        _buildIdcardPhotoSection(
          _IdcardSide.back,
          '上传国徽面照片',
          _idcardBackPhotoPath,
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.all(10),
          child: SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed:
                  _photoActionsBlocked || _hasEditConflict ? null : _submit,
              icon: const Icon(Icons.exit_to_app),
              label: const Text('提交审核'),
            ),
          ),
        ),
      ],
    );
  }
}
