import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/notifications.dart';
import '../platform/push_platform.dart';
import 'token_manager.dart';

/// Platform subscription and account revocation only; no navigation or BuildContext.
class PushSubscription {
  PushSubscription({
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) platform = pushPlatformCall,
    Future<Map<String, dynamic>> Function() config = notificationConfigApi,
    Future<void> Function(Map<String, dynamic>) register = registerNotificationsApi,
    Future<void> Function(String) unregister = unregisterNotificationsApi,
  }) : _platform = platform, _config = config, _register = register, _unregister = unregister;

  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) _platform;
  final Future<Map<String, dynamic>> Function() _config;
  final Future<void> Function(Map<String, dynamic>) _register;
  final Future<void> Function(String) _unregister;
  bool _changing = false;
  int _generation = 0;
  Future<void>? _disabling;

  /// 回到前台恢复推送失败的原因（例如系统通知权限被关、暂时断网）。
  /// 恢复失败不会自动关闭推送，下次回到前台再试；这里只给界面一个可见提示。
  final ValueNotifier<String?> resumeProblem = ValueNotifier<String?>(null);
  Future<String> _installation() async {
    final preferences = await SharedPreferences.getInstance();
    final old = preferences.getString('push_installation');
    if (old != null) return old;
    final random = Random.secure();
    final value = List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await preferences.setString('push_installation', value);
    return value;
  }

  Future<void> enable({bool resume = false}) async {
    if (_changing) {
      if (resume) return;
      throw const FormatException('通知设置正在处理，请稍后再试');
    }
    if (tokenManager.getToken().isEmpty) {
      if (resume) return;
      throw const FormatException('请先登录后开启系统通知');
    }
    _changing = true;
    final session = tokenManager.sessionId;
    final generation = _generation;
    bool cancelled() => session != tokenManager.sessionId || generation != _generation;
    String? registeredId;
    String? registeredProfile;
    try {
      if (!resume) await _platform(<String, dynamic>{'action': 'requestPermission'});
      await _disabling;
      if (cancelled()) throw const FormatException('登录或通知设置已变化，请重试');
      final settings = await SharedPreferences.getInstance();
      if (settings.getBool('push_revoke_pending') ?? false) {
        // 服务端解绑未完成前不能登记新账号；解绑仍失败时 disable 会抛出并中止开启。
        await disable();
        if (resume) return;
        throw const FormatException('旧通知订阅已解绑，请再次点击开启系统通知');
      }
      if (resume && !(settings.getBool('push_enabled') ?? false)) return;
      if (!resume) await _clearStaleProfile(settings);
      final config = await _config();
      if (cancelled()) throw const FormatException('登录或通知设置已变化，请重试');
      registeredProfile = config['profileId'] as String;
      final registration = await _platform(<String, dynamic>{
        'action': resume ? 'resume' : 'enable',
        'publicKey': config['webPublicKey'], 'profileId': config['profileId'],
      });
      if (cancelled()) {
        throw const FormatException('登录或通知设置已变化，请重试');
      }
      if (!registration.containsKey('platform')) {
        if (resume) {
          // 平台没有返回订阅：多为系统或浏览器通知权限已关闭。保持开启状态，权限恢复后自动续上。
          resumeProblem.value = '系统通知暂时不可用，请检查通知权限；待办仍会保留';
          return;
        }
        throw const FormatException('系统推送尚未登记，请重试');
      }
      registration['installationId'] ??= await _installation();
      registeredId = registration['installationId'] as String;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('registered_push_installation', registeredId);
      await preferences.setString('registered_push_profile', registeredProfile);
      if (cancelled()) throw const FormatException('登录或通知设置已变化，请重试');
      await _register(registration);
      if (cancelled()) throw const FormatException('登录或通知设置已变化，请重试');
      await preferences.setBool('push_enabled', true);
      if (cancelled()) throw const FormatException('登录或通知设置已变化，请重试');
      resumeProblem.value = null;
    } on Object catch (error) {
      if (resume && !cancelled()) {
        // 同一会话里的恢复失败（断网、超时、权限暂不可用）不关闭推送：
        // 平台和服务端仍绑定在当前账号上，下次回到前台重试即可。
        resumeProblem.value = error is FormatException ? error.message : '系统通知暂时无法恢复，将在下次打开时重试';
        rethrow;
      }
      if (registeredProfile != null) {
        // A logout may revoke before an in-flight register reaches the server.
        // Retain the capability and revoke again after that request completes.
        try { await _disabling; } on Object { /* Retry the persisted revocation below. */ }
        final preferences = await SharedPreferences.getInstance();
        if (registeredId != null) await preferences.setString('registered_push_installation', registeredId);
        await preferences.setString('registered_push_profile', registeredProfile);
        try { await disable(); } on Object { /* Preserve registration error and pending cleanup. */ }
      }
      rethrow;
    } finally { _changing = false; }
  }

  Future<void> disable() {
    _generation++;
    return _disabling ??= _disable().whenComplete(() => _disabling = null);
  }

  /// 账号隔离以服务端解绑为准：服务端删掉设备后，就不会再向本机发送该账号的提醒。
  /// 平台侧解绑（鸿蒙 profile、浏览器订阅）只是额外保护，失败时记为待清理的旧 profile，
  /// 下次主动开启前再尝试一次，不阻塞新的登记。
  Future<void> _disable() async {
    final preferences = await SharedPreferences.getInstance();
    final id = preferences.getString('registered_push_installation');
    final profile = preferences.getString('registered_push_profile') ?? '';
    await preferences.setBool('push_enabled', false);
    // 先落盘待解绑标记再做任何平台/网络操作：进程在解绑途中被杀，重启后 resume 会补解绑。
    if (id != null || profile.isNotEmpty) await preferences.setBool('push_revoke_pending', true);
    resumeProblem.value = null;
    bool platformDisabled = false;
    try {
      await _platform(<String, dynamic>{'action': 'disable', 'profileId': profile});
      platformDisabled = true;
    } on Object { /* 记为旧 profile，见下方。 */ }
    if (id != null) {
      try {
        await _unregister(id);
        await preferences.remove('registered_push_installation');
      } on Object {
        // 保留解绑凭证，联网或下次启动时重试；在此之前不允许登记新账号。
        await preferences.setBool('push_revoke_pending', true);
        throw const FormatException('本机通知已停用，服务端解绑将在联网后重试');
      }
    }
    if (!platformDisabled && profile.isNotEmpty) await preferences.setString('push_stale_profile', profile);
    await preferences.remove('registered_push_profile');
    await preferences.remove('push_revoke_pending');
  }

  /// 主动开启前尽力清理上次没解绑成功的平台 profile；失败也继续开启。
  Future<void> _clearStaleProfile(SharedPreferences preferences) async {
    final stale = preferences.getString('push_stale_profile');
    if (stale == null) return;
    try {
      await _platform(<String, dynamic>{'action': 'disable', 'profileId': stale});
    } on Object { /* 平台持续拒绝时放弃这个旧 profile，服务端早已解绑。 */ }
    await preferences.remove('push_stale_profile');
  }

  Future<void> resume() async {
    if (_changing) return;
    final preferences = await SharedPreferences.getInstance();
    // 开启途中被中断（已保存安装标识、服务端可能已登记，但未写入 push_enabled）同样补解绑。
    final interrupted = !(preferences.getBool('push_enabled') ?? false) &&
        preferences.getString('registered_push_installation') != null;
    if ((preferences.getBool('push_revoke_pending') ?? false) || interrupted) {
      await disable();
      if (preferences.getBool('push_revoke_pending') ?? false) return;
    }
    await enable(resume: true);
  }

  Future<String?> takeClick() async {
    final value = await _platform(<String, dynamic>{'action': 'takeClick'});
    final id = value['notificationId'];
    return id is String && RegExp(r'^[a-f0-9-]{36}$').hasMatch(id) ? id : null;
  }
}

final pushSubscription = PushSubscription();
