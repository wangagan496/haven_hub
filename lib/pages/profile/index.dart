import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

import '../../api/user.dart';
import '../../controller/user_info_controller.dart';
import '../../utils/app_exception.dart';
import '../../utils/toast.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({
    this.updateUserInfoLoader = updateUserInfoApi,
    this.uploadPhotoLoader = uploadPhotoApi,
    super.key,
  });

  static const String routeName = '/profile';

  final UpdateUserInfoLoader updateUserInfoLoader;
  final UploadPhotoLoader uploadPhotoLoader;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final TextEditingController _nicknameController = TextEditingController();
  final ImagePicker _imagePicker = ImagePicker();

  late final UserInfoController _userInfoController;
  XFile? _selectedAvatar;
  Uint8List? _selectedAvatarBytes;
  bool _isSaving = false;
  bool _isPickingAvatar = false;

  @override
  void initState() {
    super.initState();
    _userInfoController = Get.find<UserInfoController>();
    _nicknameController.text = getUserNickName();
  }

  String getUserNickName() {
    return _userInfoController.userInfo['nickName']?.toString().trim() ?? '';
  }

  Widget getUserAvatar(UserInfoController controller) {
    final Uint8List? selectedAvatarBytes = _selectedAvatarBytes;
    if (selectedAvatarBytes != null) {
      return Image.memory(
        selectedAvatarBytes,
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
    if (_isPickingAvatar || _isSaving) {
      return;
    }

    final List<Map<String, Object?>> getAvatarList = <Map<String, Object?>>[
      <String, Object?>{
        'name': '拍照',
        'icon': const Icon(Icons.camera_alt),
        'source': ImageSource.camera,
      },
      <String, Object?>{
        'name': '相册',
        'icon': const Icon(Icons.photo_library),
        'source': ImageSource.gallery,
      },
      <String, Object?>{
        'name': '取消',
        'icon': const Icon(Icons.cancel),
        'source': null,
      },
    ];

    final ImageSource? selectedSource = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemBuilder: (BuildContext context, int index) {
              final Map<String, Object?> item = getAvatarList[index];
              final ImageSource? source = item['source'] as ImageSource?;
              return InkWell(
                onTap: () {
                  Navigator.pop<ImageSource>(sheetContext, source);
                },
                child: SizedBox(
                  height: 56,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      item['icon'] as Widget,
                      const SizedBox(width: 8),
                      Text(item['name'] as String),
                    ],
                  ),
                ),
              );
            },
            separatorBuilder: (BuildContext context, int index) {
              return const Divider(height: 1);
            },
            itemCount: getAvatarList.length,
          ),
        );
      },
    );

    if (!mounted || selectedSource == null) {
      return;
    }
    await _pickAvatar(selectedSource);
  }

  Future<void> _pickAvatar(ImageSource source) async {
    if (_isPickingAvatar || _isSaving) {
      return;
    }

    setState(() {
      _isPickingAvatar = true;
    });
    try {
      final XFile? file = await _imagePicker.pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (file == null) {
        return;
      }

      final Uint8List bytes = await file.readAsBytes();
      if (!mounted) {
        return;
      }
      if (bytes.isEmpty) {
        throw const FormatException('所选图片内容为空');
      }

      setState(() {
        _selectedAvatar = file;
        _selectedAvatarBytes = bytes;
      });
    } on Object catch (error) {
      final String msg = switch (error) {
        BusinessException() => error.message,
        NetworkException() => error.message,
        FormatException() => error.message,
        _ => '选择头像失败，请重试',
      };
      await PromptAction.showError(msg);
    } finally {
      if (mounted) {
        setState(() {
          _isPickingAvatar = false;
        });
      }
    }
  }

  Future<void> _saveUserInfo() async {
    if (_isSaving) {
      return;
    }

    final String nickName = _nicknameController.text.trim();
    if (nickName.isEmpty) {
      await PromptAction.showWarning('请填写昵称');
      return;
    }

    final RegExp nickNameRegExp = RegExp(r'^.{2,10}$', unicode: true);
    if (!nickNameRegExp.hasMatch(nickName)) {
      await PromptAction.showWarning('昵称须为2-10位字符');
      return;
    }

    setState(() {
      _isSaving = true;
    });
    try {
      String avatar =
          _userInfoController.userInfo['avatar']?.toString().trim() ?? '';
      final XFile? selectedAvatar = _selectedAvatar;
      final Uint8List? selectedAvatarBytes = _selectedAvatarBytes;
      if (selectedAvatar != null && selectedAvatarBytes != null) {
        avatar = await widget.uploadPhotoLoader(
          fileBytes: selectedAvatarBytes,
          fileName: selectedAvatar.name,
        );
        if (!mounted) {
          return;
        }

        _selectedAvatar = null;
        _selectedAvatarBytes = null;
      }

      final Map<String, dynamic> result =
          await widget.updateUserInfoLoader(nickName);
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

      await PromptAction.showSuccess('修改成功');
      if (!mounted) {
        return;
      }
      Navigator.maybePop(context);
    } on Object catch (error) {
      final String msg = switch (error) {
        BusinessException() => error.message,
        NetworkException() => error.message,
        FormatException() => error.message,
        _ => '修改失败，请重试',
      };
      await PromptAction.showError(msg);
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
                  onTap: _isSaving ? null : _showAvatarOptions,
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
                        ClipOval(child: getUserAvatar(controller)),
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
                        enabled: !_isSaving,
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
                onPressed: _isSaving ? null : _saveUserInfo,
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
