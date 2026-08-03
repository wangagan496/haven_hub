import 'package:flutter/foundation.dart';

import '../constant/index.dart';
import '../utils/app_exception.dart';
import '../utils/request_dio.dart';

class NearbyCommunity {
  const NearbyCommunity({
    required this.name,
    required this.address,
  });

  final String name;
  final String address;
}

class LocationLookupResult {
  const LocationLookupResult({
    required this.address,
    required this.communities,
  });

  final String address;
  final List<NearbyCommunity> communities;
}

typedef LocationLookup = Future<LocationLookupResult> Function(
  double latitude,
  double longitude, {
  required bool isMocked,
});

Future<LocationLookupResult> getTencentLocationInfo(
  double latitude,
  double longitude, {
  required bool isMocked,
}) async {
  _validateCoordinate(latitude, longitude);

  final String key = GlobalVariable.tencentMapKey.trim();
  if (key.isEmpty) {
    throw const FormatException(
      '未配置腾讯位置服务 Key，请使用 TENCENT_MAP_KEY 编译参数',
    );
  }

  double gcjLatitude = latitude;
  double gcjLongitude = longitude;
  if (shouldTranslateTencentCoordinate(isMocked: isMocked)) {
    final dynamic translatedData = await requestDio.getExternal(
      HttpPath.tencentCoordinateTranslate,
      params: <String, dynamic>{
        'locations': '$latitude,$longitude',
        'type': 1,
        'key': key,
        'output': 'json',
      },
    );
    final Map<String, dynamic> translated = _requireTencentSuccess(
      translatedData,
      fallbackMessage: '坐标转换失败',
    );
    final List<dynamic> locations =
        translated['locations'] as List<dynamic>? ?? const <dynamic>[];
    if (locations.isEmpty || locations.first is! Map<dynamic, dynamic>) {
      throw const FormatException('腾讯坐标转换响应格式不正确');
    }
    final Map<String, dynamic> point =
        Map<String, dynamic>.from(locations.first as Map<dynamic, dynamic>);
    final double? translatedLatitude = _toDouble(point['lat']);
    final double? translatedLongitude = _toDouble(point['lng']);
    if (translatedLatitude == null || translatedLongitude == null) {
      throw const FormatException('腾讯坐标转换结果缺少经纬度');
    }
    gcjLatitude = translatedLatitude;
    gcjLongitude = translatedLongitude;
  }

  final dynamic reverseData = await requestDio.getExternal(
    HttpPath.tencentReverseGeocode,
    params: <String, dynamic>{
      'location': '$gcjLatitude,$gcjLongitude',
      'key': key,
      'output': 'json',
    },
  );
  final Map<String, dynamic> reverse = _requireTencentSuccess(
    reverseData,
    fallbackMessage: '逆地址解析失败',
  );
  final dynamic rawResult = reverse['result'];
  if (rawResult is! Map<dynamic, dynamic>) {
    throw const FormatException('腾讯逆地址解析响应格式不正确');
  }
  final Map<String, dynamic> result = Map<String, dynamic>.from(rawResult);
  final String address = _readAddress(result);

  final dynamic searchData = await requestDio.getExternal(
    HttpPath.tencentPlaceSearch,
    params: <String, dynamic>{
      'key': key,
      'keyword': '小区',
      'boundary': 'nearby($gcjLatitude,$gcjLongitude,1000,0)',
      'orderby': '_distance',
      'page_size': 10,
      'page_index': 1,
      'output': 'json',
    },
  );
  if (kDebugMode) {
    // 课程要求在调试控制台查看腾讯周边搜索的原始返回值。
    // ignore: avoid_print
    print('腾讯周边搜索返回值：$searchData');
  }
  final List<NearbyCommunity> communities =
      parseTencentNearbyCommunities(searchData);

  return LocationLookupResult(
    address: address,
    communities: List<NearbyCommunity>.unmodifiable(communities),
  );
}

bool shouldTranslateTencentCoordinate({
  required bool isMocked,
  String coordinateSystem = GlobalVariable.locationCoordinateSystem,
}) {
  return switch (coordinateSystem.trim().toLowerCase()) {
    'auto' => !isMocked,
    'wgs84' => true,
    'gcj02' => false,
    _ => throw const FormatException(
        'LOCATION_COORDINATE_SYSTEM 仅支持 auto、wgs84 或 gcj02',
      ),
  };
}

void _validateCoordinate(double latitude, double longitude) {
  if (!latitude.isFinite || latitude < -90 || latitude > 90) {
    throw const FormatException('纬度无效，请确认没有把经度和纬度填反');
  }
  if (!longitude.isFinite || longitude < -180 || longitude > 180) {
    throw const FormatException('经度无效，请检查坐标拾取器中的坐标');
  }
}

Map<String, dynamic> _requireTencentSuccess(
  dynamic data, {
  required String fallbackMessage,
}) {
  if (data is! Map<dynamic, dynamic>) {
    throw const FormatException('腾讯位置服务响应格式不正确');
  }
  final Map<String, dynamic> body = Map<String, dynamic>.from(data);
  final int? status = int.tryParse(body['status']?.toString() ?? '');
  if (status != 0) {
    throw BusinessException(
      body['message']?.toString() ?? fallbackMessage,
      code: status,
    );
  }
  return body;
}

String _readAddress(Map<String, dynamic> result) {
  final dynamic formatted = result['formatted_addresses'];
  if (formatted is Map<dynamic, dynamic>) {
    final String recommend = formatted['recommend']?.toString().trim() ?? '';
    if (recommend.isNotEmpty) return recommend;
  }
  final String address = result['address']?.toString().trim() ?? '';
  if (address.isEmpty) {
    throw const FormatException('腾讯位置服务未返回当前地址');
  }
  return address;
}

@visibleForTesting
List<NearbyCommunity> parseTencentNearbyCommunities(dynamic data) {
  final Map<String, dynamic> search = _requireTencentSuccess(
    data,
    fallbackMessage: '周边社区搜索失败',
  );
  final dynamic rawPois = search['data'];
  if (rawPois is! List<dynamic>) {
    throw const FormatException('腾讯周边搜索响应格式不正确');
  }
  return _readCommunities(rawPois);
}

List<NearbyCommunity> _readCommunities(dynamic rawPois) {
  if (rawPois is! List<dynamic>) return const <NearbyCommunity>[];

  final List<NearbyCommunity> all = <NearbyCommunity>[];
  final List<NearbyCommunity> residential = <NearbyCommunity>[];
  for (final dynamic rawPoi in rawPois) {
    if (rawPoi is! Map<dynamic, dynamic>) continue;
    final Map<String, dynamic> poi = Map<String, dynamic>.from(rawPoi);
    final String name = poi['title']?.toString().trim() ?? '';
    if (name.isEmpty) continue;
    final String address = poi['address']?.toString().trim() ?? '';
    final NearbyCommunity community = NearbyCommunity(
      name: name,
      address: address,
    );
    all.add(community);

    final String category = poi['category']?.toString() ?? '';
    if (category.contains('小区') ||
        category.contains('住宅') ||
        category.contains('房产')) {
      residential.add(community);
    }
  }
  final List<NearbyCommunity> result =
      residential.isNotEmpty ? residential : all;
  return result.take(10).toList(growable: false);
}

double? _toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}
