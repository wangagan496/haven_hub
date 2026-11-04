import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide FormData, MultipartFile;

import '../../api/user.dart';
import '../../controller/user_info_controller.dart';
import '../../models/user_info.dart';
import '../../platform/avatar_picker.dart';
import '../../router/app_routes.dart';
import '../../utils/toast.dart';
import '../../widgets/cached_image.dart';
import '../../widgets/camera_dialog.dart';

// 用户新选中、准备随个人资料一起保存的头像。
class _AvatarToSave {
  const _AvatarToSave({
    required this.bytes,
    required this.fileName,
    this.uploadedUrl,
  });

  final Uint8List bytes;
  final String fileName;
  final String? uploadedUrl;

  _AvatarToSave withUploadedUrl(String url) {
    return _AvatarToSave(
      bytes: bytes,
      fileName: fileName,
      uploadedUrl: url,
    );
  }
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({
    this.submitUserInfo = updateUserInfoApi,
    this.uploadAvatar = uploadAvatarApi,
    this.avatarPicker = pickAvatar,
    this.cameraSupported,
    super.key,
  });

  static const String routeName = profile;

  final SubmitUserInfoAction submitUserInfo;
  final UploadAvatarAction uploadAvatar;
  final AvatarPicker avatarPicker;
  final bool? cameraSupported;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  // 昵称规则：2～10个字符。
  static final RegExp _nicknameRule = RegExp(r'^.{2,10}$', unicode: true);

  // 负责读写昵称输入框里的文字。
  final TextEditingController _nicknameInput = TextEditingController();

  // 负责读取和更新当前用户的资料。
  late final UserInfoController _userInfoManager;
  _AvatarToSave? _newAvatarToSave;
  bool _isSaving = false;
  bool _isPickingAvatar = false;

  @override
  void initState() {
    super.initState();
    _userInfoManager = Get.find<UserInfoController>();
    // 把当前用户的昵称填进昵称输入框。
    _nicknameInput.text = _getCurrentUserNickname();
  }

  bool get _isBusy => _isSaving || _isPickingAvatar;

  bool get _supportsCamera => widget.cameraSupported ?? supportsAvatarCamera;

  String _getCurrentUserNickname() {
    return _userInfoManager.currentUser.nickName;
  }

  // 去掉文字两头的空格等空白字符，保留中间内容。
  String _removeOuterSpaces(String text) {
    return text.trim();
  }

  Widget _buildUserAvatar(UserInfoController controller) {
    final _AvatarToSave? avatarToPreview = _newAvatarToSave;
    if (avatarToPreview != null) {
      return Image.memory(
        avatarToPreview.bytes,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        errorBuilder: _buildAvatarError,
      );
    }

    final String avatar = controller.currentUser.avatarUrl;
    if (avatar.isNotEmpty) {
      return CachedImage(
        imageUrl: avatar,
        width: 40,
        height: 40,
        errorWidget: _buildDefaultAvatar(),
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
        _newAvatarToSave = _AvatarToSave(
          bytes: avatar.bytes,
          fileName: avatar.fileName,
        );
      });
    } on Object catch (error) {
      await AppPrompt.showException(error, fallback: '选择头像失败，请重试');
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

    final String nickName = _removeOuterSpaces(_nicknameInput.text);
    if (nickName.isEmpty) {
      await AppPrompt.showWarning('请填写昵称');
      return;
    }

    if (!_nicknameRule.hasMatch(nickName)) {
      await AppPrompt.showWarning('昵称须为2-10位字符');
      return;
    }

    setState(() {
      _isSaving = true;
    });
    try {
      String avatarUrl = _userInfoManager.currentUser.avatarUrl;
      final _AvatarToSave? avatarToSave = _newAvatarToSave;
      if (avatarToSave != null) {
        final String? uploadedAvatarUrl = avatarToSave.uploadedUrl;
        if (uploadedAvatarUrl != null) {
          // 已经上传过，直接使用保存下来的地址。
          avatarUrl = uploadedAvatarUrl;
        } else {
          // 还没有上传地址，先上传这张图片。
          avatarUrl = await widget.uploadAvatar(
            fileBytes: avatarToSave.bytes,
            fileName: avatarToSave.fileName,
          );
        }
        if (!mounted) {
          return;
        }
        // 记住上传地址，保存资料失败后重试时不用重复上传。
        _newAvatarToSave = avatarToSave.withUploadedUrl(avatarUrl);
      }

      // 把昵称和头像地址提交给服务器，等待保存结果。
      final Map<String, dynamic> userInfoSaveResult = await widget.submitUserInfo(
        nickName: nickName,
        avatar: avatarUrl,
      );
      if (!mounted) {
        return;
      }

      // 取出服务器返回的用户编号，再转成文字并去掉两头空白。
      final Object? returnedUserId = userInfoSaveResult['id'];
      String userId = '';
      if (returnedUserId != null) {
        final String userIdText = returnedUserId.toString();
        userId = _removeOuterSpaces(userIdText);
      }
      if (userId.isEmpty) {
        userId = _userInfoManager.currentUser.id;
      }

      // 服务器保存成功后，先整理资料，再更新应用里使用的用户信息。
      final UserInfo savedUserInfo = UserInfo(
        id: userId,
        avatarUrl: avatarUrl,
        nickName: nickName,
      );
      _userInfoManager.updateLocalUserInfo(savedUserInfo);
      _newAvatarToSave = null;

      await AppPrompt.showSuccess('修改成功');
      if (!mounted) {
        return;
      }
      await Navigator.maybePop(context);
    } on Object catch (error) {
      await AppPrompt.showException(error, fallback: '修改失败，请重试');
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
    _nicknameInput.dispose();
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
                        controller: _nicknameInput,
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
