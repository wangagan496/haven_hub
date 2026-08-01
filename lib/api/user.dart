import 'dart:typed_data';

import '../constant/index.dart';
import '../models/user_info.dart';
import '../utils/request_dio.dart';

typedef SendCodeLoader = Future<Map<String, dynamic>> Function(String mobile);
typedef LoginLoader = Future<Map<String, dynamic>> Function(
  String mobile,
  String code,
);
typedef UserInfoLoader = Future<UserInfo> Function();
typedef UpdateUserInfoLoader = Future<Map<String, dynamic>> Function({
  required String nickName,
  required String avatar,
});
typedef UploadAvatarLoader = Future<String> Function({
  required Uint8List fileBytes,
  required String fileName,
});

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

Future<Map<String, dynamic>> updateUserInfoApi({
  required String nickName,
  required String avatar,
}) async {
  final dynamic data = await requestDio.put(
    HttpPath.userInfo,
    data: <String, dynamic>{
      'nickName': nickName,
      'avatar': avatar,
    },
  );
  final Map<String, dynamic> result = _toMap(data, '修改用户信息');
  if (result['id']?.toString().trim().isEmpty ?? true) {
    throw const FormatException('修改用户信息接口未返回用户 ID');
  }
  return result;
}

Future<String> uploadAvatarApi({
  required Uint8List fileBytes,
  required String fileName,
}) async {
  final dynamic data = await requestDio.upload(
    HttpPath.upload,
    fileBytes: fileBytes,
    fileName: fileName,
    data: <String, dynamic>{'type': 'avatar'},
  );
  final Map<String, dynamic> result = _toMap(data, '上传头像');
  final String url = result['url']?.toString().trim() ?? '';
  if (url.isEmpty) {
    throw const FormatException('上传头像接口未返回图片地址');
  }
  return url;
}

Map<String, dynamic> _toMap(dynamic data, String operation) {
  if (data is! Map<dynamic, dynamic>) {
    throw FormatException('$operation接口数据格式不正确');
  }
  return Map<String, dynamic>.from(data);
}
