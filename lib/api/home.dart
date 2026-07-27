import '../constant/index.dart';
import '../utils/request_dio.dart';

typedef AnnouncementLoader = Future<List<Map<String, dynamic>>> Function();

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
