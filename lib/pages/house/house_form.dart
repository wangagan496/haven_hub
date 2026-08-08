import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../api/house.dart';
import '../../controller/build_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../models/house.dart';
import '../../platform/local_image.dart'
    if (dart.library.io) '../../platform/local_image_io.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/toast.dart';
import '../../widgets/cached_image.dart';
import '../../widgets/camera_dialog.dart';
import '../../widgets/section_title.dart';
import 'house_list.dart';

final RegExp _ownerNamePattern = RegExp(r'^[\u4e00-\u9fa5]{2,15}$');
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
  );
}

/// 校验房屋表单，返回第一条错误提示；全部通过时返回 null。
String? validateHouseFormData(House house) {
  // 逐项 trim：选楼流程和详情接口都可能带回只含空白的字段。
  if (house.point.trim().isEmpty ||
      house.building.trim().isEmpty ||
      house.room.trim().isEmpty) {
    return '小区、楼栋、房间不能为空';
  }

  final String name = house.name.trim();
  if (name.isEmpty) {
    return '业主姓名不能为空';
  }
  if (!_ownerNamePattern.hasMatch(name)) {
    return '业主姓名须为2-15位中文';
  }

  final String mobile = house.mobile.trim();
  if (mobile.isEmpty) {
    return '手机号不能为空';
  }
  if (!_mobilePattern.hasMatch(mobile)) {
    return '手机号格式不正确';
  }

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
    this.houseDetailLoader = getHouseDetailApi,
    super.key,
  });

  static const String routeName = AppRoutes.houseForm;

  final HousePhotoPicker photoPicker;
  final UploadPhotoLoader uploadPhotoLoader;
  final SubmitHouseLoader submitHouseLoader;
  final HouseDetailLoader houseDetailLoader;

  @override
  State<HouseForm> createState() => _HouseFormState();
}

class _HouseFormState extends State<HouseForm> {
  late final BuildController _controller;
  late House _house;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _mobileController = TextEditingController();
  String _idcardFrontPhotoPath = '';
  String _idcardBackPhotoPath = '';
  bool _isPickingImage = false;
  bool _isLoading = false;
  bool _isLoadingDetail = false;
  bool _didReadRouteArguments = false;
  String _houseId = '';
  String? _detailErrorMessage;

  @override
  void initState() {
    super.initState();
    _controller = BuildController.instance();
    _house = createHouseFormData(_controller);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didReadRouteArguments) return;
    _didReadRouteArguments = true;

    final Object? arguments = ModalRoute.of(context)?.settings.arguments;
    if (arguments == null) return;

    final String id = switch (arguments) {
      String() => arguments.trim(),
      HouseFormArguments() => arguments.houseId?.trim() ?? '',
      Map<dynamic, dynamic>() => arguments['id']?.toString().trim() ?? '',
      _ => '',
    };
    if (arguments is HouseFormArguments && arguments.isCreate) return;
    if (id.isEmpty) {
      setState(() => _detailErrorMessage = '房屋参数不正确');
      return;
    }

