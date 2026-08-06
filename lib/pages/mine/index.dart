import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart' hide FormData, MultipartFile;

import '../../api/user.dart';
import '../../controller/user_info_controller.dart';
import '../../utils/app_exception.dart';
import '../../utils/emitter.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';
import '../house/house_list.dart';
import '../login/index.dart';
import '../profile/index.dart';

class MinePage extends StatefulWidget {
  const MinePage({
    this.activeIndex = 0,
    this.userInfoLoader = getUserInfoApi,
    super.key,
  });

  final int activeIndex;
  final UserInfoLoader userInfoLoader;

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  static const Color _backgroundColor = Color(0xFF5B9AB8);

  static const List<({String label, String icon, String? routeName})>
      _menuItems = <({String label, String icon, String? routeName})>[
    (
      label: '我的房屋',
      icon: 'assets/images/house_profile_icon@2x.png',
      routeName: HouseList.routeName,
    ),
    (
      label: '我的报修',
      icon: 'assets/images/repair_profile_icon@2x.png',
      routeName: null,
    ),
    (
      label: '访客记录',
      icon: 'assets/images/visitor_profile_icon@2x.png',
      routeName: null,
    ),
  ];

  bool _isLoggedIn = false;
  bool _isLoggingOut = false;
  bool _isLoadingUserInfo = false;
  late final UserInfoController _userInfoController;
  late final StreamSubscription<LoginSuccessEvent> _loginSubscription;
  late final StreamSubscription<RefreshEvent> _refreshSubscription;

  @override
  void initState() {
    super.initState();
    _userInfoController = Get.isRegistered<UserInfoController>()
        ? Get.find<UserInfoController>()
        : Get.put(UserInfoController(), permanent: true);
    _loginSubscription =
        eventBus.on<LoginSuccessEvent>().listen(_onLoginSuccess);
    _refreshSubscription = eventBus.on<RefreshEvent>().listen(_onRefresh);
    _isLoggedIn = tokenManager.getToken().isNotEmpty;
    if (!_isLoggedIn) {
      _userInfoController.clearUserInfo();
    } else if (widget.activeIndex == 1) {
      unawaited(_loadUserInfo());
    }
  }

  @override
  void dispose() {
    _loginSubscription.cancel();
    _refreshSubscription.cancel();
    super.dispose();
  }

  void _onLoginSuccess(LoginSuccessEvent event) {
    if (!mounted) {
      return;
    }

    setState(() {
      _isLoggedIn = true;
    });
    unawaited(_loadUserInfo());
  }

  void _onRefresh(RefreshEvent event) {
    if (!mounted) {
      return;
    }
    unawaited(_loadUserInfo());
  }

