import '../constant/index.dart';
import '../models/repair.dart';
import '../utils/app_exception.dart';
import '../utils/json_utils.dart';
import '../utils/request_dio.dart';
import '../utils/token_manager.dart';

typedef RepairListLoader = Future<List<RepairRecord>> Function();
typedef RepairDetailLoader = Future<RepairRecord> Function(String id);
typedef RepairItemLoader = Future<List<RepairItem>> Function();
typedef SubmitRepairLoader = Future<void> Function(RepairRecord record);
typedef CancelRepairLoader = Future<void> Function(String id);

Future<List<RepairRecord>> getRepairListApi({RequestDio? client}) async {
  final RequestDio requests = client ?? requestDio;
  final int sessionId = tokenManager.sessionId;
  final List<RepairRecord> records = <RepairRecord>[];
  final Set<String> seenIds = <String>{};
  int current = 1;
  while (true) {
    if (tokenManager.sessionId != sessionId) {
      throw const SessionChangedException();
    }
    final dynamic data = await requests.get(HttpPath.repair,
        params: <String, dynamic>{'current': current, 'pageSize': 20});
    if (tokenManager.sessionId != sessionId) {
      throw const SessionChangedException();
    }
    final List<dynamic> rows = readRows(data, '报修列表');
    for (final dynamic row in rows) {
      final RepairRecord record = RepairRecord.fromJson(asMap(row, '报修'));
      if (record.id.isEmpty || !seenIds.add(record.id)) {
        throw const FormatException('报修列表记录不完整或已变化，请刷新重试');
      }
      records.add(record);
    }
    final Map<String, dynamic> page = asMap(data, '报修列表');
    final int? pageTotal = int.tryParse(page['pageTotal']?.toString() ?? '');
    final int? total = int.tryParse(page['total']?.toString() ?? '');
    if (pageTotal == null || current >= pageTotal) {
      if (total != null && records.length < total) {
        throw const FormatException('报修列表未完整加载，请刷新重试');
      }
      return List<RepairRecord>.unmodifiable(records);
    }
    if (rows.isEmpty) {
      throw const FormatException('报修列表未完整加载，请刷新重试');
    }
    current++;
  }
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

Future<void> submitRepairApi(RepairRecord record, {RequestDio? client}) =>
    (client ?? requestDio).post(HttpPath.repair, data: <String, dynamic>{
      ...record.toJson(),
      // 当前表单没有附件选择；显式传空数组，避免后端遗漏必填的 attach 列。
      'attachment': <String>[],
    });

Future<void> cancelRepairApi(String id, {RequestDio? client}) async {
  if (id.trim().isEmpty) throw const FormatException('报修参数不正确');
  await (client ?? requestDio).put(HttpPath.cancelRepair(id));
}
