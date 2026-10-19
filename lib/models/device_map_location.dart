/// 一次设备定位的 GCJ-02 坐标及精度，仅在选房流程内传递，不持久化。
class DeviceMapLocation {
  const DeviceMapLocation({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.timestamp,
  });

  final double latitude;
  final double longitude;
  final double accuracy;
  final DateTime timestamp;

  String? unavailableReason(DateTime now) {
    if (!validMapCoordinate(latitude, longitude)) return '设备位置无效，请返回重新定位';
    final Duration age = now.difference(timestamp);
    if (age.isNegative || age > const Duration(minutes: 5)) {
      return '定位结果已过期，请返回重新定位';
    }
    if (!accuracy.isFinite || accuracy <= 0 || accuracy > 50) {
      return '当前定位精度不足以推荐楼栋，请下拉选择或手动填写';
    }
    return null;
  }
}

bool validMapCoordinate(double? latitude, double? longitude) =>
    latitude != null &&
    longitude != null &&
    latitude.isFinite &&
    longitude.isFinite &&
    latitude >= -90 &&
    latitude <= 90 &&
    longitude >= -180 &&
    longitude <= 180 &&
    !(latitude == 0 && longitude == 0);
