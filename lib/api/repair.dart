import '../constant/index.dart';
import '../models/repair.dart';
import '../models/repair_page.dart';
import '../utils/app_exception.dart';
import '../utils/json_utils.dart';
import '../utils/mutation_list.dart';
import '../utils/repair_list_preloader.dart';
import '../utils/request_dio.dart';
import '../utils/token_manager.dart';

final MutationList<RepairRecord> _repairChanges =
    MutationList(RepairRecord.fromJson);

typedef RepairListLoader = Future<List<RepairRecord>> Function();
typedef RepairPageLoader = Future<RepairPage> Function({
  required int current,
  required RepairStatusFilter filter,
  bool usePreload,
});
/// 读取指定编号的工单详情。
typedef RepairDetailLoader = Future<RepairRecord> Function(String repairId);
typedef RepairItemLoader = Future<List<RepairItem>> Function();
typedef RepairSlotsLoader = Future<RepairSlots> Function({String? date, String? excludeId, String? repairItemId});

Future<RepairSlots> getRepairSlotsApi({String? date, String? excludeId, String? repairItemId, RequestDio? client}) async {
  final dynamic data = await (client ?? requestDio).get(HttpPath.repairSlots, params: <String, dynamic>{
    if (date != null && date.isNotEmpty) 'date': date,
    if (excludeId != null && excludeId.isNotEmpty) 'excludeId': excludeId,
    if (repairItemId != null && repairItemId.isNotEmpty) 'repairItemId': repairItemId,
  });
  return RepairSlots.fromJson(asMap(data, '上门时段'));
}
/// 返回值为新工单编号时，提交后直接进入详情；其他返回值（如测试替身）回到列表。
typedef SubmitRepairLoader = Future<dynamic> Function(RepairRecord record);
/// 提交直接取消请求；正常完成表示取消成功，不返回工单。
typedef RepairCancellationSubmitter = Future<void> Function(String repairId,
    {required int revision});

/// 提交函数的格式：接收当前工单和要执行的操作，完成后返回更新后的工单。
/// Future 表示结果稍后才有，调用处用 await 等待。
/// 正常使用 [submitRepairActionApi] 请求服务器；测试也可以传入模拟函数。
typedef RepairActionSubmitter = Future<RepairRecord> Function(
  RepairRecord currentRepair,
  RepairAction action,
);

/// 描述用户要做什么，以及这次操作需要携带的数据；本身不会发送请求。
sealed class RepairAction {
  const RepairAction();
}

/// 确认维修已完成。
final class ConfirmAction extends RepairAction {
  const ConfirmAction();
}

/// 拒绝本次维修结果，并说明原因。
final class RejectAction extends RepairAction {
  const RejectAction(this.reason);
  final String reason;
}

/// 申请售后返修，并说明原因。
final class AftersaleAction extends RepairAction {
  const AftersaleAction(this.reason);
  final String reason;
}

/// 提交工单反馈。
final class FeedbackAction extends RepairAction {
  const FeedbackAction(this.content);
  final String content;
}

/// 申请撤销；notified 表示是否已电话告知师傅。
final class RevokeAction extends RepairAction {
  const RevokeAction(this.reason, {required this.notified});
  final String reason;
  final bool notified;
}

/// 提议新的上门时段，并说明改约原因。
final class ProposeAction extends RepairAction {
  const ProposeAction(this.slot, this.reason);
  final String slot;
  final String reason;
}

/// 回应师傅的改约提议；accept 表示是否同意。
final class RespondAction extends RepairAction {
  const RespondAction({required this.accept, this.reason = ''});
  final bool accept;
  final String reason;
}

/// 根据操作类型调用对应接口，返回服务器处理后的工单。
Future<RepairRecord> submitRepairActionApi(
  RepairRecord currentRepair,
  RepairAction action,
) {
  // 每个 case 对应一种操作；action.reason 等字段就是该操作携带的数据。
  switch (action) {
    case ConfirmAction():
      return confirmRepairApi(currentRepair);
    case RejectAction():
      return rejectRepairApi(currentRepair, action.reason);
    case AftersaleAction():
      return applyAftersaleApi(currentRepair, action.reason);
    case FeedbackAction():
      return feedbackRepairApi(currentRepair, action.content);
    case RevokeAction():
      return revokeRepairApi(
        currentRepair,
        reason: action.reason,
        notified: action.notified,
      );
    case ProposeAction():
      return proposeRescheduleApi(currentRepair, action.slot, action.reason);
    case RespondAction():
      return respondRescheduleApi(
        currentRepair,
        accept: action.accept,
        reason: action.reason,
      );
  }
}

final RepairListPreloader repairListPreloader =
    RepairListPreloader(loader: getRepairListApi);

