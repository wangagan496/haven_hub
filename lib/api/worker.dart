import '../constant/index.dart';
import '../models/repair.dart';
import '../utils/date_utils.dart';
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

/// 接单或提交完工。完工时核心只填“修了什么”和“费用多少”，无费用填 0。
/// 接单时 [time] 为空表示按住户期望时间上门；不同则需填写 [reason]，作为改约提议。
Future<RepairRecord> processWorkerRepairApi(RepairRecord record,
    {required bool complete,
    String result = '',
    num cost = 0,
    DateTime? time,
    String reason = ''}) async {
  final String trimmedResult = result.trim();
  if (complete && trimmedResult.isEmpty) {
    throw const FormatException('请填写处理结果后再完成维修');
  }
  if (cost < 0) throw const FormatException('费用不能为负数');
  final dynamic data = await requestDio.put(
      HttpPath.workerRepairAction(record.id, complete ? 'complete' : 'accept'),
      data: <String, dynamic>{
        'revision': record.revision,
        if (complete) 'result': trimmedResult,
        if (complete) 'cost': cost,
        if (!complete && time != null) 'time': formatLocalTime(time),
        if (!complete && time != null) 'reason': reason.trim(),
      });
  return RepairRecord.fromJson(asMap(data, '工单处理'));
}

/// 无法继续接单：填写原因后退出，工单交回物业重新派单。
Future<void> releaseWorkerRepairApi(RepairRecord record, String reason) =>
    requestDio.put(HttpPath.workerRepairAction(record.id, 'release'),
        data: <String, dynamic>{'revision': record.revision, 'reason': reason.trim()});

/// 师傅发起改约：必须先电话告知住户；住户同意后生效。
Future<RepairRecord> proposeWorkerRescheduleApi(
        RepairRecord record, DateTime time, String reason) =>
    _action(record, 'reschedule', <String, dynamic>{
      'time': formatLocalTime(time),
      'reason': reason.trim(),
      'notified': true,
    });

Future<RepairRecord> respondWorkerRescheduleApi(RepairRecord record,
        {required bool accept, String reason = ''}) =>
    _action(record, 'reschedule',
        <String, dynamic>{'accept': accept, 'reason': reason.trim()},
        method: 'PUT');

/// 进展说明（已联系、等待材料等），只写入时间线，不改变工单状态。
Future<RepairRecord> workerProgressApi(RepairRecord record, String content) =>
    _action(record, 'progress', <String, dynamic>{'content': content.trim()});

/// 回应住户的撤销申请：已知晓，撤销立即生效。
Future<RepairRecord> acknowledgeRevokeApi(RepairRecord record) =>
    _action(record, 'revoke', <String, dynamic>{}, method: 'PUT');

Future<RepairRecord> _action(
    RepairRecord record, String action, Map<String, dynamic> body,
    {String method = 'POST'}) async {
  final String path = HttpPath.workerRepairAction(record.id, action);
  final Map<String, dynamic> data = <String, dynamic>{
    'revision': record.revision,
    ...body
  };
  final dynamic response = method == 'PUT'
      ? await requestDio.put(path, data: data)
      : await requestDio.post(path, data: data);
  return RepairRecord.fromJson(asMap(response, '工单处理'));
}
