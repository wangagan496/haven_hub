import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/home.dart';
import '../../constant/tab_config.dart';
import '../../controller/build_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/emitter.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';
import '../home/index.dart';
import '../login/index.dart';
import '../mine/index.dart';

class TabsPage extends StatefulWidget {
  const TabsPage({
    this.announcementLoader = getAnnouncementListApi,
    super.key,
  });

  final AnnouncementLoader announcementLoader;

  @override
  State<TabsPage> createState() => _TabsPageState();
}

class _TabsPageState extends State<TabsPage> {
  int _currentIndex = 0;
  late Future<void> _tokenInitialization;
  late final StreamSubscription<LogoutEvent> _logoutSubscription;
  bool _isHandlingLogout = false;

  @override
  void initState() {
    super.initState();
    BuildController.instance();
    _tokenInitialization = tokenManager.init();
    _logoutSubscription = eventBus.on<LogoutEvent>().listen(_onLogoutEvent);
  }

  @override
  void dispose() {
    _logoutSubscription.cancel();
    super.dispose();
  }

  void _onLogoutEvent(LogoutEvent event) {
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
      _tokenInitialization = tokenManager.init();
    });
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

        return _buildTabs();
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
