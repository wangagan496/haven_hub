import 'package:flutter/foundation.dart';

import '../constant/index.dart';
import '../models/building_info.dart';
import '../utils/app_exception.dart';
import '../utils/request_dio.dart';

class NearbyCommunity {
  const NearbyCommunity({
    required this.name,
    required this.address,
    this.id = '',
    this.latitude,
    this.longitude,
  });

  final String name;
  final String address;
  final String id;
  final double? latitude;
  final double? longitude;
}

typedef PlaceExternalGet = Future<dynamic> Function(
  String url, {
  Map<String, dynamic>? params,
});

class TencentBuilding {
  const TencentBuilding({
    required this.id,
    required this.name,
    required this.address,
    required this.label,
  });

  final String id;
  final String name;
  final String address;

  /// 仅移除名称中已有的小区前缀，不推算楼号、单元或房间。
  final String label;
}

class TencentBuildingPage {
  const TencentBuildingPage({
    required this.buildings,
    required this.poiIds,
    this.hasMore = false,
    this.reachedLimit = false,
  });

  final List<TencentBuilding> buildings;
  final List<String> poiIds;
  final bool hasMore;
  final bool reachedLimit;
}

typedef CommunityBuildingLookup = Future<TencentBuildingPage> Function(
  BuildingInfo community,
  int page,
);

Future<TencentBuildingPage> searchTencentCommunityBuildings(
  BuildingInfo community,
  int page, {
  String? apiKey,
  TencentExternalGet externalGet = _getTencentExternal,
}) async {
  final double? latitude = community.latitude;
  final double? longitude = community.longitude;
  if (!community.hasCommunity || latitude == null || longitude == null) {
    throw const FormatException('所选小区缺少地图坐标，请重新选择小区或手动填写楼栋');
  }
  _validateCoordinate(latitude, longitude);
  if (page < 1 || page > 10) {
    throw const FormatException('楼栋查询页码超出地图服务范围');
  }
  final String key = (apiKey ?? GlobalVariable.tencentMapKey).trim();
  if (key.isEmpty) throw const FormatException('未配置腾讯位置服务 Key');
  final dynamic response = await externalGet(
    HttpPath.tencentPlaceSearch,
    params: <String, dynamic>{
      'key': key,
      'keyword': _communitySearchName(community.name),
      // 无结果时由腾讯地点搜索逐级扩大；返回后仍按所选小区筛选。
      'boundary': 'nearby($latitude,$longitude,1000,1)',
      // 实际住宅楼栋常归入房产小区附属；281200 为商务楼宇。
      // 返回后仍校验名称和分类，不能把周边地点当作小区库存。
      'filter': 'category=288000,281200',
      'added_fields': 'category_code',
      'orderby': '_distance',
      'page_size': 20,
      'page_index': page,
      'output': 'json',
    },
  );
  return parseTencentCommunityBuildings(response, community, page);
}

/// 合并腾讯和高德的真实楼栋地点，未配置高德 Key 时保持原有腾讯查询。
Future<TencentBuildingPage> searchCommunityBuildings(
  BuildingInfo community,
  int page, {
  String? tencentKey,
  String? amapKey,
  TencentExternalGet tencentGet = _getTencentExternal,
  PlaceExternalGet amapGet = _getTencentExternal,
}) async {
  final String key = (amapKey ?? GlobalVariable.amapWebKey).trim();
  if (key.isEmpty) {
    return searchTencentCommunityBuildings(community, page,
        apiKey: tencentKey, externalGet: tencentGet);
  }

  Future<({TencentBuildingPage? page, Object? error})> attempt(
      Future<TencentBuildingPage> Function() lookup) async {
    try {
      return (page: await lookup(), error: null);
    } on Object catch (error) {
      return (page: null, error: error);
    }
  }

  final results =
      await Future.wait(<Future<({TencentBuildingPage? page, Object? error})>>[
    attempt(() => searchTencentCommunityBuildings(community, page,
        apiKey: tencentKey, externalGet: tencentGet)),
    attempt(() => searchAmapCommunityBuildings(community, page,
        apiKey: key, externalGet: amapGet)),
  ]);
  if (results[0].error != null && results[1].error != null) {
    throw results[0].error!;
  }
  final TencentBuildingPage? primary = results[0].page;
  final TencentBuildingPage? supplemental = results[1].page;
  final Set<String> labels = <String>{};
  final List<TencentBuilding> buildings = <TencentBuilding>[
    for (final TencentBuilding building in <TencentBuilding>[
      ...?primary?.buildings,
      ...?supplemental?.buildings,
    ])
      if (labels.add(building.label.trim().toLowerCase())) building,
  ];
  return TencentBuildingPage(
    buildings: List<TencentBuilding>.unmodifiable(buildings),
    poiIds: List<String>.unmodifiable(<String>[
      ...?primary?.poiIds,
      ...?supplemental?.poiIds,
    ]),
    hasMore: (primary?.hasMore ?? false) || (supplemental?.hasMore ?? false),
    reachedLimit: (primary?.reachedLimit ?? false) ||
        (supplemental?.reachedLimit ?? false),
  );
}

