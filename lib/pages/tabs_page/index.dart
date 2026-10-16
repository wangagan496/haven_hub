import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/home.dart';
import '../../api/user.dart';
import '../../constant/index.dart';
import '../../constant/tab_config.dart';
import '../../controller/build_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/emitter.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';
import '../home/index.dart';
import '../login/index.dart';
import '../mine/index.dart';
import '../worker/worker_pages.dart';

/// 判断当前登录账号是否为维修师傅；未登录或非本地后端时返回 false。
typedef WorkerRoleLoader = Future<bool> Function();

Future<bool> loadIsWorker() async {
  if (!GlobalVariable.localBackend || tokenManager.getToken().isEmpty) {
    return false;
  }
  final user = await getUserInfoApi();
  return user.role == 'worker';
}

class TabsPage extends StatefulWidget {
  const TabsPage({
    this.announcementLoader = getAnnouncementListApi,
    this.workerRoleLoader = loadIsWorker,
    this.workerPageBuilder = _buildWorkerPage,
    super.key,
  });

  final AnnouncementLoader announcementLoader;
  final WorkerRoleLoader workerRoleLoader;
  final WidgetBuilder workerPageBuilder;

  static Widget _buildWorkerPage(BuildContext context) => const WorkerPage();

  @override
  State<TabsPage> createState() => _TabsPageState();
}

class _TabsPageState extends State<TabsPage> {
  int _currentIndex = 0;
  bool _isWorker = false;
  int _roleRequestId = 0;
  late Future<void> _tokenInitialization;
  late final StreamSubscription<LoginSuccessEvent> _loginSubscription;
  late final StreamSubscription<LogoutEvent> _logoutSubscription;
  bool _isHandlingLogout = false;

  @override
  void initState() {
    super.initState();
    BuildController.instance();
    _tokenInitialization = _initializeIdentity();
    _loginSubscription =
        eventBus.on<LoginSuccessEvent>().listen(_onLoginSuccess);
    _logoutSubscription = eventBus.on<LogoutEvent>().listen(_onLogoutEvent);
  }

  @override
  void dispose() {
    _loginSubscription.cancel();
    _logoutSubscription.cancel();
    super.dispose();
  }

  /// 换号后旧实例可能仍在栈底，必须按新账号重新判定角色，
  /// 否则住户会看到上一位师傅的工作台。
  void _onLoginSuccess(LoginSuccessEvent event) {
    if (!mounted) return;
    setState(() => _isWorker = false);
    unawaited(_resolveRole());
  }

  void _onLogoutEvent(LogoutEvent event) {
    _roleRequestId++;
    if (mounted && _isWorker) setState(() => _isWorker = false);
    unawaited(_handleLogout());
  }

  Future<void> _handleLogout() async {
    if (_isHandlingLogout) {
      return;
    }

    _isHandlingLogout = true;
    try {
      final bool cleared = await tokenManager.deleteToken();
      if (!cleared) {
        // 内存中的凭证已经失效，磁盘上的还在。此时若照常跳到登录页，用户会
        // 以为已经退出，重启后却被残留凭证自动登录回来。保持当前页面并如实
        // 报错，让这次失败可见。
        tokenManager.invalidateLocalSession();
        if (mounted) {
          await PromptAction.showError('本地登录信息清除失败，请重试');
        }
        return;
      }
      if (!mounted) {
        return;
      }

      if (_currentIndex != 0) {
        setState(() {
          _currentIndex = 0;
        });
      }

      await Navigator.pushNamedAndRemoveUntil(
        context,
        LoginPage.routeName,
        (Route<dynamic> route) => route.isFirst,
      );
    } on Object {
      await PromptAction.showError('退出登录失败，请重试');
    } finally {
      _isHandlingLogout = false;
    }
  }

  void _retryTokenInitialization() {
    setState(() {
      _tokenInitialization = _initializeIdentity();
    });
  }

  Future<void> _initializeIdentity() async {
    await tokenManager.init();
    await _resolveRole();
  }

  /// 角色查询失败只降级为住户界面，不阻塞启动；师傅接口仍由服务端鉴权。
  Future<void> _resolveRole() async {
    final int requestId = ++_roleRequestId;
    final int session = tokenManager.sessionId;
    bool isWorker = false;
    bool failed = false;
    try {
      isWorker = await widget.workerRoleLoader();
    } on Object {
      failed = true;
    }
    if (!mounted ||
        requestId != _roleRequestId ||
        session != tokenManager.sessionId) {
      return;
    }
    if (isWorker != _isWorker) setState(() => _isWorker = isWorker);
    if (failed) {
      await PromptAction.showWarning('身份信息获取失败，已按住户界面进入');
    }
  }

  List<BottomNavigationBarItem> getTabs(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context)!;
    final List<String> labels = <String>[l10n.home, l10n.mine];
    return tabsList.asMap().entries.map((MapEntry<int, TabConfig> entry) {
      final TabConfig item = entry.value;
      return BottomNavigationBarItem(
        icon: Image.asset(
          item.icon,
          width: 28,
          height: 28,
          fit: BoxFit.contain,
        ),
        activeIcon: Image.asset(
          item.activeIcon,
          width: 28,
          height: 28,
          fit: BoxFit.contain,
        ),
        label: labels[entry.key],
      );
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _tokenInitialization,
      builder: (BuildContext context, AsyncSnapshot<void> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: SafeArea(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Text('登录状态初始化失败，请重试'),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _retryTokenInitialization,
                      child: const Text('重新加载'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return _isWorker ? widget.workerPageBuilder(context) : _buildTabs();
      },
    );
  }

  Widget _buildTabs() {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: <Widget>[
          HomePage(announcementLoader: widget.announcementLoader),
          MinePage(activeIndex: _currentIndex),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        items: getTabs(context),
        currentIndex: _currentIndex,
        selectedItemColor: const Color(0xFF5591AF),
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        onTap: (int index) {
          if (index == _currentIndex) {
            return;
          }
          setState(() {
            _currentIndex = index;
          });
        },
      ),
    );
  }
}
