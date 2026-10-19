import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../constant/index.dart';
import '../router/app_routes.dart';
import '../utils/emitter.dart';
import '../utils/push_subscription.dart';
import '../utils/token_manager.dart';

/// 只有鸿蒙原生（Push Kit 点击参数）和 Web（Service Worker 转发）有通知点击可取。
bool get pushClickBridgeAvailable => kIsWeb || defaultTargetPlatform == TargetPlatform.ohos;

class PushLifecycle extends StatefulWidget {
  const PushLifecycle({required this.child, super.key});
  final Widget child;
  @override
  State<PushLifecycle> createState() => _PushLifecycleState();
}

class _PushLifecycleState extends State<PushLifecycle> with WidgetsBindingObserver {
  StreamSubscription<LoginSuccessEvent>? _login;
  StreamSubscription<LogoutEvent>? _logout;
  Timer? _clickTimer;
  bool _checking = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    tokenManager.beforeSessionEnd = _disable;
    _login = eventBus.on<LoginSuccessEvent>().listen((_) {
      _syncClickTimer();
      unawaited(_resume());
      unawaited(_checkClick());
    });
    _logout = eventBus.on<LogoutEvent>().listen((_) {
      _syncClickTimer();
      if (tokenManager.getToken().isEmpty) unawaited(_disable());
    });
    // Web 冷启动的 #/notifications/<id> 已由 MaterialApp 初始路由打开，这里不再重复处理。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_resume());
      unawaited(_checkClick());
    });
    _syncClickTimer();
  }
  void _stopClickTimer() {
    _clickTimer?.cancel();
    _clickTimer = null;
  }
  void _syncClickTimer() {
    if (!mounted || !pushClickBridgeAvailable || tokenManager.getToken().isEmpty) {
      _stopClickTimer();
      return;
    }
    _clickTimer ??= Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_checkClick()));
  }
  Future<void> _resume() async {
    try {
      await tokenManager.init();
      if (!mounted) return;
      _syncClickTimer();
      await pushSubscription.resume();
    }
    on Object { /* 失败原因由 pushSubscription.resumeProblem 展示在待办页；启动不受影响。 */ }
  }
  Future<void> _disable() async {
    _stopClickTimer();
    try { await pushSubscription.disable(); } on Object { /* Local logout must always remain available. */ }
  }
  void _open(String id) {
    final NavigatorState? navigator = GlobalVariable.navigatorKey.currentState;
    if (!mounted || navigator == null) return;
    final String name = AppRoutes.notificationDetail(id);
    String? top;
    navigator.popUntil((Route<dynamic> route) { top = route.settings.name; return true; });
    // 同一条通知已经在最上层时不再叠一层（重复点击、平台重复投递点击事件）。
    if (top == name) return;
    unawaited(navigator.pushNamed<void>(name));
  }
  Future<void> _checkClick() async {
    _syncClickTimer();
    if (!pushClickBridgeAvailable || _checking || !mounted) return;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) return;
    // 未登录时点击记录留在平台侧，登录成功后再取。
    if (tokenManager.getToken().isEmpty) return;
    _checking = true;
    try {
      final id = await pushSubscription.takeClick();
      if (id != null) _open(id);
    } on Object { /* Unsupported platforms do not interrupt ordinary navigation. */ }
    finally { _checking = false; }
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) { unawaited(_resume()); unawaited(_checkClick()); }
  }
  @override
  void dispose() {
    _login?.cancel(); _logout?.cancel(); _stopClickTimer();
    tokenManager.beforeSessionEnd = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => widget.child;
}
