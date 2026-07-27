import '../constant/index.dart';
import '../utils/request_dio.dart';

typedef AnnouncementLoader = Future<List<Map<String, dynamic>>> Function();
typedef AnnouncementDetailLoader = Future<Map<String, dynamic>> Function(
  String id,
);

Future<List<Map<String, dynamic>>> getAnnouncementListApi() async {
  final dynamic data = await requestDio.get(HttpPath.announcement);
  if (data is! List<dynamic>) {
    throw const FormatException('社区公告列表数据格式不正确');
  }

  return data
      .map(
        (dynamic item) =>
            Map<String, dynamic>.from(item as Map<dynamic, dynamic>),
      )
      .toList(growable: false);
}

Future<Map<String, dynamic>> getAnnouncementDetailApi(String id) async {
  final dynamic data = await requestDio.get(
    HttpPath.announcementDetail(id),
  );
  if (data is! Map<dynamic, dynamic>) {
    throw const FormatException('社区公告详情数据格式不正确');
  }

  return Map<String, dynamic>.from(data);
}