Future<TencentBuildingPage> searchAmapCommunityBuildings(
  BuildingInfo community,
  int page, {
  String? apiKey,
  PlaceExternalGet externalGet = _getTencentExternal,
}) async {
  final double? latitude = community.latitude;
  final double? longitude = community.longitude;
  if (!community.hasCommunity || latitude == null || longitude == null) {
    throw const FormatException('所选小区缺少地图坐标，请重新选择小区或手动填写楼栋');
  }
  _validateCoordinate(latitude, longitude);
  if (page < 1 || page > 10) {
    throw const FormatException('楼栋查询页码超出地图服务范围');
  }
  final String key = (apiKey ?? GlobalVariable.amapWebKey).trim();
  if (key.isEmpty) throw const FormatException('未配置高德 Web 服务 Key');
  final dynamic response = await externalGet(
    HttpPath.amapPlaceAround,
    params: <String, dynamic>{
      'key': key,
      'location': '$longitude,$latitude',
      'keywords': _communitySearchName(community.name),
      'radius': 5000,
      'sortrule': 'distance',
      'page_size': 25,
      'page_num': page,
      'output': 'json',
    },
  );
  return parseAmapCommunityBuildings(response, community, page);
}

String _communitySearchName(String name) {
  final String trimmed = name.trim();
  final String stem = trimmed.replaceFirst(RegExp(r'小区$'), '').trim();
  return stem.length >= 2 ? stem : trimmed;
}

@visibleForTesting
TencentBuildingPage parseTencentCommunityBuildings(
  dynamic response,
  BuildingInfo community,
  int page,
) {
  final Map<String, dynamic> body = _requireTencentSuccess(
    response,
    fallbackMessage: '楼栋查询失败',
  );
  final dynamic raw = body['data'];
  final int? count = int.tryParse(body['count']?.toString() ?? '');
  if (raw is! List<dynamic> || count == null || count < 0) {
    throw const FormatException('腾讯楼栋查询响应格式不正确');
  }
  final List<TencentBuilding> buildings = <TencentBuilding>[];
  final Set<String> ids = <String>{};
  for (final dynamic value in raw) {
    if (value is! Map<dynamic, dynamic>) continue;
    final String id = value['id']?.toString().trim() ?? '';
    final String title = value['title']?.toString().trim() ?? '';
    final String address = value['address']?.toString().trim() ?? '';
    if (id.isEmpty || !ids.add(id) || title.isEmpty) continue;
    if (id == community.communityId) continue;
    final String category = value['category']?.toString() ?? '';
    final String code = value['category_code']?.toString() ?? '';
    final bool isBuildingCategory = code == '288000' ||
        code == '281200' ||
        category.contains('房产小区附属') ||
        category.contains('住宅楼栋') ||
        category.contains('商务楼宇');
    if (!isBuildingCategory ||
        RegExp(r'楼门|出入口|入口|出口|停车|车库|商铺|店|幼儿园').hasMatch(title)) {
      continue;
    }
    final String? label = _buildingLabel(community, title, address);
    if (label == null) continue;
    buildings.add(TencentBuilding(
      id: id,
      name: title,
      address: address,
      label: label,
    ));
  }
  return TencentBuildingPage(
    buildings: List<TencentBuilding>.unmodifiable(buildings),
    poiIds: List<String>.unmodifiable(ids),
    hasMore: raw.length >= 20 && page * 20 < count && page < 10,
    reachedLimit: count > 200 && page == 10,
  );
}