final RepairPreloader<RepairPage> repairPagePreloader =
    RepairPreloader<RepairPage>(loader: getRepairPageApi);

// 首页只提前读第一页，完整列表入口继续供既有调用方使用。
Future<void> preloadRepairList() => repairPagePreloader.preload();

void _invalidateRepairPreloads() {
  repairListPreloader.invalidate();
  repairPagePreloader.invalidate();
}

Future<RepairPage> getPreloadedRepairPageApi({
  required int current,
  required RepairStatusFilter filter,
  bool usePreload = false,
}) {
  if (usePreload && current == 1 && filter == RepairStatusFilter.all) {
    return repairPagePreloader.load();
  }
  repairPagePreloader.invalidate();
  return getRepairPageApi(current: current, filter: filter);
}

Future<RepairPage> getRepairPageApi({
  int current = 1,
  int pageSize = 20,
  RepairStatusFilter filter = RepairStatusFilter.all,
  RequestDio? client,
}) async {
  if (current < 1 || current > 9007199254740991 || pageSize < 1 || pageSize > 200) {
    throw const FormatException('报修分页参数不正确');
  }
  final int sessionId = tokenManager.sessionId;
  final dynamic data = await (client ?? requestDio).get(HttpPath.repair,
      params: <String, dynamic>{'current': current, 'pageSize': pageSize, 'filter': filter.name});
  if (tokenManager.sessionId != sessionId) throw const SessionChangedException();
  return RepairPage.fromJson(data, current: current, pageSize: pageSize, filter: filter);
}

Future<List<RepairRecord>> getPreloadedRepairListApi() {
  if (_repairChanges.pending != null) repairListPreloader.invalidate();
  return repairListPreloader.load();
}

Future<List<RepairRecord>> getRepairListApi({RequestDio? client}) =>
    _repairChanges.load(() => _fetchRepairList(client: client));

