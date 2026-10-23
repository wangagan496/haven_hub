import '../constant/index.dart';
import '../models/repair.dart';
import '../utils/json_utils.dart';
import '../utils/request_dio.dart';

Future<List<RepairRecord>> getWorkerRepairPoolApi() async {
  final dynamic data = await requestDio.get(HttpPath.workerRepairPool);
  if (data is! List<dynamic>) throw const FormatException('可接单列表格式不正确');
  return data.map((dynamic value) {
    final row = asMap(value, '可接单');
    return RepairRecord.fromJson(<String, dynamic>{...row,
      'houseInfo': '${row['community'] ?? ''} ${row['building'] ?? ''}'.trim()});
  }).toList();
}

Future<RepairRecord> claimWorkerRepairApi(RepairRecord record, {String? slot}) async =>
    RepairRecord.fromJson(asMap(await requestDio.put(HttpPath.workerRepairAction(record.id, 'claim'),
      data: <String, dynamic>{'revision': record.revision, if (slot != null) 'slot': slot}), '接单结果'));

class WorkerSkills {
  const WorkerSkills(this.skills, this.revision);
  factory WorkerSkills.fromJson(Map<String, dynamic> json) => WorkerSkills(
    (json['skills'] as List<dynamic>).whereType<String>().toList(),
    (json['workforceRevision'] as num).toInt());
  final List<String> skills;
  final int revision;
}

Future<WorkerSkills> getWorkerSkillsApi() async =>
    WorkerSkills.fromJson(asMap(await requestDio.get(HttpPath.workerSkills), '我的技能'));

Future<Map<String, dynamic>> saveWorkerSkillsApi(WorkerSkills profile, List<String> skills, {bool preview = false}) async =>
    asMap(await requestDio.put(HttpPath.workerSkills, data: <String, dynamic>{
      'workforceRevision': profile.revision, 'skills': skills, 'preview': preview,
    }), '技能保存');

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
/// 接单时 [slot] 为空则沿用现有安排；无安排时可仅接单或同时提出首次时段。
Future<RepairRecord> processWorkerRepairApi(RepairRecord record,
    {required bool complete,
    String result = '',
    num cost = 0,
    bool saveOnly = false,
    bool ready = false,
    String? problem,
    String? cause,
    String? slot,
    String reason = '', RequestDio? client}) async {
  final String trimmedResult = result.trim();
  if (complete && (!saveOnly || ready) && trimmedResult.isEmpty) {
    throw const FormatException('请填写处理结果后再完成维修');
  }
  if (!cost.isFinite || cost < 0) throw const FormatException('请填写有效费用');
  final dynamic data = await (client ?? requestDio).put(
      HttpPath.workerRepairAction(record.id, complete ? (saveOnly ? 'result' : 'complete') : 'accept'),
      data: <String, dynamic>{
        'revision': record.revision,
        if (complete) 'result': trimmedResult,
        if (complete) 'cost': cost,
        if (complete && saveOnly) 'ready': ready,
        if (complete && problem != null) 'problem': problem.trim(),
        if (complete && cause != null) 'cause': cause.trim(),
        if (!complete && slot != null) 'slot': slot,
        if (!complete && slot != null) 'reason': reason.trim(),
      });
  return RepairRecord.fromJson(asMap(data, '工单处理'));
}

Future<RepairRecord> saveWorkerRepairResultApi(RepairRecord record,
    {required bool ready, required String result, required num cost,
    String? problem, String? cause}) =>
    processWorkerRepairApi(record, complete: true, saveOnly: true,
        ready: ready, result: result, cost: cost, problem: problem, cause: cause);

/// 无法继续接单：填写原因后退出，工单交回物业重新派单。
Future<void> releaseWorkerRepairApi(RepairRecord record, String reason) =>
    requestDio.put(HttpPath.workerRepairAction(record.id, 'release'),
        data: <String, dynamic>{'revision': record.revision, 'reason': reason.trim()});

/// 师傅发起改约：必须先电话告知住户；住户同意后生效。
Future<RepairRecord> proposeWorkerRescheduleApi(
        RepairRecord record, String slot, String reason, {RequestDio? client}) =>
    _action(record, 'reschedule', <String, dynamic>{
      'slot': slot,
      'reason': reason.trim(),
      'notified': true,
    }, client: client);

Future<RepairRecord> respondWorkerRescheduleApi(RepairRecord record,
        {required bool accept, String reason = ''}) =>
    _action(record, 'reschedule',
        <String, dynamic>{'accept': accept, 'reason': reason.trim()},
        method: 'PUT');

/// 进展说明（已联系、等待材料等），只写入时间线，不改变工单状态。
Future<RepairRecord> workerProgressApi(RepairRecord record, String content, {bool needsAdmin = false, RequestDio? client}) =>
    _action(record, 'progress', <String, dynamic>{'content': content.trim(), 'needsAdmin': needsAdmin}, client: client);

/// 回应住户的撤销申请：已知晓，撤销立即生效。
Future<RepairRecord> acknowledgeRevokeApi(RepairRecord record) =>
    _action(record, 'revoke', <String, dynamic>{}, method: 'PUT');

Future<RepairRecord> _action(
    RepairRecord record, String action, Map<String, dynamic> body,
    {String method = 'POST', RequestDio? client}) async {
  final String path = HttpPath.workerRepairAction(record.id, action);
  final Map<String, dynamic> data = <String, dynamic>{
    'revision': record.revision,
    ...body
  };
  final dynamic response = method == 'PUT'
      ? await (client ?? requestDio).put(path, data: data)
      : await (client ?? requestDio).post(path, data: data);
  return RepairRecord.fromJson(asMap(response, '工单处理'));
}