@visibleForTesting
TencentBuildingPage parseAmapCommunityBuildings(
  dynamic response,
  BuildingInfo community,
  int page,
) {
  if (response is! Map<dynamic, dynamic>) {
    throw const FormatException('高德楼栋查询响应格式不正确');
  }
  final Map<String, dynamic> body = Map<String, dynamic>.from(response);
  if (body['status']?.toString() != '1') {
    throw BusinessException(
      body['info']?.toString() ?? '高德楼栋查询失败',
      code: int.tryParse(body['infocode']?.toString() ?? ''),
    );
  }
  final dynamic raw = body['pois'];
  if (raw is! List<dynamic>) {
    throw const FormatException('高德楼栋查询响应格式不正确');
  }
  final List<TencentBuilding> buildings = <TencentBuilding>[];
  final Set<String> poiIds = <String>{};
  for (final dynamic item in raw) {
    if (item is! Map<dynamic, dynamic>) continue;
    final String id = item['id']?.toString().trim() ?? '';
    final String title = item['name']?.toString().trim() ?? '';
    final String address = item['address']?.toString().trim() ?? '';
    if (id.isEmpty || title.isEmpty || !poiIds.add('amap:$id')) continue;
    if (community.communityId == 'amap:$id') continue;
    final String? label = _buildingLabel(community, title, address);
    if (label == null) continue;
    buildings.add(TencentBuilding(
      id: 'amap:$id',
      name: title,
      address: address,
      label: label,
    ));
  }
  return TencentBuildingPage(
    buildings: List<TencentBuilding>.unmodifiable(buildings),
    poiIds: List<String>.unmodifiable(poiIds),
    hasMore: raw.length >= 25 && page < 10,
    reachedLimit: raw.length >= 25 && page == 10,
  );
}

