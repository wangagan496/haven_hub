import 'dart:typed_data';

import '../constant/index.dart';
import '../models/house.dart';
import '../utils/request_dio.dart';

/// 房屋列表加载器类型定义。
typedef HouseListLoader = Future<List<House>> Function();

/// 房屋详情加载器类型定义。
typedef HouseDetailLoader = Future<House> Function(String id);

/// 删除房屋加载器类型定义。
typedef DeleteHouseLoader = Future<void> Function(String id);

/// 上传照片加载器类型定义。
typedef UploadPhotoLoader = Future<String> Function({
  required Uint8List fileBytes,
  required String fileName,
});

/// 提交房屋信息加载器类型定义。
typedef SubmitHouseLoader = Future<void> Function(House house);

/// 获取房屋列表。
///
/// 返回当前用户的所有房屋信息列表。
///
/// 抛出：
/// - [NetworkException]: 网络请求失败
/// - [BusinessException]: 业务逻辑错误
/// - [FormatException]: 数据格式不正确
Future<List<House>> getHouseListApi() async {
  final dynamic data = await requestDio.get(HttpPath.houseList);
  if (data is! List<dynamic>) {
    throw const FormatException('房屋列表数据格式不正确');
  }

  final List<House> houses = <House>[];
  for (final dynamic item in data) {
    if (item is! Map<dynamic, dynamic>) {
      throw const FormatException('房屋信息数据格式不正确');
    }
    houses.add(House.fromJson(Map<String, dynamic>.from(item)));
  }
  return List<House>.unmodifiable(houses);
}

/// 获取房屋详情。
///
/// [id] 房屋ID。
///
/// 返回指定房屋的完整信息。
///
/// 抛出：
/// - [NetworkException]: 网络请求失败
/// - [BusinessException]: 业务逻辑错误（如房屋不存在）
/// - [FormatException]: 数据格式不正确
Future<House> getHouseDetailApi(String id) async {
  final dynamic data = await requestDio.get(HttpPath.houseDetail(id));
  if (data is! Map<dynamic, dynamic>) {
    throw const FormatException('房屋详情数据格式不正确');
  }

  return House.fromJson(Map<String, dynamic>.from(data));
}

/// 删除房屋。
///
/// [id] 房屋ID，不能为空。
///
/// 抛出：
/// - [FormatException]: ID 参数无效
/// - [NetworkException]: 网络请求失败
/// - [BusinessException]: 业务逻辑错误（如无权限删除）
Future<void> deleteHouseApi(String id) async {
  final String houseId = id.trim();
  if (houseId.isEmpty) {
    throw const FormatException('房屋参数不正确');
  }

  await requestDio.delete(HttpPath.houseDetail(houseId));
}

/// 上传照片到服务器。
///
/// [fileBytes] 图片文件的字节数据。
/// [fileName] 文件名，用于服务端识别文件类型。
///
/// 返回上传成功后的图片 URL。
///
/// 抛出：
/// - [NetworkException]: 网络请求失败
/// - [BusinessException]: 业务逻辑错误（如文件过大）
/// - [FormatException]: 服务端返回格式不正确
Future<String> uploadPhotoAPI({
  required Uint8List fileBytes,
  required String fileName,
}) async {
  final dynamic data = await requestDio.upload(
    HttpPath.upload,
    fileBytes: fileBytes,
    fileName: fileName,
  );
  if (data is! Map<dynamic, dynamic>) {
    throw const FormatException('上传图片接口数据格式不正确');
  }

  final String url = data['url']?.toString().trim() ?? '';
  if (url.isEmpty) {
    throw const FormatException('上传图片接口未返回图片地址');
  }
  return url;
}

/// 提交房屋信息（新增或修改）。
///
/// [house] 房屋信息对象。如果 [house.id] 为空，则为新增；否则为修改。
///
/// 抛出：
/// - [NetworkException]: 网络请求失败
/// - [BusinessException]: 业务逻辑错误（如验证失败）
Future<void> submitHouseAPI(House house) async {
  await requestDio.post(HttpPath.houseList, data: house.toJson());
}
