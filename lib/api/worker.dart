import '../constant/index.dart';
import '../models/repair.dart';
import '../utils/json_utils.dart';
import '../utils/request_dio.dart';

Future<List<RepairRecord>> getWorkerRepairsApi() async {
  final dynamic data = await requestDio.get(HttpPath.workerRepairs);
  if (data is! List<dynamic>) throw const FormatException('工单列表格式不正确');
  return data
      .map((dynamic row) => RepairRecord.fromJson(asMap(row, '工单')))
      .toList();
}

Future<RepairRecord> getWorkerRepairApi(String id) async =>
    RepairRecord.fromJson(
        asMap(await requestDio.get(HttpPath.workerRepair(id)), '工单详情'));
Future<RepairRecord> processWorkerRepairApi(RepairRecord record,
    {required bool complete, String result = ''}) async {
  final String trimmedResult = result.trim();
  if (complete && trimmedResult.isEmpty) {
    throw const FormatException('请填写处理结果后再完成维修');
  }
  final dynamic data = await requestDio.put(
      HttpPath.workerRepairAction(record.id, complete ? 'complete' : 'accept'),
      data: <String, dynamic>{
        'revision': record.revision,
        if (complete) 'result': trimmedResult
      });
  return RepairRecord.fromJson(asMap(data, '工单处理'));
}
