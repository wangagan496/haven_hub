import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/location.dart';
import 'package:haven_hub/models/building_info.dart';
import 'package:haven_hub/utils/app_exception.dart';

const BuildingInfo selectedCommunity = BuildingInfo(
  name: '榴苑三街小区',
  address: '佛山市榴苑三街16号',
  communityId: 'tencent-community',
  latitude: 23.007933,
  longitude: 113.090276,
);

Map<String, dynamic> amapPois(List<dynamic> pois) =>
    <String, dynamic>{'status': '1', 'pois': pois};

Map<String, dynamic> amapPoi(String id, String name,
        {String address = '佛山市榴苑三街小区',
        String location = '113.090276,23.007933'}) =>
    <String, dynamic>{
      'id': id,
      'name': name,
      'address': address,
      'location': location,
    };

Map<String, dynamic> tencentPois(List<dynamic> pois) =>
    <String, dynamic>{'status': 0, 'count': pois.length, 'data': pois};

Map<String, dynamic> tencentPoi(String id, String title,
        {String category = '房产小区:住宅小区'}) =>
    <String, dynamic>{
      'id': id,
      'title': title,
      'address': '佛山市榴苑三街小区',
      'category': category,
      'location': <String, dynamic>{'lat': 23.007933, 'lng': 113.090276},
    };

void main() {
  test('Amap nearby query sends longitude first and parses coordinates',
      () async {
    Map<String, dynamic>? sent;
    final List<NearbyCommunity> result = await searchAmapNearbyCommunities(
      23.007933,
      113.090276,
      apiKey: 'test-key',
      externalGet: (String url, {Map<String, dynamic>? params}) async {
        sent = params;
        return amapPois(<dynamic>[
          amapPoi('amap-1', '榴苑四街小区'),
          amapPoi('bad', '坐标异常', location: 'invalid'),
          amapPoi('out-of-range', '越界坐标', location: '200,91'),
        ]);
      },
    );
    expect(sent?['location'], '113.090276,23.007933');
    expect(sent?['radius'], 5000);
    expect(result.single.id, 'amap:amap-1');
    expect(result.single.latitude, 23.007933);
    expect(result.single.longitude, 113.090276);
  });

  test('nearby results merge and deduplicate the same physical community',
      () async {
    final List<NearbyCommunity> result = await searchNearbyCommunities(
      23.007933,
      113.090276,
      tencentKey: 'tencent-test',
      amapKey: 'amap-test',
      tencentGet: (String url, {Map<String, dynamic>? params}) async =>
          tencentPois(<dynamic>[
        tencentPoi('qq-1', '榴苑三街小区'),
      ]),
      amapGet: (String url, {Map<String, dynamic>? params}) async =>
          amapPois(<dynamic>[
        amapPoi('gd-1', '榴苑三街小区'),
        amapPoi('gd-2', '榴苑四街小区', location: '113.092276,23.009933'),
      ]),
    );
    expect(result.map((NearbyCommunity value) => value.name),
        <String>['榴苑三街小区', '榴苑四街小区']);
    expect(result.first.id, 'qq-1');
    expect(result.last.id, 'amap:gd-2');
  });

  test('Amap works if Tencent nearby search fails; no key skips Amap',
      () async {
    final List<NearbyCommunity> fallback = await searchNearbyCommunities(
      23.007933,
      113.090276,
      tencentKey: 'tencent-test',
      amapKey: 'amap-test',
      tencentGet: (String url, {Map<String, dynamic>? params}) async =>
          throw const NetworkException('腾讯超时'),
      amapGet: (String url, {Map<String, dynamic>? params}) async =>
          amapPois(<dynamic>[amapPoi('gd-1', '榴苑三街小区')]),
    );
    expect(fallback.single.id, 'amap:gd-1');

    int amapCalls = 0;
    final List<NearbyCommunity> noKey = await searchNearbyCommunities(
      23.007933,
      113.090276,
      tencentKey: 'tencent-test',
      amapKey: '',
      tencentGet: (String url, {Map<String, dynamic>? params}) async =>
          tencentPois(<dynamic>[tencentPoi('qq-1', '榴苑三街小区')]),
      amapGet: (String url, {Map<String, dynamic>? params}) async {
        amapCalls++;
        return amapPois(<dynamic>[]);
      },
    );
    expect(noKey.single.id, 'qq-1');
    expect(amapCalls, 0);
  });

  test('Amap buildings use the selected coordinates and reject unrelated POIs',
      () async {
    Map<String, dynamic>? sent;
    final TencentBuildingPage result = await searchAmapCommunityBuildings(
      selectedCommunity,
      2,
      apiKey: 'test-key',
      externalGet: (String url, {Map<String, dynamic>? params}) async {
        sent = params;
        return amapPois(<dynamic>[
          amapPoi('gd-13', '榴苑三街小区-13座'),
          amapPoi('gd-gate', '榴苑三街小区-南门'),
          amapPoi('gd-other', '邻居小区-7座', address: '佛山市邻居小区'),
        ]);
      },
    );
    expect(sent?['location'], '113.090276,23.007933');
    expect(sent?['page_num'], 2);
    expect(result.buildings.single.label, '13座');
    expect(result.buildings.single.id, 'amap:gd-13');
  });

  test('building results deduplicate across providers and survive one failure',
      () async {
    final TencentBuildingPage merged = await searchCommunityBuildings(
      selectedCommunity,
      1,
      tencentKey: 'tencent-test',
      amapKey: 'amap-test',
      tencentGet: (String url, {Map<String, dynamic>? params}) async =>
          tencentPois(<dynamic>[
        tencentPoi('qq-13', '榴苑三街小区-13座', category: '房产小区:房产小区附属'),
      ]),
      amapGet: (String url, {Map<String, dynamic>? params}) async =>
          amapPois(<dynamic>[
        amapPoi('gd-13', '榴苑三街小区-13座'),
        amapPoi('gd-15', '榴苑三街小区-15座'),
      ]),
    );
    expect(merged.buildings.map((TencentBuilding value) => value.label),
        <String>['13座', '15座']);

    final TencentBuildingPage fallback = await searchCommunityBuildings(
      selectedCommunity,
      1,
      tencentKey: 'tencent-test',
      amapKey: 'amap-test',
      tencentGet: (String url, {Map<String, dynamic>? params}) async =>
          throw const NetworkException('腾讯超时'),
      amapGet: (String url, {Map<String, dynamic>? params}) async =>
          amapPois(<dynamic>[amapPoi('gd-15', '榴苑三街小区-15座')]),
    );
    expect(fallback.buildings.single.id, 'amap:gd-15');

    int amapCalls = 0;
    final TencentBuildingPage noKey = await searchCommunityBuildings(
      selectedCommunity,
      1,
      tencentKey: 'tencent-test',
      amapKey: '',
      tencentGet: (String url, {Map<String, dynamic>? params}) async =>
          tencentPois(<dynamic>[
        tencentPoi('qq-13', '榴苑三街小区-13座', category: '房产小区:房产小区附属'),
      ]),
      amapGet: (String url, {Map<String, dynamic>? params}) async {
        amapCalls++;
        return amapPois(<dynamic>[]);
      },
    );
    expect(noKey.buildings.single.id, 'qq-13');
    expect(amapCalls, 0);
  });

  test('Amap reports service failures without treating them as empty results',
      () {
    expect(
      () => parseAmapNearbyCommunities(
          <String, dynamic>{'status': '0', 'info': 'Key 不可用'}),
      throwsA(isA<BusinessException>().having(
          (BusinessException error) => error.message, 'message', 'Key 不可用')),
    );
  });
}
