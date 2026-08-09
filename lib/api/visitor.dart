import '../constant/index.dart';
import '../models/visitor.dart';
import '../utils/json_utils.dart';
import '../utils/request_dio.dart';

typedef VisitorListLoader = Future<List<VisitorRecord>> Function();
typedef VisitorDetailLoader = Future<VisitorRecord> Function(String id);
typedef SubmitVisitorLoader = Future<void> Function(VisitorRecord record);

Future<List<VisitorRecord>> getVisitorListApi() async {
  final dynamic data = await requestDio.get(HttpPath.visitor);
  return readRows(data, '访客记录')
      .map((dynamic item) => VisitorRecord.fromJson(asMap(item, '访客记录')))
      .toList(growable: false);
}

Future<VisitorRecord> getVisitorDetailApi(String id) async {
  final dynamic data = await requestDio.get(HttpPath.visitorDetail(id));
  return VisitorRecord.fromJson(asMap(data, '访客详情'));
}

Future<void> submitVisitorApi(VisitorRecord record) =>
    requestDio.post(HttpPath.visitor, data: record.toJson());
