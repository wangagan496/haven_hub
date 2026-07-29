import 'package:event_bus/event_bus.dart';

/// 应用内共享的事件总线。
final EventBus eventBus = EventBus();

/// 登录成功，需要刷新账号相关页面。
class LoginSuccessEvent {
  const LoginSuccessEvent();
}

/// Token 无感刷新成功，需要重新拉取用户信息。
class RefreshEvent {
  const RefreshEvent();
}

/// 登录凭证失效，需要退出当前账号。
class LogoutEvent {
  const LogoutEvent();
}
