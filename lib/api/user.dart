import '../constant/index.dart';
import '../models/user_info.dart';
import '../utils/request_dio.dart';

typedef SendCodeLoader = Future<Map<String, dynamic>> Function(String mobile);
typedef LoginLoader = Future<Map<String, dynamic>> Function(
  String mobile,
  String code,
);
typedef UserInfoLoader = Future<UserInfo> Function();

Future<Map<String, dynamic>> sendCodeApi(String mobile) async {
  final dynamic data = await requestDio.get(
    HttpPath.sendCode,
    params: <String, dynamic>{'mobile': mobile},
  );
  return _toMap(data, '验证码');
}

Future<Map<String, dynamic>> loginApi(String mobile, String code) async {
  final dynamic data = await requestDio.post(
    HttpPath.login,
    data: <String, dynamic>{
      'mobile': mobile,
      'code': code,
    },
  );
  return _toMap(data, '登录');
}

Future<UserInfo> getUserInfoApi() async {
  final dynamic data = await requestDio.get(HttpPath.userInfo);
  return UserInfo.fromJson(_toMap(data, '获取用户信息'));
}

Map<String, dynamic> _toMap(dynamic data, String operation) {
  if (data is! Map<dynamic, dynamic>) {
    throw FormatException('$operation接口数据格式不正确');
  }
  return Map<String, dynamic>.from(data);
}
