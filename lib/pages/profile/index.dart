import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide FormData, MultipartFile;

import '../../api/user.dart';
import '../../controller/user_info_controller.dart';
import '../../platform/avatar_picker.dart';
import '../../widgets/camera_dialog.dart';
import '../../utils/app_exception.dart';
import '../../utils/toast.dart';

class _PendingAvatar {
  const _PendingAvatar({
    required this.bytes,
    required this.fileName,
    this.uploadedUrl,
  });

  final Uint8List bytes;
  final String fileName;
  final String? uploadedUrl;

  _PendingAvatar withUploadedUrl(String url) {
    return _PendingAvatar(
      bytes: bytes,
      fileName: fileName,
      uploadedUrl: url,
    );
  }
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({
    this.updateUserInfoLoader = updateUserInfoApi,
    this.uploadAvatarLoader = uploadAvatarApi,
    this.avatarPicker = pickAvatar,
    this.cameraSupported,
    super.key,
  });

  static const String routeName = '/profile';

  final UpdateUserInfoLoader updateUserInfoLoader;
  final UploadAvatarLoader uploadAvatarLoader;
  final AvatarPicker avatarPicker;
  final bool? cameraSupported;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  static final RegExp _nicknamePattern = RegExp(r'^.{2,10}$', unicode: true);

  final TextEditingController _nicknameController = TextEditingController();

  late final UserInfoController _userInfoController;
  _PendingAvatar? _pendingAvatar;
  bool _isSaving = false;
  bool _isPickingAvatar = false;

  @override
  void initState() {
    super.initState();
    _userInfoController = Get.find<UserInfoController>();
    _nicknameController.text = _getUserNickname();
  }

  bool get _isBusy => _isSaving || _isPickingAvatar;

  bool get _supportsCamera => widget.cameraSupported ?? supportsAvatarCamera;

  String _getUserNickname() {
    return _userInfoController.userInfo['nickName']?.toString().trim() ?? '';
  }

  Widget _buildUserAvatar(UserInfoController controller) {
    final _PendingAvatar? pendingAvatar = _pendingAvatar;
    if (pendingAvatar != null) {
      return Image.memory(
        pendingAvatar.bytes,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        errorBuilder: _buildAvatarError,
      );
    }

    final String avatar =
        controller.userInfo['avatar']?.toString().trim() ?? '';
    if (avatar.isNotEmpty) {
      return Image.network(
        avatar,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        errorBuilder: _buildAvatarError,
      );
    }
    return _buildDefaultAvatar();
  }

  Widget _buildAvatarError(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) {
    return _buildDefaultAvatar();
  }

  Widget _buildDefaultAvatar() {
    return Image.asset(
      'assets/images/avatar_1.jpg',
      width: 40,
      height: 40,
      fit: BoxFit.cover,
    );
  }

  // 显示选择头像弹窗
  Future<void> _showAvatarOptions() async {
    if (_isBusy) {
      return;
    }

    await showCameraDialog(
      context,
      onOpenGallery: () => _pickAvatar(AvatarSource.gallery),
      onOpenCamera: () => _pickAvatar(AvatarSource.camera),
      showCameraOption: _supportsCamera,
    );
  }

  Future<void> _pickAvatar(AvatarSource source) async {
    if (_isBusy) {
      return;
    }

    setState(() {
      _isPickingAvatar = true;
    });
    try {
      final PickedAvatar? avatar = await widget.avatarPicker(source);
      if (avatar == null) {
        return;
      }

      if (!mounted) {
        return;
      }
      if (avatar.bytes.isEmpty) {
        throw const FormatException('所选图片内容为空');
      }

      setState(() {
        _pendingAvatar = _PendingAvatar(
          bytes: avatar.bytes,
          fileName: avatar.fileName,
        );
      });
    } on Object catch (error) {
      await PromptAction.showError(
        describeError(error, fallback: '选择头像失败，请重试'),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isPickingAvatar = false;
        });
      }
    }
  }

  Future<void> _saveUserInfo() async {
    if (_isBusy) {
      return;
    }

    final String nickName = _nicknameController.text.trim();
    if (nickName.isEmpty) {
      await PromptAction.showWarning('请填写昵称');
      return;
    }

    if (!_nicknamePattern.hasMatch(nickName)) {
      await PromptAction.showWarning('昵称须为2-10位字符');
      return;
    }

    setState(() {
      _isSaving = true;
    });
    try {
      String avatar =
          _userInfoController.userInfo['avatar']?.toString().trim() ?? '';
      final _PendingAvatar? pendingAvatar = _pendingAvatar;
      if (pendingAvatar != null) {
        avatar = pendingAvatar.uploadedUrl ??
            await widget.uploadAvatarLoader(
              fileBytes: pendingAvatar.bytes,
              fileName: pendingAvatar.fileName,
            );
        if (!mounted) {
          return;
        }
        _pendingAvatar = pendingAvatar.withUploadedUrl(avatar);
      }

      final Map<String, dynamic> result = await widget.updateUserInfoLoader(
        nickName: nickName,
        avatar: avatar,
      );
      if (!mounted) {
        return;
      }

      final String id = result['id']?.toString().trim() ?? '';
      _userInfoController.updateUserInfo(<String, dynamic>{
        ..._userInfoController.userInfo,
        'nickName': nickName,
        'avatar': avatar,
        if (id.isNotEmpty) 'id': id,
      });
      _pendingAvatar = null;

      await PromptAction.showSuccess('修改成功');
      if (!mounted) {
        return;
      }
      Navigator.maybePop(context);
    } on Object catch (error) {
      await PromptAction.showError(
        describeError(error, fallback: '修改失败，请重试'),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GetBuilder<UserInfoController>(
      builder: (UserInfoController controller) {
        return Scaffold(
          backgroundColor: Colors.white,
          appBar: AppBar(
            title: const Text('个人信息'),
            backgroundColor: Colors.transparent,
            centerTitle: true,
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Semantics(
                button: true,
                label: '修改头像',
                child: InkWell(
                  onTap: _isBusy ? null : _showAvatarOptions,
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    height: 56,
                    child: Row(
                      children: <Widget>[
                        const Text(
                          '头像',
                          style: TextStyle(fontSize: 16),
                        ),
                        const Spacer(),
                        ClipOval(child: _buildUserAvatar(controller)),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_forward_ios, size: 12),
                      ],
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              SizedBox(
                height: 56,
                child: Row(
                  children: <Widget>[
                    const Text('昵称', style: TextStyle(fontSize: 16)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: TextField(
                        controller: _nicknameController,
                        enabled: !_isBusy,
                        decoration: const InputDecoration(
                          hintText: '请输入昵称',
                          border: InputBorder.none,
                          counterText: '',
                        ),
                        maxLength: 10,
                        textAlign: TextAlign.right,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) async {
                          await _saveUserInfo();
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color.fromARGB(255, 85, 145, 175),
                  minimumSize: const Size.fromHeight(50),
                ),
                onPressed: _isBusy ? null : _saveUserInfo,
                child: _isSaving
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        '保存',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
