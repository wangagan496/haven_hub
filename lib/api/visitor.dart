import '../constant/index.dart';
import '../models/visitor.dart';
import '../utils/json_utils.dart';
import '../utils/mutation_list.dart';
import '../utils/request_dio.dart';
import '../utils/submission_id.dart';

final MutationList<VisitorRecord> _visitorChanges =
    MutationList(VisitorRecord.fromJson);

typedef VisitorListLoader = Future<List<VisitorRecord>> Function();
typedef VisitorDetailLoader = Future<VisitorRecord> Function(String id);
typedef SubmitVisitorLoader = Future<void> Function(VisitorRecord record);

Future<List<VisitorRecord>> getVisitorListApi({RequestDio? client}) =>
    _visitorChanges.load(() => _fetchVisitorList(client ?? requestDio));

Future<List<VisitorRecord>> _fetchVisitorList(RequestDio client) async {
  final dynamic data = await client.get(HttpPath.visitor);
  return readRows(data, '访客记录')
      .map((dynamic item) => VisitorRecord.fromJson(asMap(item, '访客记录')))
      .toList(growable: false);
}

Future<VisitorRecord> getVisitorDetailApi(String id) async {
  final dynamic data = await requestDio.get(HttpPath.visitorDetail(id));
  return VisitorRecord.fromJson(asMap(data, '访客详情'));
}

Future<void> submitVisitorApi(VisitorRecord record, {RequestDio? client}) =>
    _visitorChanges.write(() async {
      if (record.submissionId.isNotEmpty) _checkReceipt(record.submissionId);
      final dynamic data = await (client ?? requestDio)
          .post(HttpPath.visitor, data: record.toJson());
      if (record.submissionId.isNotEmpty &&
          (data is! Map ||
              data['createdId'] is! String ||
              (data['createdId'] as String).trim().isEmpty)) {
        throw const FormatException('未收到访客邀请编号，请查看提交结果');
      }
      return data;
    });

Future<VisitorSubmissionResult> getVisitorSubmissionApi(String id,
    {RequestDio? client}) async {
  _checkReceipt(id);
  final dynamic data =
      await (client ?? requestDio).get(HttpPath.visitorSubmission(id));
  return VisitorSubmissionResult.fromJson(asMap(data, '访客提交结果'));
}

Future<VisitorSubmissionResult> closeVisitorSubmissionApi(String id,
    {RequestDio? client}) async {
  _checkReceipt(id);
  final dynamic data =
      await (client ?? requestDio).put(HttpPath.closeVisitorSubmission(id));
  final result = VisitorSubmissionResult.fromJson(asMap(data, '访客提交结果'));
  if (result.state == VisitorSubmissionState.unknown) {
    throw const FormatException('尚未确认停止，请继续查看提交结果');
  }
  return result;
}

void _checkReceipt(String id) {
  if (!isSubmissionId(id)) throw const FormatException('访客提交回执无效');
}
