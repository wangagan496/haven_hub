import '../constant/index.dart';
import '../models/visitor.dart';
import '../utils/json_utils.dart';
import '../utils/mutation_list.dart';
import '../utils/request_dio.dart';

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
    _visitorChanges.write(() =>
        (client ?? requestDio).post(HttpPath.visitor, data: record.toJson()));
