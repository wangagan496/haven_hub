import 'dart:math' as math;

import '../api/location.dart';
import '../models/device_map_location.dart';

typedef NearbyBuilding = ({TencentBuilding building, double distance});

/// 仅对已属于所选小区的地图楼栋排序，不推断楼号或自动选中。
List<NearbyBuilding> recommendBuildings(
  List<TencentBuilding> buildings,
  DeviceMapLocation? position, {
  required DateTime now,
}) {
  if (position == null || position.unavailableReason(now) != null) {
    return const <NearbyBuilding>[];
  }
  final List<NearbyBuilding> nearby = <NearbyBuilding>[];
  for (final TencentBuilding building in buildings) {
    if (!validMapCoordinate(building.latitude, building.longitude)) continue;
    final double lat1 = position.latitude * math.pi / 180;
    final double lat2 = building.latitude! * math.pi / 180;
    final double dLat = lat2 - lat1;
    final double dLon =
        (building.longitude! - position.longitude) * math.pi / 180;
    final double a = math.pow(math.sin(dLat / 2), 2).toDouble() +
        math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLon / 2), 2);
    final double distance = 6371000 * 2 * math.asin(math.sqrt(a.clamp(0, 1)));
    if (distance <= 120) nearby.add((building: building, distance: distance));
  }
  nearby.sort((NearbyBuilding a, NearbyBuilding b) {
    final int comparison = a.distance.compareTo(b.distance);
    return comparison != 0
        ? comparison
        : a.building.id.compareTo(b.building.id);
  });
  return nearby.take(3).toList(growable: false);
}
