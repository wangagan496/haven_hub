import '../constant/index.dart';
import '../models/repair.dart';
import '../utils/app_exception.dart';
import '../utils/json_utils.dart';
import '../utils/mutation_list.dart';
import '../utils/repair_list_preloader.dart';
import '../utils/request_dio.dart';
import '../utils/token_manager.dart';

final MutationList<RepairRecord> _repairChanges =
    MutationList(RepairRecord.fromJson);

typedef RepairListLoader = Future<List<RepairRecord>> Function();
typedef RepairDetailLoader = Future<RepairRecord> Function(String id);
typedef RepairItemLoader = Future<List<RepairItem>> Function();
typedef RepairSlotsLoader = Future<RepairSlots> Function({String? date, String? excludeId});

Future<RepairSlots> getRepairSlotsApi({String? date, String? excludeId, RequestDio? client}) async {
  final dynamic data = await (client ?? requestDio).get(HttpPath.repairSlots, params: <String, dynamic>{
    if (date != null && date.isNotEmpty) 'date': date,
    if (excludeId != null && excludeId.isNotEmpty) 'excludeId': excludeId,
  });
  return RepairSlots.fromJson(asMap(data, '上门时段'));
}
/// 返回值为新工单编号时，提交后直接进入详情；其他返回值（如测试替身）回到列表。
typedef SubmitRepairLoader = Future<dynamic> Function(RepairRecord record);
typedef CancelRepairLoader = Future<void> Function(String id);

/// 详情页上住户的各项操作；返回服务端最新工单。
typedef RepairActionLoader = Future<RepairRecord> Function(
    RepairRecord record, RepairAction action);

sealed class RepairAction {
  const RepairAction();
}

final class ConfirmAction extends RepairAction {
  const ConfirmAction();
}

final class RejectAction extends RepairAction {
  const RejectAction(this.reason);
  final String reason;
}

final class AftersaleAction extends RepairAction {
  const AftersaleAction(this.reason);
  final String reason;
}

final class FeedbackAction extends RepairAction {
  const FeedbackAction(this.content);
  final String content;
}

final class RevokeAction extends RepairAction {
  const RevokeAction(this.reason, {required this.notified});
  final String reason;
  final bool notified;
}

final class ProposeAction extends RepairAction {
  const ProposeAction(this.slot, this.reason);
  final String slot;
  final String reason;
}

final class RespondAction extends RepairAction {
  const RespondAction({required this.accept, this.reason = ''});
  final bool accept;
  final String reason;
}

Future<RepairRecord> runRepairAction(RepairRecord record, RepairAction action) =>
    switch (action) {
      ConfirmAction() => confirmRepairApi(record),
      RejectAction(:final String reason) => rejectRepairApi(record, reason),
      AftersaleAction(:final String reason) => applyAftersaleApi(record, reason),
      FeedbackAction(:final String content) => feedbackRepairApi(record, content),
      RevokeAction(:final String reason, :final bool notified) =>
        revokeRepairApi(record, reason: reason, notified: notified),
      ProposeAction(:final String slot, :final String reason) =>
        proposeRescheduleApi(record, slot, reason),
      RespondAction(:final bool accept, :final String reason) =>
        respondRescheduleApi(record, accept: accept, reason: reason),
    };

final RepairListPreloader repairListPreloader =
    RepairListPreloader(loader: getRepairListApi);

Future<void> preloadRepairList() => repairListPreloader.preload();

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

Future<List<RepairItem>> getRepairItemsApi() async {
  final dynamic data = await requestDio.get(HttpPath.repairItem);
  if (data is! List<dynamic>) throw const FormatException('维修项目数据格式不正确');
  return data
      .map((dynamic item) => RepairItem.fromJson(asMap(item, '维修项目')))
      .toList(growable: false);
}

/// 提交报修并返回新工单编号，供提交成功后直接进入详情。
Future<String> submitRepairApi(RepairRecord record, {RequestDio? client}) async {
  if (record.attachment.length > 8) throw const FormatException('现场照片最多8张');
  repairListPreloader.invalidate();
  String createdId = '';
  try {
    await _repairChanges.write(() async {
      final dynamic data =
          await (client ?? requestDio).post(HttpPath.repair, data: record.toJson());
      if (data is Map) createdId = data['createdId']?.toString() ?? '';
      return data;
    });
  } finally {
    repairListPreloader.invalidate();
  }
  return createdId;
}

/// 未接单前直接撤销，返回完整列表（旧契约不变）。师傅接单后请用 [revokeRepairApi]。
Future<void> cancelRepairApi(String id, {RequestDio? client}) async {
  if (id.trim().isEmpty) throw const FormatException('报修参数不正确');
  repairListPreloader.invalidate();
  try {
    await _repairChanges
        .write(() => (client ?? requestDio).put(HttpPath.cancelRepair(id)));
  } finally {
    repairListPreloader.invalidate();
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
  repairListPreloader.invalidate();
  try {
    final dynamic data = method == 'PUT'
        ? await (client ?? requestDio).put(path, data: body)
        : await (client ?? requestDio).post(path, data: body);
    return RepairRecord.fromJson(asMap(data, '报修'));
  } finally {
    repairListPreloader.invalidate();
  }
}
