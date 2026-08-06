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
    this.ipAddress,
    this.isIpBased = false,
  });

  final String address;
  final List<NearbyCommunity> communities;
  final String? ipAddress;
  final bool isIpBased;
}

typedef LocationLookup = Future<LocationLookupResult> Function(
  double latitude,
  double longitude, {
  required bool isMocked,
});

typedef TencentExternalGet = Future<dynamic> Function(
  String url, {
  Map<String, dynamic>? params,
});

typedef IpLocationLookup = Future<LocationLookupResult> Function();

const List<({String keyword, int autoExtend})> _nearbySearchAttempts =
    <({String keyword, int autoExtend})>[
  (keyword: '小区', autoExtend: 0),
  (keyword: '小区', autoExtend: 1),
  (keyword: '社区', autoExtend: 1),
  (keyword: '住宅区', autoExtend: 1),
  (keyword: '村', autoExtend: 1),
];

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

  final List<NearbyCommunity> communities =
      await searchTencentNearbyCommunities(
    gcjLatitude,
    gcjLongitude,
    key: key,
  );

  return LocationLookupResult(
    address: address,
    communities: List<NearbyCommunity>.unmodifiable(communities),
  );
}

Future<LocationLookupResult> getTencentIpLocationInfo({
  TencentExternalGet externalGet = _getTencentExternal,
  String? apiKey,
}) async {
  final String key = (apiKey ?? GlobalVariable.tencentMapKey).trim();
  if (key.isEmpty) {
    throw const FormatException(
      '未配置腾讯位置服务 Key，请使用 TENCENT_MAP_KEY 编译参数',
    );
  }

  final dynamic rawData = await externalGet(
    HttpPath.tencentIpLocation,
    params: <String, dynamic>{
      'key': key,
      'output': 'json',
    },
  );
  final Map<String, dynamic> body = _requireTencentSuccess(
    rawData,
    fallbackMessage: '腾讯 IP 定位失败',
  );
  final dynamic rawResult = body['result'];
  if (rawResult is! Map<dynamic, dynamic>) {
    throw const FormatException('腾讯 IP 定位响应格式不正确');
  }

  final Map<String, dynamic> result = Map<String, dynamic>.from(rawResult);
  final dynamic rawLocation = result['location'];
  final dynamic rawAdInfo = result['ad_info'];
  if (rawLocation is! Map<dynamic, dynamic> ||
      rawAdInfo is! Map<dynamic, dynamic>) {
    throw const FormatException('腾讯 IP 定位结果缺少位置或行政区划信息');
  }

  final Map<String, dynamic> location = Map<String, dynamic>.from(rawLocation);
  final double? latitude = _toDouble(location['lat']);
  final double? longitude = _toDouble(location['lng']);
  if (latitude == null || longitude == null) {
    throw const FormatException('腾讯 IP 定位结果缺少经纬度');
  }
  _validateCoordinate(latitude, longitude);

  final Map<String, dynamic> adInfo = Map<String, dynamic>.from(rawAdInfo);
  final List<String> addressParts = <String>[
    adInfo['nation']?.toString().trim() ?? '',
    adInfo['province']?.toString().trim() ?? '',
    adInfo['city']?.toString().trim() ?? '',
    adInfo['district']?.toString().trim() ?? '',
  ].where((String value) => value.isNotEmpty).toList(growable: false);
  if (addressParts.isEmpty) {
    throw const FormatException('腾讯 IP 定位结果缺少行政区划');
  }

  return LocationLookupResult(
    address: addressParts.join(' '),
    communities: const <NearbyCommunity>[],
    ipAddress: result['ip']?.toString().trim(),
    isIpBased: true,
  );
}

Future<dynamic> _getTencentExternal(
  String url, {
  Map<String, dynamic>? params,
}) {
  return requestDio.getExternal(url, params: params);
}

@visibleForTesting
Future<List<NearbyCommunity>> searchTencentNearbyCommunities(
  double latitude,
  double longitude, {
  required String key,
  TencentExternalGet externalGet = _getTencentExternal,
}) async {
  for (final ({String keyword, int autoExtend}) attempt
      in _nearbySearchAttempts) {
    final dynamic searchData = await externalGet(
      HttpPath.tencentPlaceSearch,
      params: <String, dynamic>{
        'key': key,
        'keyword': attempt.keyword,
        // 腾讯地点搜索 radius 最大为 1000 米；auto_extend=1 会按
        // 1、2、5 公里逐级扩大，仍为空时继续扩大到城市范围。
        'boundary': 'nearby($latitude,$longitude,1000,${attempt.autoExtend})',
        'orderby': '_distance',
        'page_size': 10,
        'page_index': 1,
        'output': 'json',
      },
    );
    if (kDebugMode) {
      // 课程要求在调试控制台查看腾讯周边搜索的原始返回值。
      // ignore: avoid_print
      print(
        '腾讯周边搜索返回值'
        '（关键词：${attempt.keyword}，自动扩大：${attempt.autoExtend}）：'
        '$searchData',
      );
    }

    final List<NearbyCommunity> communities =
        parseTencentNearbyCommunities(searchData);
    if (communities.isNotEmpty) {
      return communities;
    }
  }

  return const <NearbyCommunity>[];
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
