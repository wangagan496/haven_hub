import 'package:haven_hub/utils/token_storage.dart';

/// 普通会话测试使用内存存储；失败和并发时序仍由专用替身模拟。
class MemoryTokenStorage implements TokenStorage {
  MemoryTokenStorage({this.token = '', this.refreshToken = ''});

  @override
  String token;

  @override
  String refreshToken;

  @override
  Future<void> load() async {}

  @override
  Future<bool> write(String token, String refreshToken) async {
    this.token = token;
    this.refreshToken = refreshToken;
    return true;
  }

  @override
  void invalidate() {
    token = '';
    refreshToken = '';
  }

  @override
  Future<bool> clear() async {
    invalidate();
    return true;
  }
}
