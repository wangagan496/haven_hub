import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/api/location.dart';
import 'package:haven_hub/controller/build_controller.dart';
import 'package:haven_hub/models/building_info.dart';
import 'package:haven_hub/utils/app_exception.dart';

const BuildingInfo community = BuildingInfo(
  name: '榴苑三街小区',
  address: '佛山市榴苑三街16号',
  communityId: 'community',
  latitude: 23.007933,
  longitude: 113.090276,
);

Map<String, dynamic> poi(String id, String title,
    {String address = '佛山市榴苑三街小区', String category = '房产小区:房产小区附属'}) {
  return <String, dynamic>{
    'id': id,
    'title': title,
    'address': address,
    'category': category,
  };
}

Map<String, dynamic> response(List<dynamic> data, {int? count}) =>
    <String, dynamic>{'status': 0, 'count': count ?? data.length, 'data': data};

void main() {
  test('selected community retains Tencent identity and GCJ coordinates', () {
    final NearbyCommunity selected = parseTencentNearbyCommunities(
      response(<dynamic>[
        <String, dynamic>{
          ...poi('community', community.name, category: '房产小区:住宅小区'),
          'location': <String, dynamic>{'lat': 23.007933, 'lng': 113.090276},
        },
      ]),
    ).single;
    final BuildController controller = BuildController()
      ..updateBuildingInfo(<String, dynamic>{
        'name': selected.name,
        'address': selected.address,
        'communityId': selected.id,
        'latitude': selected.latitude,
        'longitude': selected.longitude,
      })
      ..updateBuild('12座2单元')
      ..updateRoom('1602');
    expect(controller.buildingInfo.latitude, community.latitude);
    expect(controller.buildingInfo.longitude, community.longitude);
    expect(controller.buildingInfo.communityId, 'community');
    expect(BuildingInfo.fromJson(controller.buildingInfo.toJson()),
        controller.buildingInfo);
    controller.updateBuildingInfo(<String, dynamic>{'name': '另一小区'});
    expect(controller.buildingInfo.latitude, isNull);
    expect(controller.build, isEmpty);
    expect(controller.room, isEmpty);
  });

  test('query uses selected community coordinates and next real map page',
      () async {
    Map<String, dynamic>? actual;
    await searchTencentCommunityBuildings(community, 2, apiKey: 'test-key',
        externalGet: (String url, {Map<String, dynamic>? params}) async {
      actual = params;
      return response(<dynamic>[]);
    });
    expect(actual?['boundary'], 'nearby(23.007933,113.090276,1000,1)');
    expect(actual?['keyword'], '榴苑三街');
    expect(actual?['filter'], 'category=288000,281200');
    expect(actual?['page_index'], 2);
    expect(actual?['page_size'], 20);
  });

  test('keeps actual buildings and units; excludes gates shops and neighbors',
      () {
    final TencentBuildingPage page = parseTencentCommunityBuildings(
      response(<dynamic>[
        poi('a', '榴苑三街小区-13座'),
        poi('b', '榴苑三街6座'),
        poi('c', '榴苑三街小区12座-2单元'),
        poi('d', '榴苑三街小区8座-楼门'),
        poi('e', '榴苑三街小区-停车场'),
        poi('f', '小店12号', category: '购物:便利店'),
        poi('g', '永星小区-33号', address: '榴苑三街永星小区'),
        poi('h', '苏家大楼-1座', address: '榴苑三街苏家大楼'),
        poi('i', '榴苑三街附近永星小区-1座'),
        poi('j', '2号楼'),
        poi('a', '榴苑三街小区-13座'),
        null,
      ]),
      community,
      1,
    );
    expect(page.buildings.map((TencentBuilding p) => p.label),
        <String>['13座', '6座', '12座-2单元', '2号楼']);
    expect(page.buildings.first.name, '榴苑三街小区-13座');
    expect(page.buildings.first.address, '佛山市榴苑三街小区');
  });

  test('pagination depends on raw POIs even if all are filtered out', () {
    final List<dynamic> data = List<dynamic>.generate(
        20, (int i) => poi('$i', '邻居小区-$i座', address: '邻居小区'));
    final TencentBuildingPage first = parseTencentCommunityBuildings(
        response(data, count: 250), community, 1);
    expect(first.buildings, isEmpty);
    expect(first.hasMore, isTrue);
    expect(first.poiIds.length, 20);
    final TencentBuildingPage last = parseTencentCommunityBuildings(
        response(data, count: 250), community, 10);
    expect(last.hasMore, isFalse);
    expect(last.reachedLimit, isTrue);
    expect(
        parseTencentCommunityBuildings(response(<dynamic>[]), community, 1)
            .hasMore,
        isFalse);
  });

  test('business, malformed and network failures remain distinct', () async {
    expect(
      () => parseTencentCommunityBuildings(
          <String, dynamic>{'status': 120, 'message': 'Key无效'}, community, 1),
      throwsA(isA<BusinessException>()
          .having((BusinessException e) => e.message, 'message', 'Key无效')),
    );
    expect(
        () => parseTencentCommunityBuildings(
            <String, dynamic>{'status': 0, 'data': null}, community, 1),
        throwsFormatException);
    await expectLater(
        searchTencentCommunityBuildings(community, 1, apiKey: 'test-key',
            externalGet: (String url, {Map<String, dynamic>? params}) async {
          throw const NetworkException('连接超时', isTimeout: true);
        }),
        throwsA(isA<NetworkException>()));
    await expectLater(
        searchTencentCommunityBuildings(const BuildingInfo(name: '旧小区'), 1,
            apiKey: 'test-key'),
        throwsFormatException);
  });
}
