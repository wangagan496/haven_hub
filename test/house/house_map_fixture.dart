import 'package:haven_hub/models/building_info.dart';

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