String? _buildingLabel(BuildingInfo community, String title, String address) {
  final String name = community.name.trim();
  final String stem = _communitySearchName(name);
  if (RegExp(r'楼门|出入口|入口|出口|停车|车库|商铺|店|幼儿园').hasMatch(title)) {
    return null;
  }
  String label = title;
  if (title.startsWith(name)) {
    label = title.substring(name.length);
  } else if (title.startsWith(stem)) {
    label = title.substring(stem.length);
  } else if (!address.contains(name) || name.length < 2) {
    return null;
  }
  label = label.replaceFirst(RegExp(r'^[\s\-—_·]+'), '').trim();
  if (!RegExp(r'^(第)?([0-9一二三四五六七八九十百零〇两]+|[A-Za-z][0-9]*)\s*(号楼|栋|幢|座|号)')
          .hasMatch(label) ||
      label.length > 100) {
    return null;
  }
  return label;
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

  final List<NearbyCommunity> communities = await searchNearbyCommunities(
    gcjLatitude,
    gcjLongitude,
    tencentKey: key,
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
  final String district = adInfo['district']?.toString().trim() ?? '';
  final List<String> addressParts = <String>[
    adInfo['nation']?.toString().trim() ?? '',
    adInfo['province']?.toString().trim() ?? '',
    adInfo['city']?.toString().trim() ?? '',
    district,
  ].where((String value) => value.isNotEmpty).toList(growable: false);
  if (addressParts.isEmpty) {
    throw const FormatException('腾讯 IP 定位结果缺少行政区划');
  }

  final List<NearbyCommunity> communities = await searchNearbyCommunities(
    latitude,
    longitude,
    tencentKey: key,
    tencentGet: externalGet,
  );

  return LocationLookupResult(
    address: addressParts.join(' '),
    communities: List<NearbyCommunity>.unmodifiable(communities),
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

/// 合并两家地图的小区结果；没有高德 Key 时沿用腾讯查询。
Future<List<NearbyCommunity>> searchNearbyCommunities(
  double latitude,
  double longitude, {
  required String tencentKey,
  String? amapKey,
  TencentExternalGet tencentGet = _getTencentExternal,
  PlaceExternalGet amapGet = _getTencentExternal,
}) async {
  final String key = (amapKey ?? GlobalVariable.amapWebKey).trim();
  if (key.isEmpty) {
    return searchTencentNearbyCommunities(latitude, longitude,
        key: tencentKey, externalGet: tencentGet);
  }

  Future<({List<NearbyCommunity>? communities, Object? error})> attempt(
      Future<List<NearbyCommunity>> Function() lookup) async {
    try {
      return (communities: await lookup(), error: null);
    } on Object catch (error) {
      return (communities: null, error: error);
    }
  }

  final results = await Future
      .wait(<Future<({List<NearbyCommunity>? communities, Object? error})>>[
    attempt(() => searchTencentNearbyCommunities(latitude, longitude,
        key: tencentKey, externalGet: tencentGet)),
    attempt(() => searchAmapNearbyCommunities(latitude, longitude,
        apiKey: key, externalGet: amapGet)),
  ]);
  if (results[0].error != null && results[1].error != null) {
    throw results[0].error!;
  }

  final List<NearbyCommunity> communities = <NearbyCommunity>[];
  for (final NearbyCommunity candidate in <NearbyCommunity>[
    ...?results[0].communities,
    ...?results[1].communities,
  ]) {
    if (!communities.any((NearbyCommunity existing) =>
        _sameNearbyCommunity(existing, candidate))) {
      communities.add(candidate);
    }
  }
  return List<NearbyCommunity>.unmodifiable(communities);
}

bool _sameNearbyCommunity(NearbyCommunity first, NearbyCommunity second) {
  String normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), '').trim().toLowerCase();
  if (normalize(first.name) != normalize(second.name)) return false;
  if (first.latitude != null &&
      first.longitude != null &&
      second.latitude != null &&
      second.longitude != null) {
    return (first.latitude! - second.latitude!).abs() < 0.002 &&
        (first.longitude! - second.longitude!).abs() < 0.002;
  }
  return normalize(first.address) == normalize(second.address);
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

/// 使用高德周边搜索补齐腾讯没有收录的小区；未配置 Key 时安全跳过。
Future<List<NearbyCommunity>> searchAmapNearbyCommunities(
  double latitude,
  double longitude, {
  String? apiKey,
  PlaceExternalGet externalGet = _getTencentExternal,
}) async {
  final String key = (apiKey ?? GlobalVariable.amapWebKey).trim();
  if (key.isEmpty) return const <NearbyCommunity>[];
  _validateCoordinate(latitude, longitude);
  final dynamic response = await externalGet(
    HttpPath.amapPlaceAround,
    params: <String, dynamic>{
      'key': key,
      'location': '$longitude,$latitude',
      'keywords': '小区|社区|住宅区|村',
      'types': '120000',
      'radius': 5000,
      'sortrule': 'distance',
      'page_size': 25,
      'page_num': 1,
      'output': 'json',
    },
  );
  return parseAmapNearbyCommunities(response);
}

@visibleForTesting
List<NearbyCommunity> parseAmapNearbyCommunities(dynamic response) {
  if (response is! Map<dynamic, dynamic>) {
    throw const FormatException('高德周边搜索响应格式不正确');
  }
  final Map<String, dynamic> body = Map<String, dynamic>.from(response);
  if (body['status']?.toString() != '1') {
    throw BusinessException(
      body['info']?.toString() ?? '高德周边搜索失败',
      code: int.tryParse(body['infocode']?.toString() ?? ''),
    );
  }
  final dynamic rawPois = body['pois'];
  if (rawPois is! List<dynamic>) {
    throw const FormatException('高德周边搜索响应格式不正确');
  }
  final List<NearbyCommunity> result = <NearbyCommunity>[];
  for (final dynamic raw in rawPois) {
    if (raw is! Map<dynamic, dynamic>) continue;
    final Map<String, dynamic> poi = Map<String, dynamic>.from(raw);
    final String name = poi['name']?.toString().trim() ?? '';
    final String address = poi['address']?.toString().trim() ?? '';
    final String id = poi['id']?.toString().trim() ?? '';
    if (name.isEmpty || id.isEmpty) continue;
    final List<String> coordinates =
        poi['location']?.toString().split(',') ?? const <String>[];
    if (coordinates.length != 2) continue;
    final double? longitude = double.tryParse(coordinates[0]);
    final double? latitude = double.tryParse(coordinates[1]);
    if (latitude == null ||
        longitude == null ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      continue;
    }
    result.add(NearbyCommunity(
      name: name,
      address: address,
      id: 'amap:$id',
      latitude: latitude,
      longitude: longitude,
    ));
  }
  return result.take(10).toList(growable: false);
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
      id: poi['id']?.toString().trim() ?? '',
      latitude: poi['location'] is Map<dynamic, dynamic>
          ? _toDouble((poi['location'] as Map<dynamic, dynamic>)['lat'])
          : null,
      longitude: poi['location'] is Map<dynamic, dynamic>
          ? _toDouble((poi['location'] as Map<dynamic, dynamic>)['lng'])
          : null,
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
