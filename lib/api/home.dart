import '../constant/index.dart';
import '../models/notice_data.dart';
import '../utils/request_dio.dart';

typedef AnnouncementLoader = Future<List<NoticeData>> Function();
typedef AnnouncementDetailLoader = Future<NoticeData> Function(String id);

Future<List<NoticeData>> getAnnouncementListApi() async {
  final dynamic data = await requestDio.get(HttpPath.announcement);
  if (data is! List<dynamic>) {
    throw const FormatException('社区公告列表数据格式不正确');
  }

  return data.map((dynamic item) {
    if (item is! Map<dynamic, dynamic>) {
      throw const FormatException('Announcement item has an invalid format');
    }
    return NoticeData.fromJson(Map<String, dynamic>.from(item));
  }).toList(growable: false);
}

Future<NoticeData> getAnnouncementDetailApi(String id) async {
  final dynamic data = await requestDio.get(
    HttpPath.announcementDetail(id),
  );
  if (data is! Map<dynamic, dynamic>) {
    throw const FormatException('社区公告详情数据格式不正确');
  }

  return NoticeData.fromJson(Map<String, dynamic>.from(data));
}