Future<List<RepairRecord>> _fetchRepairList({RequestDio? client}) async {
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

/// 师傅人手不足时，提交住户选择的新时间，或保持原时间继续等待。
/// slot 是新时段；keep 为 true 表示保持原时间。
typedef ReplacementScheduleSubmitter = Future<RepairRecord> Function(
  RepairRecord currentRepair, {
  String? slot,
  bool keep,
});
Future<RepairSlots> getUnstaffedSlotsApi({String? date, String? excludeId, String? repairItemId}) async {
  final int session = tokenManager.sessionId;
  final dynamic data = await requestDio.get(HttpPath.repairUnstaffedOptions(excludeId!),
      params: <String, dynamic>{if (date != null) 'date': date});
  if (session != tokenManager.sessionId) throw const SessionChangedException();
  return RepairSlots.fromJson(asMap(data, '可选上门时间'));
}

Future<RepairRecord> chooseUnstaffedSlotApi(RepairRecord record, {String? slot, bool keep = false}) async {
  final int session = tokenManager.sessionId;
  final RepairRecord result = await _repairAction(HttpPath.repairUnstaffedChoice(record.id), <String, dynamic>{
    'revision': record.revision, 'offerId': record.rescheduleOffer!.id,
    if (keep) 'keep': true else 'slot': slot,
  }, method: 'PUT');
  if (session != tokenManager.sessionId) throw const SessionChangedException();
  return result;
}

Future<List<RepairItem>> getRepairItemsApi() async {
  final dynamic data = await requestDio.get(HttpPath.repairItem);
  if (data is! List<dynamic>) throw const FormatException('维修项目数据格式不正确');
  return data
      .map((dynamic item) => RepairItem.fromJson(asMap(item, '维修项目')))
      .toList(growable: false);
}

/// 查询当前账号的提交回执；null 只表示尚未查到，不表示提交失败。
Future<String?> getRepairSubmissionApi(String submissionId, {RequestDio? client}) async {
  final int session = tokenManager.sessionId;
  final dynamic data = await (client ?? requestDio).get(HttpPath.repairSubmission(submissionId));
  if (session != tokenManager.sessionId) throw const SessionChangedException();
  final Map<String, dynamic> result = asMap(data, '报修提交结果');
  if (result['state'] == 'unknown') return null;
  if (result['state'] == 'closed') throw const BusinessException('本次提交已停止，可以修改后重新提交', code: 40903);
  final String createdId = result['createdId']?.toString().trim() ?? '';
  if (result['state'] != 'created' || createdId.isEmpty) throw const FormatException('提交结果格式不正确，请稍后重新查询');
  return createdId;
}

Future<String?> closeRepairSubmissionApi(String submissionId, {RequestDio? client}) async {
  final int session = tokenManager.sessionId;
  final dynamic data = await (client ?? requestDio).put(HttpPath.closeRepairSubmission(submissionId));
  if (session != tokenManager.sessionId) throw const SessionChangedException();
  final Map<String, dynamic> result = asMap(data, '停止报修提交');
  if (result['state'] == 'closed') return null;
  final String id = result['createdId']?.toString().trim() ?? '';
  if (result['state'] != 'created' || id.isEmpty) throw const FormatException('停止提交的结果未确认，请稍后查询');
  return id;
}

/// 带回执的创建请求重复发送时，服务端返回同一工单编号。
Future<String> submitRepairApi(RepairRecord record, {RequestDio? client}) async {
  if (record.attachment.length > 8) throw const FormatException('现场照片最多8张');
  _invalidateRepairPreloads();
  String createdId = '';
  try {
    await _repairChanges.write(() async {
      final dynamic data =
          await (client ?? requestDio).post(HttpPath.repair, data: record.toJson());
      if (data is Map) createdId = data['createdId']?.toString() ?? '';
      return data;
    });
  } finally {
    _invalidateRepairPreloads();
  }
  if (record.submissionId.isNotEmpty && createdId.isEmpty) throw const FormatException('未收到报修编号，请查询提交结果');
  return createdId;
}

/// 未接单前按已查看版本直接撤销，返回完整列表。师傅接单后请用 [revokeRepairApi]。
Future<void> cancelRepairApi(String id,
    {required int revision, RequestDio? client}) async {
  if (id.trim().isEmpty) throw const FormatException('报修参数不正确');
  if (revision < 0 || revision > 9007199254740991) {
    throw const FormatException('工单版本无效，请刷新后再操作');
  }
  _invalidateRepairPreloads();
  try {
    await _repairChanges
        .write(() => (client ?? requestDio).put(HttpPath.cancelRepair(id),
            data: <String, dynamic>{'revision': revision}));
  } finally {
    _invalidateRepairPreloads();
  }
}

/// 撤销报修。师傅已接单时为撤销申请，必须先电话告知师傅（[notified]）。
Future<RepairRecord> revokeRepairApi(RepairRecord record,
    {required String reason, bool notified = false}) {
  return _repairAction(HttpPath.repairAction(record.id, 'revoke'), <String, dynamic>{
    'revision': record.revision,
    'reason': reason.trim(),
    'notified': notified,
  }, method: 'PUT');
}

Future<RepairRecord> confirmRepairApi(RepairRecord record) => _repairAction(
    HttpPath.repairAction(record.id, 'confirm'),
    <String, dynamic>{'revision': record.revision},
    method: 'PUT');

Future<RepairRecord> rejectRepairApi(RepairRecord record, String reason) =>
    _repairAction(HttpPath.repairAction(record.id, 'reject'),
        <String, dynamic>{'revision': record.revision, 'reason': reason.trim()},
        method: 'PUT');

Future<RepairRecord> applyAftersaleApi(RepairRecord record, String reason) =>
    _repairAction(HttpPath.repairAction(record.id, 'aftersale'),
        <String, dynamic>{'revision': record.revision, 'reason': reason.trim()});

Future<RepairRecord> feedbackRepairApi(RepairRecord record, String content) =>
    _repairAction(HttpPath.repairAction(record.id, 'feedback'),
        <String, dynamic>{'revision': record.revision, 'content': content.trim()});

/// 住户发起改约：必须先电话告知师傅；师傅同意后生效。
Future<RepairRecord> proposeRescheduleApi(
        RepairRecord record, String slot, String reason, {RequestDio? client}) =>
    _repairAction(HttpPath.repairAction(record.id, 'reschedule'), <String, dynamic>{
      'revision': record.revision,
      'slot': slot,
      'reason': reason.trim(),
      'notified': true,
    }, client: client);

/// 住户回应师傅发起的改约。
Future<RepairRecord> respondRescheduleApi(RepairRecord record,
        {required bool accept, String reason = '', RequestDio? client}) =>
    _repairAction(HttpPath.repairAction(record.id, 'reschedule'), <String, dynamic>{
      'revision': record.revision,
      'accept': accept,
      'reason': reason.trim(),
    }, method: 'PUT', client: client);

Future<RepairRecord> _repairAction(String path, Map<String, dynamic> body,
    {String method = 'POST', RequestDio? client}) async {
  _invalidateRepairPreloads();
  try {
    final dynamic data = method == 'PUT'
        ? await (client ?? requestDio).put(path, data: body)
        : await (client ?? requestDio).post(path, data: body);
    return RepairRecord.fromJson(asMap(data, '报修'));
  } finally {
    _invalidateRepairPreloads();
  }
}