  @override
  void didUpdateWidget(covariant MinePage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.activeIndex != 1 && widget.activeIndex == 1) {
      _syncLoginStateBeforeBuild();
      unawaited(_loadUserInfo());
    }
  }

  void _syncLoginStateBeforeBuild() {
    final bool isLoggedIn = tokenManager.getToken().isNotEmpty;
    if (_isLoggedIn == isLoggedIn) {
      return;
    }

    _isLoggedIn = isLoggedIn;
    if (!isLoggedIn) {
      _userInfoController.clearUserInfo();
    }
  }

  Future<void> _loadUserInfo() async {
    if (_isLoadingUserInfo || !_isLoggedIn || tokenManager.getToken().isEmpty) {
      return;
    }

    _isLoadingUserInfo = true;
    try {
      final userInfo = await widget.userInfoLoader();
      if (!mounted || !_isLoggedIn || tokenManager.getToken().isEmpty) {
        return;
      }
      _userInfoController.updateUserInfo(<String, dynamic>{
        'nickName': userInfo.nickName,
        'avatar': userInfo.avatarUrl,
        'id': userInfo.id,
      });
    } on Object catch (error) {
      if (!mounted || widget.activeIndex != 1 || !_isLoggedIn) {
        return;
      }
      final String msg = describeError(error, fallback: '获取用户信息失败');
      await PromptAction.showError(msg);
    } finally {
      _isLoadingUserInfo = false;
    }
  }

  Widget _buildDefaultAvatar() {
    return Image.asset(
      'assets/images/avatar_2.jpg',
      width: 72,
      height: 72,
      fit: BoxFit.cover,
    );
  }

  Widget _buildUserAvatar() {
    final String avatar =
        _userInfoController.userInfo['avatar']?.toString() ?? '';
    if (_isLoggedIn && avatar.isNotEmpty) {
      return Image.network(
        avatar,
        width: 72,
        height: 72,
        fit: BoxFit.cover,
        errorBuilder:
            (BuildContext context, Object error, StackTrace? stackTrace) {
          return _buildDefaultAvatar();
        },
      );
    }
    return _buildDefaultAvatar();
  }

  String _getUserNickName() {
    final String nickName =
        _userInfoController.userInfo['nickName']?.toString() ?? '';
    if (nickName.isNotEmpty) {
      return nickName;
    }
    return '微信用户';
  }

  bool _hasLoggedInUser() {
    final String id = _userInfoController.userInfo['id']?.toString() ?? '';
    return id.isNotEmpty;
  }

  void _refreshLoginState() {
    final bool isLoggedIn = tokenManager.getToken().isNotEmpty;
    if (_isLoggedIn == isLoggedIn) {
      return;
    }

    setState(() {
      _isLoggedIn = isLoggedIn;
    });
    if (!isLoggedIn) {
      _userInfoController.clearUserInfo();
    }
  }

  Future<void> _openLogin() async {
    if (_isLoggedIn) {
      return;
    }

    await Navigator.pushNamed(context, LoginPage.routeName);
    if (!mounted) {
      return;
    }

    _refreshLoginState();
    if (_isLoggedIn) {
      await _loadUserInfo();
    }
  }

  Future<void> _openProfile() async {
    await Navigator.pushNamed(context, ProfilePage.routeName);
    if (!mounted) {
      return;
    }

    _refreshLoginState();
    if (_isLoggedIn && widget.activeIndex == 1) {
      await _loadUserInfo();
    }
  }

  Future<void> _confirmLogout() async {
    if (_isLoggingOut) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('退出登录'),
          content: const Text('确定要退出当前账号吗？'),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
              },
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                unawaited(_logout(dialogContext));
              },
              child: const Text(
                '退出',
                style: TextStyle(color: Colors.red),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _logout(BuildContext dialogContext) async {
    if (_isLoggingOut) {
      return;
    }

    setState(() {
      _isLoggingOut = true;
      _isLoggedIn = false;
    });
    _userInfoController.clearUserInfo();
    try {
      final bool deleted = await tokenManager.deleteToken();
      if (!deleted) {
        throw const FormatException('登录状态清除失败');
      }
      if (!mounted) {
        if (dialogContext.mounted) {
          Navigator.pop(dialogContext);
        }
        return;
      }

      if (dialogContext.mounted) {
        Navigator.pop(dialogContext);
      }
      await PromptAction.showSuccess('已退出登录');
    } on Object {
      if (mounted) {
        setState(() {
          _isLoggedIn = tokenManager.getToken().isNotEmpty;
        });
        if (_isLoggedIn) {
          await _loadUserInfo();
        }
      }
      await PromptAction.showError('退出失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _isLoggingOut = false;
        });
      }
    }
  }

  Future<void> _openMenuItem(
    ({String label, String icon, String? routeName}) item,
  ) async {
    final String? routeName = item.routeName;
    if (routeName != null) {
      await Navigator.pushNamed<void>(context, routeName);
      return;
    }
    await PromptAction.showToast('${item.label}功能暂未开放');
  }

  @override
  Widget build(BuildContext context) {
    return GetBuilder<UserInfoController>(
      builder: (_) {
        return ColoredBox(
          color: _backgroundColor,
          child: SafeArea(
            bottom: false,
            child: Column(
              children: <Widget>[
                const SizedBox(
                  height: 64,
                  child: Center(
                    child: Text(
                      '我的',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: _isLoggedIn ? null : _openLogin,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: <Widget>[
                                Container(
                                  width: 72,
                                  height: 72,
                                  decoration: const BoxDecoration(
                                    color: Color(0x33FFFFFF),
                                    shape: BoxShape.circle,
                                  ),
                                  child: ClipOval(
                                    child: _buildUserAvatar(),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Text(
                                    _isLoggedIn ? _getUserNickName() : '点击登录',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 23,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: _openProfile,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                '去完善信息',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                ),
                              ),
                              Icon(
                                Icons.chevron_right_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: _menuItems
                        .map<Widget>(
                          (({
                                String label,
                                String icon,
                                String? routeName
                              }) item) {
                            return InkWell(
                              onTap: () {
                                unawaited(_openMenuItem(item));
                              },
                              child: SizedBox(
                                height: 72,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 20),
                                  child: Row(
                                    children: <Widget>[
                                      Image.asset(
                                        item.icon,
                                        width: 48,
                                        height: 48,
                                        fit: BoxFit.contain,
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Text(
                                          item.label,
                                          style: const TextStyle(
                                            color: Color(0xFF262626),
                                            fontSize: 20,
                                            fontWeight: FontWeight.w400,
                                          ),
                                        ),
                                      ),
                                      const Icon(
                                        Icons.chevron_right_rounded,
                                        color: Color(0xFFA7A7A7),
                                        size: 32,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        )
                        .followedBy(
                          _hasLoggedInUser()
                              ? <Widget>[
                                  const Divider(
                                    height: 1,
                                    indent: 20,
                                    endIndent: 20,
                                  ),
                                  InkWell(
                                    onTap:
                                        _isLoggingOut ? null : _confirmLogout,
                                    child: SizedBox(
                                      height: 64,
                                      child: Center(
                                        child: _isLoggingOut
                                            ? const SizedBox(
                                                width: 24,
                                                height: 24,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                ),
                                              )
                                            : const Text(
                                                '退出登录',
                                                style: TextStyle(
                                                  color: Colors.red,
                                                  fontSize: 18,
                                                ),
                                              ),
                                      ),
                                    ),
                                  ),
                                ]
                              : const <Widget>[],
                        )
                        .toList(growable: false),
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        );
      },
    );
  }
}
