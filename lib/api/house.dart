import '../constant/index.dart';
import '../utils/request_dio.dart';

typedef HouseListLoader = Future<List<Map<String, dynamic>>> Function();

Future<List<Map<String, dynamic>>> getHouseListApi() async {
  final dynamic data = await requestDio.get(HttpPath.houseList);
  if (data is! List<dynamic>) {
    throw const FormatException('房屋列表数据格式不正确');
  }

  final List<Map<String, dynamic>> houses = <Map<String, dynamic>>[];
  for (final dynamic item in data) {
    if (item is! Map<dynamic, dynamic>) {
      throw const FormatException('房屋信息数据格式不正确');
    }
    houses.add(Map<String, dynamic>.from(item));
  }
  return List<Map<String, dynamic>>.unmodifiable(houses);
}
