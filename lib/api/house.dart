import 'dart:typed_data';

import '../constant/index.dart';
import '../models/house.dart';
import '../utils/json_utils.dart';
import '../utils/mutation_list.dart';
import '../utils/request_dio.dart';
import '../utils/submission_id.dart';

final MutationList<House> _houseChanges = MutationList(House.fromJson);

/// 房屋列表加载器类型定义。
typedef HouseListLoader = Future<List<House>> Function();

/// 房屋详情加载器类型定义。
typedef HouseDetailLoader = Future<House> Function(String id);

/// 删除房屋加载器类型定义。
typedef DeleteHouseLoader = Future<void> Function(String id,
    {required int revision});

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
Future<List<House>> getHouseListApi({RequestDio? client}) =>
    _houseChanges.load(() => _fetchHouseList(client ?? requestDio));

Future<List<House>> _fetchHouseList(RequestDio client) async {
  final dynamic data = await client.get(HttpPath.houseList);
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
Future<House> getHouseDetailApi(String id,
    {bool forceRefresh = false, RequestDio? client}) async {
  // 编辑返回详情页时直接使用同一次写响应中的记录，列表仍可随后消费。
  for (final House house in forceRefresh
      ? const <House>[]
      : _houseChanges.pending ?? const <House>[]) {
    if (house.id == id) return house;
  }
  final dynamic data =
      await (client ?? requestDio).get(HttpPath.houseDetail(id));
  if (data is! Map<dynamic, dynamic>) {
    throw const FormatException('房屋详情数据格式不正确');
  }

  return House.fromJson(Map<String, dynamic>.from(data));
}

/// 编辑和冲突恢复必须读取服务端当前资料，不能复用较早的写入回执。
Future<House> getHouseEditDetailApi(String id, {RequestDio? client}) =>
    getHouseDetailApi(id, forceRefresh: true, client: client);

/// 删除房屋。
///
/// [id] 房屋ID，不能为空。
/// [revision] 用户确认删除时查看的版本；冲突后须刷新核对，不能自动重放。
///
/// 抛出：
/// - [FormatException]: ID 参数无效
/// - [NetworkException]: 网络请求失败
/// - [BusinessException]: 业务逻辑错误（如无权限删除）
Future<void> deleteHouseApi(String id,
    {required int revision, RequestDio? client}) async {
  final String houseId = id.trim();
  if (houseId.isEmpty) {
    throw const FormatException('房屋参数不正确');
  }
  if (revision < 0 || revision > 9007199254740991) {
    throw const FormatException('房屋版本无效，请刷新核对后再删除');
  }

  await _houseChanges.write(() => (client ?? requestDio).delete(
      HttpPath.houseDetail(houseId),
      data: <String, dynamic>{'revision': revision}));
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
Future<void> submitHouseAPI(House house, {RequestDio? client}) =>
    _houseChanges.write(() async {
      if (house.id.isEmpty && house.submissionId.isNotEmpty) {
        _checkReceipt(house.submissionId);
      }
      final dynamic data = await (client ?? requestDio)
          .post(HttpPath.houseList, data: house.toJson());
      if (house.id.isEmpty &&
          house.submissionId.isNotEmpty &&
          (data is! Map ||
              data['createdId'] is! String ||
              (data['createdId'] as String).trim().isEmpty)) {
        throw const FormatException('未收到房屋编号，请查看提交结果');
      }
      return data;
    });

Future<HouseSubmissionResult> getHouseSubmissionApi(String id,
    {RequestDio? client}) async {
  _checkReceipt(id);
  final dynamic data =
      await (client ?? requestDio).get(HttpPath.houseSubmission(id));
  return HouseSubmissionResult.fromJson(asMap(data, '房屋提交结果'));
}

Future<HouseSubmissionResult> closeHouseSubmissionApi(String id,
    {RequestDio? client}) async {
  _checkReceipt(id);
  final dynamic data =
      await (client ?? requestDio).put(HttpPath.closeHouseSubmission(id));
  final result = HouseSubmissionResult.fromJson(asMap(data, '房屋提交结果'));
  if (result.state == HouseSubmissionState.unknown) {
    throw const FormatException('尚未确认停止，请继续查看提交结果');
  }
  return result;
}

void _checkReceipt(String id) {
  if (!isSubmissionId(id)) throw const FormatException('房屋提交回执无效');
}
