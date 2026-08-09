import '../constant/index.dart';
import '../models/repair.dart';
import '../utils/json_utils.dart';
import '../utils/request_dio.dart';

typedef RepairListLoader = Future<List<RepairRecord>> Function();
typedef RepairDetailLoader = Future<RepairRecord> Function(String id);
typedef RepairItemLoader = Future<List<RepairItem>> Function();
typedef SubmitRepairLoader = Future<void> Function(RepairRecord record);
typedef CancelRepairLoader = Future<void> Function(String id);

Future<List<RepairRecord>> getRepairListApi() async {
  final dynamic data = await requestDio.get(HttpPath.repair);
  return readRows(data, '报修列表')
      .map((dynamic item) => RepairRecord.fromJson(asMap(item, '报修')))
      .toList(growable: false);
}

Future<RepairRecord> getRepairDetailApi(String id) async {
  final dynamic data = await requestDio.get(HttpPath.repairDetail(id));
  return RepairRecord.fromJson(asMap(data, '报修详情'));
}

Future<List<RepairItem>> getRepairItemsApi() async {
  final dynamic data = await requestDio.get(HttpPath.repairItem);
  if (data is! List<dynamic>) throw const FormatException('维修项目数据格式不正确');
  return data
      .map((dynamic item) => RepairItem.fromJson(asMap(item, '维修项目')))
      .toList(growable: false);
}

Future<void> submitRepairApi(RepairRecord record) =>
    requestDio.post(HttpPath.repair, data: record.toJson());

Future<void> cancelRepairApi(String id) async {
  if (id.trim().isEmpty) throw const FormatException('报修参数不正确');
  await requestDio.put(HttpPath.cancelRepair(id));
}