    _houseId = id;
    unawaited(_loadHouseDetail());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _mobileController.dispose();
    super.dispose();
  }

  Future<void> _loadHouseDetail() async {
    if (_isLoadingDetail || _houseId.isEmpty) return;

    setState(() {
      _isLoadingDetail = true;
      _detailErrorMessage = null;
    });
    try {
      final House detail = await widget.houseDetailLoader(_houseId);
      if (!mounted) return;

      setState(() {
        // 详情接口不返回 id 时以路由参数为准，避免提交时退化成“新增”。
        _house = detail.copyWith(id: _houseId);
        _nameController.text = detail.name;
        _mobileController.text = detail.mobile;
        _idcardFrontPhotoPath = detail.idcardFrontUrl;
        _idcardBackPhotoPath = detail.idcardBackUrl;
      });
    } on Object catch (error) {
      final String msg = describeError(
        error,
        fallback: '获取房屋详情失败，请重试',
      );
      if (!mounted) return;
      setState(() => _detailErrorMessage = msg);
      await PromptAction.showError(msg);
    } finally {
      if (mounted) setState(() => _isLoadingDetail = false);
    }
  }

  Future<void> _submit() async {
    if (_isLoading) return;

    final String? validationMessage = validateHouseFormData(_house);
    if (validationMessage != null) {
      await PromptAction.showWarning(validationMessage);
      return;
    }

    setState(() => _isLoading = true);
    try {
      await widget.submitHouseLoader(
        _house.copyWith(
          name: _house.name.trim(),
          mobile: _house.mobile.trim(),
        ),
      );
      if (!mounted) return;

      await PromptAction.showSuccess(
        _houseId.isEmpty ? '添加成功' : '修改成功',
      );
      if (!mounted) return;

      _controller.clearBuildingInfo();
      if (_houseId.isNotEmpty) {
        Navigator.pop(context, true);
        return;
      }

      unawaited(
        Navigator.pushNamedAndRemoveUntil<void>(
          context,
          HouseList.routeName,
          (Route<dynamic> route) => false,
        ),
      );
    } on Object catch (error) {
      final String msg = describeError(
        error,
        fallback: _houseId.isEmpty ? '添加房屋失败，请重试' : '修改房屋失败，请重试',
      );
      await PromptAction.showError(msg);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _showIdcardPhotoOptions(_IdcardSide side) async {
    if (_isPickingImage) return;

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
  }

  Future<void> _pickIdcardPhoto(_IdcardSide side, ImageSource source) async {
    if (_isPickingImage) return;

    setState(() => _isPickingImage = true);
    final AppLocalizations l10n = AppLocalizations.of(context)!;
    try {
      final XFile? photo = await widget.photoPicker(source);
      if (photo == null || !mounted) {
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
      if (!mounted) return;

      _setIdcardPhoto(side, photoPath: photoPath);

      final String photoUrl = await widget.uploadPhotoLoader(
        fileBytes: fileBytes,
        fileName: fileName,
      );
      if (!mounted) return;
      _setIdcardPhoto(side, url: photoUrl);
    } on Object catch (error) {
      if (mounted) {
        // 上传失败时回退到已保存的图片地址，避免界面留着一张没上传成功的本地图。
        _setIdcardPhoto(side, photoPath: _idcardUrl(side));
      }
      final String msg = describeError(error, fallback: '上传图片失败，请重试');
      await PromptAction.showError(msg);
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
    _setIdcardPhoto(side, url: '', photoPath: '');
  }

  Widget _buildAddIdcardPhoto(_IdcardSide side, String info) {
    return Semantics(
      button: true,
      label: info,
      child: InkWell(
        onTap: _isPickingImage ? null : () => _showIdcardPhotoOptions(side),
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
        SizedBox(
          width: double.infinity,
          height: 300,
          // Web 端 buildLocalImage 本身就是 Image.network，无需再判断 kIsWeb。
          child: _isNetworkPhotoPath(photoPath)
              ? _buildNetworkPhoto(photoPath)
              : buildLocalImage(photoPath, fit: BoxFit.contain),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            tooltip: '删除照片',
            onPressed: _isPickingImage ? null : () => _clearIdcardPhoto(side),
          ),
        ),
      ],
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(_houseId.isEmpty ? '添加房屋信息' : '修改房屋信息'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoadingDetail) {
      return const Center(child: CircularProgressIndicator());
    }

    final String? detailErrorMessage = _detailErrorMessage;
    if (detailErrorMessage != null) {
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
      _house.room,
    ].where((String value) => value.isNotEmpty).join(' ');

    return ListView(
      padding: const EdgeInsets.only(top: 10, bottom: 10),
      children: <Widget>[
        const SectionTitle('房屋信息'),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 15,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _house.point.isEmpty ? '尚未选择小区' : _house.point,
                style: const TextStyle(fontSize: 16),
              ),
              if (houseLabel.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  houseLabel,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SectionTitle('业主信息'),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: TextField(
            controller: _nameController,
            maxLength: 15,
            onChanged: (String value) => _house = _house.copyWith(name: value),
            decoration: const InputDecoration(
              labelText: '姓名',
              hintText: '请输入业主姓名',
              hintStyle: TextStyle(color: Colors.grey),
              border: InputBorder.none,
            ),
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
              if (value == null) return;
              setState(() => _house = _house.copyWith(gender: value));
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
          child: TextField(
            controller: _mobileController,
            keyboardType: TextInputType.phone,
            maxLength: 11,
            onChanged: (String value) =>
                _house = _house.copyWith(mobile: value),
            decoration: const InputDecoration(
              labelText: '手机号',
              hintText: '请输入您的手机号',
              hintStyle: TextStyle(color: Colors.grey),
              border: InputBorder.none,
            ),
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
        Container(
          color: Colors.white,
          height: 320,
          padding: const EdgeInsets.all(10),
          child: _idcardFrontPhotoPath.isEmpty
              ? _buildAddIdcardPhoto(
                  _IdcardSide.front,
                  '上传人像面照片',
                )
              : _buildIdcardPhoto(
                  _IdcardSide.front,
                  _idcardFrontPhotoPath,
                ),
        ),
        const SizedBox(height: 20),
        Container(
          color: Colors.white,
          height: 320,
          padding: const EdgeInsets.all(10),
          child: _idcardBackPhotoPath.isEmpty
              ? _buildAddIdcardPhoto(
                  _IdcardSide.back,
                  '上传国徽面照片',
                )
              : _buildIdcardPhoto(
                  _IdcardSide.back,
                  _idcardBackPhotoPath,
                ),
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.all(10),
          child: SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _isLoading ? null : _submit,
              icon: const Icon(Icons.exit_to_app),
              label: const Text('提交审核'),
            ),
          ),
        ),
      ],
    );
  }
}
